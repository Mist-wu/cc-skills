#!/usr/bin/env bash
# pi-wt.sh - throwaway git worktrees for pi subagents that write code.
# The worktree lives outside the repo; changes come back as an unstaged diff.

set -uo pipefail

WT_ROOT=${PI_WT_DIR:-$HOME/.claude/pi-worktrees}

die() { printf 'pi-wt: %s\n' "$*" >&2; exit 2; }

usage() {
  cat <<'USAGE'
pi-wt.sh new  <name> [--from <ref>]   create worktree on branch pi/<name>, print its path
pi-wt.sh path <name>                  print the path
pi-wt.sh list                         list this repo's pi worktrees
pi-wt.sh diff <name>                  diff of everything the subagent did
pi-wt.sh land <name>                  apply that diff onto the main worktree, unstaged
pi-wt.sh drop <name> [--force]        remove the worktree and its branch
USAGE
}

MAIN=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
REPO=$(basename "$MAIN")
DIR_FOR() { printf '%s/%s/%s' "$WT_ROOT" "$REPO" "$1"; }

CMD=${1:-}; [ $# -gt 0 ] && shift
case "$CMD" in
  ''|-h|--help) usage; exit 0 ;;
esac

NAME=${1:-}
case "$CMD" in
  list) : ;;
  *)
    [ -n "$NAME" ] || die "$CMD needs a <name>"
    case "$NAME" in
      *[!A-Za-z0-9._-]*) die "name may only contain letters, digits, dot, dash, underscore" ;;
    esac
    shift ;;
esac

WT=$(DIR_FOR "$NAME")
BRANCH="pi/$NAME"

# Linked dependency dirs are symlinks, which a "node_modules/" gitignore rule
# (directories only) does not cover. Keep them out of every path we look at.
SPEC=(-- . ':(exclude)node_modules' ':(exclude)*/node_modules')

case "$CMD" in

new)
  FROM=HEAD
  while [ $# -gt 0 ]; do
    case "$1" in
      --from) [ $# -ge 2 ] || die "--from needs a ref"; FROM=$2; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [ -e "$WT" ] && die "worktree already exists: $WT"
  mkdir -p "$(dirname "$WT")" || die "cannot create $WT_ROOT/$REPO"
  git -C "$MAIN" show-ref --verify --quiet "refs/heads/$BRANCH" \
    && die "branch $BRANCH already exists (pi-wt.sh drop $NAME first)"
  git -C "$MAIN" worktree add -b "$BRANCH" "$WT" "$FROM" >&2 || die "worktree add failed"

  # Dependency dirs are gitignored, so a fresh worktree cannot build without them.
  for SRC in "$MAIN/node_modules" "$MAIN"/*/node_modules; do
    [ -d "$SRC" ] || continue
    REL=${SRC#"$MAIN"/}
    DST=$WT/$REL
    [ -e "$DST" ] && continue
    mkdir -p "$(dirname "$DST")"
    ln -s "$SRC" "$DST" && printf 'pi-wt: linked %s\n' "$REL" >&2
  done

  printf '%s\n' "$WT"
  ;;

path)
  [ -d "$WT" ] || die "no such worktree: $NAME"
  printf '%s\n' "$WT"
  ;;

list)
  git -C "$MAIN" worktree list | grep -F "$WT_ROOT/$REPO/" || printf 'no pi worktrees for %s\n' "$REPO"
  ;;

diff)
  [ -d "$WT" ] || die "no such worktree: $NAME"
  git -C "$WT" add -A -N "${SPEC[@]}" >/dev/null 2>&1
  git -C "$WT" diff HEAD "${SPEC[@]}"
  ;;

land)
  [ -d "$WT" ] || die "no such worktree: $NAME"
  git -C "$WT" add -A -N "${SPEC[@]}" >/dev/null 2>&1
  PATCH=$WT_ROOT/$REPO/$NAME.patch
  git -C "$WT" diff HEAD "${SPEC[@]}" > "$PATCH" || die "could not produce a diff"
  if [ ! -s "$PATCH" ]; then
    printf 'pi-wt: %s changed nothing.\n' "$NAME"
    rm -f "$PATCH"; exit 0
  fi
  if git -C "$MAIN" apply --check "$PATCH" 2>/dev/null; then
    git -C "$MAIN" apply "$PATCH" \
      || die "apply failed - the tree may be partially patched, check git status. Patch: $PATCH"
  else
    printf 'pi-wt: clean apply not possible, falling back to 3-way merge.\n' >&2
    git -C "$MAIN" apply --3way "$PATCH" \
      || die "3-way apply left the tree conflicted; patch kept at $PATCH"
  fi
  git -C "$WT" diff HEAD --stat "${SPEC[@]}"
  printf 'pi-wt: landed in %s as unstaged changes (nothing committed). Patch: %s\n' "$MAIN" "$PATCH"
  ;;

drop)
  FORCE=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --force|-f) FORCE=1; shift ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [ -d "$WT" ] || die "no such worktree: $NAME"
  if [ "$FORCE" -eq 0 ] && [ -n "$(git -C "$WT" status --porcelain "${SPEC[@]}" 2>/dev/null)" ]; then
    die "$NAME still has uncommitted work - pi-wt.sh land $NAME, or drop --force to discard"
  fi
  git -C "$MAIN" worktree remove --force "$WT" || die "worktree remove failed"
  git -C "$MAIN" branch -D "$BRANCH" >/dev/null 2>&1
  printf 'pi-wt: dropped %s\n' "$NAME"
  ;;

*) die "unknown command: $CMD" ;;
esac
