#!/usr/bin/env bash
# pi-wt.sh - throwaway git worktrees for pi subagents that write code.
# The worktree lives outside the repo. land copies bytes into the main
# working tree and does not stage them. drop compares those bytes.
# It does not trust `git apply --reverse`, and --force does not skip identity.

set -uo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX

WT_ROOT=${PI_WT_DIR:-$HOME/.claude/pi-worktrees}

die() { printf 'pi-wt: %s\n' "$*" >&2; exit 2; }
warn() { printf 'pi-wt: %s\n' "$*" >&2; }

usage() {
  cat <<'USAGE'
pi-wt.sh new  <name> [--from <ref>]   create worktree on branch pi/<name>, print its path
pi-wt.sh path <name>                  print the path registered in this repository
pi-wt.sh list                         list this repository's pi/ worktrees
pi-wt.sh diff <name>                  diff of commits, index, worktree, and untracked files
pi-wt.sh land <name>                  copy that work into the main worktree, unstaged
pi-wt.sh drop <name> [--force]        remove the worktree and its branch

drop without --force deletes a worktree only when it is registered to this
repository on branch pi/<name>, it is not the main worktree, and every committed,
staged, unstaged, and untracked change is already present byte for byte in the
main working tree. --force still requires that identity. It discards only the
named worktree. Gitignored files inside the worktree directory are deleted with
it, including files you created there.
USAGE
}

phys_dir() {
  (cd "$1" && pwd -P)
}

CMD=${1:-}
[ $# -gt 0 ] && shift
case "$CMD" in
  ''|-h|--help) usage; exit 0 ;;
esac

COMMON_RAW=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
  || die "not inside a git repository"
COMMON=$(phys_dir "$COMMON_RAW") || die "cannot resolve this repository"

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

BRANCH="pi/$NAME"

# Only the exact node_modules symlinks `new` created are invisible to land/drop.
# A real node_modules directory, including untracked files inside it, is work.
tool_link_args() {
  local src rel dst src_phys dst_phys
  ADD_ARGS=(-- .)
  for src in "$MAIN_PATH/node_modules" "$MAIN_PATH"/*/node_modules; do
    [ -e "$src" ] || continue
    rel=${src#"$MAIN_PATH"/}
    dst=$TARGET_PATH/$rel
    [ -L "$dst" ] || continue
    src_phys=$(phys_dir "$src") || continue
    dst_phys=$(phys_dir "$dst") || continue
    if [ "$src_phys" = "$dst_phys" ]; then
      ADD_ARGS+=(":(exclude)$rel")
    fi
  done
}

WT_PATHS=()
WT_HEADS=()
WT_BRANCHES=()

load_worktrees() {
  local token path head branch raw
  WT_PATHS=()
  WT_HEADS=()
  WT_BRANCHES=()
  path=""
  head=""
  branch=""
  raw=$(mktemp) || die "cannot create a temp file"
  git worktree list --porcelain -z >"$raw" || { rm -f "$raw"; die "cannot list worktrees"; }
  while IFS= read -r -d '' token; do
    case "$token" in
      worktree\ *)
        if [ -n "$path" ]; then
          WT_PATHS+=("$path")
          WT_HEADS+=("$head")
          WT_BRANCHES+=("$branch")
        fi
        path=${token#worktree }
        head=""
        branch=""
        ;;
      HEAD\ *) head=${token#HEAD } ;;
      branch\ *) branch=${token#branch } ;;
      detached) branch="" ;;
    esac
  done <"$raw"
  rm -f "$raw"
  if [ -n "$path" ]; then
    WT_PATHS+=("$path")
    WT_HEADS+=("$head")
    WT_BRANCHES+=("$branch")
  fi
  [ "${#WT_PATHS[@]}" -gt 0 ] || die "this repository has no worktree"
}

same_dir() {
  [ "$(phys_dir "$1")" = "$(phys_dir "$2")" ]
}

resolve_main() {
  load_worktrees
  MAIN_PATH=$(phys_dir "${WT_PATHS[0]}") || die "cannot resolve the main worktree"
  MAIN_HEAD=${WT_HEADS[0]}
  local main_common
  main_common=$(git -C "$MAIN_PATH" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    || die "cannot read the main repository"
  main_common=$(phys_dir "$main_common") || die "cannot resolve the main repository"
  [ "$main_common" = "$COMMON" ] || die "worktree list does not belong to this repository"
}

# Sets TARGET_PATH, TARGET_HEAD. Refuses the wrong repo, the main worktree, and a
# worktree that is not currently on pi/<name>. --force does not bypass this.
resolve_target() {
  resolve_main
  local i found=0 path branch common_target current
  for i in "${!WT_PATHS[@]}"; do
    [ "${WT_BRANCHES[$i]}" = "refs/heads/$BRANCH" ] || continue
    found=$((found + 1))
    path=${WT_PATHS[$i]}
    TARGET_HEAD=${WT_HEADS[$i]}
  done
  [ "$found" -ne 0 ] || die "no worktree on branch $BRANCH is registered in this repository"
  [ "$found" -eq 1 ] || die "more than one worktree is registered on $BRANCH"
  [ -d "$path" ] || die "registered worktree is missing on disk: $path"
  TARGET_PATH=$(phys_dir "$path") || die "cannot resolve $path"
  same_dir "$TARGET_PATH" "$MAIN_PATH" \
    && die "refusing: $BRANCH is checked out as the main worktree, so source and target are the same"
  common_target=$(git -C "$TARGET_PATH" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    || die "cannot read the registered worktree"
  common_target=$(phys_dir "$common_target") || die "cannot resolve the registered worktree"
  [ "$common_target" = "$COMMON" ] || die "registered path does not belong to this repository: $TARGET_PATH"
  current=$(git -C "$TARGET_PATH" symbolic-ref --quiet HEAD 2>/dev/null) || current=""
  [ "$current" = "refs/heads/$BRANCH" ] \
    || die "refusing: worktree is on ${current:-a detached HEAD}, not $BRANCH"
}

repo_key() {
  printf '%s' "$COMMON" | git hash-object --stdin | cut -c1-16
}

index_file() {
  git -C "$1" rev-parse --path-format=absolute --git-path index 2>/dev/null
}

require_readable() {
  local which=$1 root idx err
  root=$MAIN_PATH
  [ "$which" = target ] && root=$TARGET_PATH
  idx=$(index_file "$root") || die "cannot locate the git index of $root"
  if [ -e "$idx.lock" ]; then
    die "index.lock is present in $root; refusing so staged and untracked work cannot be missed"
  fi
  err=$(mktemp) || die "cannot create a temp file"
  if ! git -C "$root" status --porcelain=v1 >/dev/null 2>"$err"; then
    die "cannot read git status in $root: $(tr '\n' ' ' <"$err")"
  fi
  rm -f "$err"
  if [ -n "$(git -C "$root" ls-files -u)" ]; then
    die "index in $root has unmerged entries; refusing"
  fi
}

# Prints paths whose index differs from HEAD and whose worktree differs from the index.
ambiguous_paths() {
  local cached work hashdir h p
  cached=$(mktemp) || return 2
  work=$(mktemp) || { rm -f "$cached"; return 2; }
  hashdir=$(mktemp -d) || { rm -f "$cached" "$work"; return 2; }
  tool_link_args
  if ! git -C "$TARGET_PATH" diff --cached --name-only -z "${ADD_ARGS[@]}" >"$cached"; then
    rm -rf "$hashdir"; rm -f "$cached" "$work"; return 2
  fi
  if ! git -C "$TARGET_PATH" diff --name-only -z "${ADD_ARGS[@]}" >"$work"; then
    rm -rf "$hashdir"; rm -f "$cached" "$work"; return 2
  fi
  while IFS= read -r -d '' p; do
    [ -n "$p" ] || continue
    h=$(printf '%s' "$p" | git hash-object --stdin) || return 2
    : >"$hashdir/$h"
  done <"$cached"
  while IFS= read -r -d '' p; do
    [ -n "$p" ] || continue
    h=$(printf '%s' "$p" | git hash-object --stdin) || return 2
    [ -e "$hashdir/$h" ] && printf '%s\n' "$p"
  done <"$work"
  rm -rf "$hashdir"
  rm -f "$cached" "$work"
}

build_snapshot() {
  local tmp err tree
  tmp=$(mktemp) || return 2
  err=$(mktemp) || { rm -f "$tmp"; return 2; }
  if ! GIT_INDEX_FILE="$tmp" git -C "$TARGET_PATH" read-tree HEAD >"$err" 2>&1; then
    warn "cannot read the worktree HEAD into a snapshot: $(tr '\n' ' ' <"$err")"
    rm -f "$tmp" "$err"
    return 2
  fi
  tool_link_args
  if ! GIT_INDEX_FILE="$tmp" git -C "$TARGET_PATH" add -A "${ADD_ARGS[@]}" >"$err" 2>&1; then
    warn "cannot snapshot worktree files: $(tr '\n' ' ' <"$err")"
    rm -f "$tmp" "$err"
    return 2
  fi
  if ! tree=$(GIT_INDEX_FILE="$tmp" git -C "$TARGET_PATH" write-tree 2>"$err"); then
    warn "cannot write a snapshot tree: $(tr '\n' ' ' <"$err")"
    rm -f "$tmp" "$err"
    return 2
  fi
  rm -f "$tmp" "$err"
  printf '%s\n' "$tree"
}

tree_mode_blob() {
  local spec mode blob
  spec=$(git -C "$TARGET_PATH" ls-tree "$1" -- "$2" 2>/dev/null) || return 2
  [ -n "$spec" ] || return 1
  # 100644 blob <hash>\t<path>
  mode=${spec%% *}
  blob=${spec#*blob }
  blob=${blob%%[[:space:]]*}
  [ -n "$mode" ] && [ -n "$blob" ] || return 1
  printf '%s %s\n' "$mode" "$blob"
}

blob_bytes_match() {
  local file=$1 repo=$2 blob=$3 tmp rc
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  tmp=$(mktemp) || return 2
  if ! git -C "$repo" cat-file blob "$blob" >"$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 2
  fi
  cmp -s "$file" "$tmp"
  rc=$?
  rm -f "$tmp"
  return "$rc"
}

file_mode() {
  if [ -x "$1" ]; then printf '100755\n'; else printf '100644\n'; fi
}

# Refuse a path whose ancestor inside the main worktree is a symlink.
# mkdir and mktemp would otherwise write through that link, outside the tree.
path_stays_inside() {
  local rel=$1 acc part parent
  case "$rel" in
    /*) die "refusing to write $rel outside the main worktree" ;;
  esac
  parent=$(dirname "$rel")
  [ "$parent" = . ] && return 0
  acc=$MAIN_PATH
  local IFS=/
  for part in $parent; do
    [ -n "$part" ] && [ "$part" != . ] || continue
    [ "$part" = .. ] && die "refusing to write $rel outside the main worktree"
    acc=$acc/$part
    if [ -L "$acc" ]; then
      die "refusing to write $rel through symlink $acc"
    fi
  done
  if [ -d "$MAIN_PATH/$parent" ]; then
    local parent_phys main_phys
    parent_phys=$(phys_dir "$MAIN_PATH/$parent") || die "cannot resolve $parent"
    main_phys=$(phys_dir "$MAIN_PATH") || die "cannot resolve the main worktree"
    case "$parent_phys/" in
      "$main_phys"/*) ;;
      *) die "refusing to write $rel outside $MAIN_PATH" ;;
    esac
  fi
}

# Fill OP, PTH, MODE, BLOB from BASE..TREE. Return 2 on a read error.
collect_changes() {
  local raw status oldp newp info mode blob
  OP=()
  PTH=()
  MODE=()
  BLOB=()
  raw=$(mktemp) || return 2
  if ! git -C "$TARGET_PATH" diff-tree -r -z --name-status --find-renames "$BASE" "$TREE" >"$raw"; then
    rm -f "$raw"
    return 2
  fi
  while IFS= read -r -d '' status; do
    [ -n "$status" ] || continue
    case "$status" in
      R*|C*)
        IFS= read -r -d '' oldp || { rm -f "$raw"; return 2; }
        IFS= read -r -d '' newp || { rm -f "$raw"; return 2; }
        if [ "${status#R}" != "$status" ]; then
          OP+=("D")
          PTH+=("$oldp")
          MODE+=("")
          BLOB+=("")
        fi
        info=$(tree_mode_blob "$TREE" "$newp") || { rm -f "$raw"; return 2; }
        mode=${info%% *}
        blob=${info#* }
        OP+=("A")
        PTH+=("$newp")
        MODE+=("$mode")
        BLOB+=("$blob")
        ;;
      D)
        IFS= read -r -d '' newp || { rm -f "$raw"; return 2; }
        OP+=("D")
        PTH+=("$newp")
        MODE+=("")
        BLOB+=("")
        ;;
      *)
        IFS= read -r -d '' newp || { rm -f "$raw"; return 2; }
        info=$(tree_mode_blob "$TREE" "$newp") || { rm -f "$raw"; return 2; }
        mode=${info%% *}
        blob=${info#* }
        OP+=("$status")
        PTH+=("$newp")
        MODE+=("$mode")
        BLOB+=("$blob")
        ;;
    esac
  done <"$raw"
  rm -f "$raw"
}

prepare_snapshot() {
  local amb
  require_readable target || return 2
  if ! amb=$(ambiguous_paths); then
    die "cannot compare the worktree index with its files"
  fi
  if [ -n "$amb" ]; then
    SNAP_BLOCK="index and working tree disagree, so both copies are kept:
$(printf '%s\n' "$amb" | sed 's/^/  /')"
    return 1
  fi
  MAIN_HEAD=$(git -C "$MAIN_PATH" rev-parse HEAD 2>/dev/null) || die "cannot read the main HEAD"
  TARGET_HEAD=$(git -C "$TARGET_PATH" rev-parse HEAD 2>/dev/null) || die "cannot read the worktree HEAD"
  BASE=$(git merge-base "$MAIN_HEAD" "$TARGET_HEAD" 2>/dev/null) || {
    SNAP_BLOCK="no common ancestor between the main HEAD and $BRANCH; refusing to guess"
    return 1
  }
  TREE=$(build_snapshot) || die "cannot snapshot $BRANCH"
  collect_changes || die "cannot list changes in $BRANCH"
  UNIQUE_COMMITS=$(git -C "$TARGET_PATH" rev-list --count "$MAIN_HEAD..$TARGET_HEAD" 2>/dev/null) \
    || die "cannot list commits that exist only on $BRANCH"
}

bytes_landed() {
  local i path mode blob file base_info base_mode base_blob
  [ "${#OP[@]}" -eq 0 ] && return 0
  for i in "${!OP[@]}"; do
    path=${PTH[$i]}
    mode=${MODE[$i]}
    blob=${BLOB[$i]}
    file=$MAIN_PATH/$path
    case "${OP[$i]}" in
      D)
        [ -e "$file" ] || [ -L "$file" ] && return 1
        ;;
      *)
        case "$mode" in
          100644|100755) ;;
          *) return 1 ;;
        esac
        blob_bytes_match "$file" "$TARGET_PATH" "$blob" || return 1
        [ "$(file_mode "$file")" = "$mode" ] || return 1
        ;;
    esac
  done
  return 0
}

patch_path() {
  printf '%s/%s.patch' "$(dirname "$TARGET_PATH")" "$NAME"
}

write_patch() {
  local dest tmp dir bak
  dest=$(patch_path)
  dir=$(dirname "$dest")
  mkdir -p "$dir" || die "cannot create $dir"
  tmp=$(mktemp "$dir/.pi-wt-patch.XXXXXX") || die "cannot create a patch file"
  if ! git -C "$TARGET_PATH" diff --binary --full-index "$BASE" "$TREE" >"$tmp"; then
    rm -f "$tmp"
    die "could not write a recovery patch"
  fi
  if [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    return 0
  fi
  if [ -f "$dest" ] && cmp -s "$dest" "$tmp"; then
    rm -f "$tmp"
    PATCH=$dest
    return 0
  fi
  if [ -s "$dest" ]; then
    bak=$dest.bak.$(date +%Y%m%d-%H%M%S)-$$
    mv "$dest" "$bak" || { rm -f "$tmp"; die "could not keep the previous patch"; }
    warn "kept the previous patch at $bak"
  fi
  mv "$tmp" "$dest" || die "could not install the patch"
  PATCH=$dest
}

index_dirty_for() {
  local err rc
  err=$(mktemp) || return 2
  git -C "$MAIN_PATH" diff --cached --quiet -- "$1" 2>"$err"
  rc=$?
  if [ "$rc" -gt 1 ]; then
    warn "cannot read the main index for $1: $(tr '\n' ' ' <"$err")"
    rm -f "$err"
    return 2
  fi
  rm -f "$err"
  return "$rc"
}

link_modules() {
  local src rel dst
  for src in "$MAIN_PATH/node_modules" "$MAIN_PATH"/*/node_modules; do
    [ -d "$src" ] || continue
    rel=${src#"$MAIN_PATH"/}
    dst=$TARGET_PATH/$rel
    [ -e "$dst" ] && continue
    mkdir -p "$(dirname "$dst")" || die "cannot link $rel"
    ln -s "$src" "$dst" || die "cannot link $rel"
    printf 'pi-wt: linked %s\n' "$rel" >&2
  done
}

case "$CMD" in

new)
  FROM=HEAD
  while [ $# -gt 0 ]; do
    case "$1" in
      --from) [ $# -ge 2 ] || die "--from needs a ref"; FROM=$2; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  resolve_main
  TARGET_PATH=$WT_ROOT/$(repo_key)/$NAME
  [ -e "$TARGET_PATH" ] && die "worktree path already exists: $TARGET_PATH"
  git -C "$MAIN_PATH" show-ref --verify --quiet "refs/heads/$BRANCH" \
    && die "branch $BRANCH already exists (pi-wt.sh drop $NAME first)"
  mkdir -p "$(dirname "$TARGET_PATH")" || die "cannot create $WT_ROOT"
  git -C "$MAIN_PATH" worktree add -b "$BRANCH" "$TARGET_PATH" "$FROM" >&2 \
    || die "worktree add failed"
  link_modules
  printf '%s\n' "$TARGET_PATH"
  ;;

path)
  resolve_target
  printf '%s\n' "$TARGET_PATH"
  ;;

list)
  resolve_main
  found=0
  for i in "${!WT_PATHS[@]}"; do
    case "${WT_BRANCHES[$i]}" in
      refs/heads/pi/*)
        printf '%s %s\n' "${WT_BRANCHES[$i]#refs/heads/}" "${WT_PATHS[$i]}"
        found=1
        ;;
    esac
  done
  [ "$found" -eq 1 ] || printf 'no pi worktrees for this repository\n'
  ;;

diff)
  resolve_target
  prepare_snapshot
  snap_rc=$?
  if [ "$snap_rc" -eq 1 ]; then
    warn "$SNAP_BLOCK"
    warn "showing the index diff, the worktree diff, and untracked files separately"
    tool_link_args
    git -C "$TARGET_PATH" diff --cached --binary "${ADD_ARGS[@]}"
    git -C "$TARGET_PATH" diff --binary "${ADD_ARGS[@]}"
    git -C "$TARGET_PATH" ls-files --others --exclude-standard -z "${ADD_ARGS[@]}" \
      | tr '\0' '\n'
    exit 0
  fi
  git -C "$TARGET_PATH" diff --binary --full-index "$BASE" "$TREE"
  ;;

land)
  resolve_target
  require_readable main
  prepare_snapshot
  snap_rc=$?
  if [ "$snap_rc" -eq 1 ]; then
    die "$SNAP_BLOCK"
  fi
  if [ "${#OP[@]}" -eq 0 ]; then
    printf 'pi-wt: %s changed nothing.\n' "$NAME"
    exit 0
  fi
  write_patch
  for i in "${!OP[@]}"; do
    path=${PTH[$i]}
    mode=${MODE[$i]}
    blob=${BLOB[$i]}
    file=$MAIN_PATH/$path
    path_stays_inside "$path"
    index_dirty_for "$path"
    dirty=$?
    [ "$dirty" -eq 2 ] && die "cannot read the main index; patch kept at $PATCH"
    if [ "$dirty" -ne 0 ]; then
      die "main index already has changes on $path; stopped before changing the index. Patch: $PATCH"
    fi
    case "${OP[$i]}" in
      D)
        if [ -e "$file" ] || [ -L "$file" ]; then
          base_info=$(tree_mode_blob "$BASE" "$path") || base_info=""
          base_blob=${base_info#* }
          if [ -z "$base_blob" ] || ! blob_bytes_match "$file" "$TARGET_PATH" "$base_blob"; then
            die "main worktree copy of $path has diverged; stopped before changing it. Patch: $PATCH"
          fi
        fi
        ;;
      *)
        case "$mode" in
          100644|100755) ;;
          *) die "refusing to land $path (mode $mode). Patch: $PATCH" ;;
        esac
        if [ -e "$file" ] || [ -L "$file" ]; then
          if blob_bytes_match "$file" "$TARGET_PATH" "$blob" && [ "$(file_mode "$file")" = "$mode" ]; then
            continue
          fi
          base_info=$(tree_mode_blob "$BASE" "$path") || {
            die "main worktree already has $path and it is not the worktree copy. Patch: $PATCH"
          }
          base_blob=${base_info#* }
          if ! blob_bytes_match "$file" "$TARGET_PATH" "$base_blob"; then
            die "main worktree copy of $path has diverged; stopped before changing it. Patch: $PATCH"
          fi
        fi
        ;;
    esac
  done

  before_tree=$(git -C "$MAIN_PATH" write-tree 2>/dev/null) \
    || die "main index is unreadable; stopped before changing it. Patch: $PATCH"
  backup=$(mktemp -d) || die "cannot create a backup directory"
  mkdir -p "$backup/payload" "$backup/missing" || die "cannot create a backup directory"
  for i in "${!OP[@]}"; do
    path=${PTH[$i]}
    file=$MAIN_PATH/$path
    if [ -e "$file" ] || [ -L "$file" ]; then
      mkdir -p "$backup/payload/$(dirname "$path")" || die "cannot back up $path"
      cp -a "$file" "$backup/payload/$path" || die "cannot back up $path"
    else
      mkdir -p "$backup/missing/$(dirname "$path")" || die "cannot record $path"
      : >"$backup/missing/$path"
    fi
  done

  restore_backup() {
    local i path file
    for i in "${!OP[@]}"; do
      path=${PTH[$i]}
      file=$MAIN_PATH/$path
      path_stays_inside "$path"
      if [ -e "$backup/missing/$path" ]; then
        rm -rf "$file"
      elif [ -e "$backup/payload/$path" ] || [ -L "$backup/payload/$path" ]; then
        mkdir -p "$(dirname "$file")"
        rm -rf "$file"
        cp -a "$backup/payload/$path" "$file" || warn "could not restore $path"
      fi
    done
  }

  for i in "${!OP[@]}"; do
    path=${PTH[$i]}
    mode=${MODE[$i]}
    blob=${BLOB[$i]}
    file=$MAIN_PATH/$path
    case "${OP[$i]}" in
      D)
        if [ -e "$file" ] || [ -L "$file" ]; then
          rm -f "$file" || { restore_backup; die "could not remove $path. Patch: $PATCH"; }
        fi
        ;;
      *)
        if [ -f "$file" ] && [ ! -L "$file" ] \
          && blob_bytes_match "$file" "$TARGET_PATH" "$blob" \
          && [ "$(file_mode "$file")" = "$mode" ]; then
          continue
        fi
        path_stays_inside "$path"
        mkdir -p "$(dirname "$file")" || { restore_backup; die "could not create $(dirname "$path")"; }
        tmp=$(mktemp "$(dirname "$file")/.pi-wt.XXXXXX") || { restore_backup; die "could not write $path"; }
        if ! git -C "$TARGET_PATH" cat-file blob "$blob" >"$tmp"; then
          rm -f "$tmp"
          restore_backup
          die "could not read blob for $path. Patch: $PATCH"
        fi
        if [ "$mode" = "100755" ]; then chmod 755 "$tmp"; else chmod 644 "$tmp"; fi
        mv -f "$tmp" "$file" || { rm -f "$tmp"; restore_backup; die "could not install $path. Patch: $PATCH"; }
        ;;
    esac
  done

  after_tree=$(git -C "$MAIN_PATH" write-tree 2>/dev/null) || {
    restore_backup
    die "main index could not be reread; restored the previous files. Patch: $PATCH"
  }
  if [ "$before_tree" != "$after_tree" ]; then
    restore_backup
    die "main index changed during land; restored the previous files. Patch: $PATCH"
  fi
  rm -rf "$backup"
  git -C "$TARGET_PATH" diff --stat "$BASE" "$TREE"
  printf 'pi-wt: landed in %s as unstaged changes (nothing committed). Patch: %s\n' "$MAIN_PATH" "$PATCH"
  ;;

drop)
  FORCE=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --force|-f) FORCE=1; shift ;;
      *) die "unknown option: $1" ;;
    esac
  done
  resolve_target
  require_readable target
  if [ "$FORCE" -eq 0 ]; then
    prepare_snapshot
    snap_rc=$?
    if [ "$snap_rc" -eq 1 ]; then
      die "$SNAP_BLOCK"
    fi
    if [ "${UNIQUE_COMMITS:-0}" -gt 0 ]; then
      die "$BRANCH has $UNIQUE_COMMITS commit(s) that are not in the main branch. Refusing to remove the worktree or delete the branch, even when the working tree matches the baseline"
    fi
    if ! bytes_landed; then
      die "$NAME still has work that is not byte-for-byte in the main worktree. Land it, or drop --force to discard this worktree only"
    fi
  fi
  same_dir "$TARGET_PATH" "$MAIN_PATH" \
    && die "refusing to remove the main worktree"
  tool_link_args
  ignored=$(git -C "$TARGET_PATH" ls-files -o -i --exclude-standard --directory "${ADD_ARGS[@]}")
  git -C "$MAIN_PATH" worktree remove --force "$TARGET_PATH" \
    || die "worktree remove failed"
  if ! git -C "$MAIN_PATH" branch -D "$BRANCH" >/dev/null 2>&1; then
    die "removed the worktree but could not delete branch $BRANCH"
  fi
  printf 'pi-wt: dropped %s\n' "$NAME"
  if [ -n "$ignored" ]; then
    warn "deleted gitignored files that lived only in that worktree, including files you created there. node_modules symlinks are gone; their targets were not. The main worktree was not modified."
  else
    warn "the main index and main working tree were not modified"
  fi
  ;;

*) die "unknown command: $CMD" ;;
esac
