#!/usr/bin/env bash
# pi-run.sh - hand one scoped task to a pi subagent, capture it, report back.
# Targets bash 3.2 (macOS system bash): no associative arrays, no mapfile.

set -uo pipefail

RUN_ROOT=${PI_RUN_DIR:-$HOME/.claude/pi-runs}

die() { printf 'pi-run: %s\n' "$*" >&2; exit 2; }

usage() {
  cat <<'USAGE'
pi-run.sh [options] -- "<prompt>"
pi-run.sh progress [<log-dir>|latest]

Options:
  --profile <name>   search | recon | test | edit | browser | free   (default: recon)
  --model <name>     flash | astra | <provider>/<model>              (default: flash)
  --cwd <dir>        working directory for the subagent               (default: $PWD)
  --timeout <secs>   watchdog; default is max(model, profile) default
  --session <spec>   new | <uuid> | off   (profile decides when unset)
  --thinking <lvl>   off|minimal|low|medium|high|xhigh|max            (default: high)
  --tools <list>     extra tools appended to the profile whitelist
                     (required, and used verbatim, for --profile free)
  --label <slug>     tag for the log directory name
  --unsafe-in-place  let --profile edit run outside a pi/ worktree
  --dry-run          print the pi command and exit

Exit codes: 0 ok, 1 pi failed, 2 usage error, 124 timed out.
USAGE
}

# ---------------------------------------------------------------- progress ---
if [ "${1:-}" = "progress" ]; then
  command -v jq >/dev/null || die "jq is not on PATH"
  DIR=${2:-latest}
  [ "$DIR" = "latest" ] && DIR=$(ls -dt "$RUN_ROOT"/*/ 2>/dev/null | head -1)
  [ -n "$DIR" ] && [ -d "$DIR" ] || die "no run directory found"
  DIR=${DIR%/}
  printf 'run: %s\n' "$DIR"
  [ -f "$DIR/cmd.txt" ] && sed -n '1,2p' "$DIR/cmd.txt"
  if [ -f "$DIR/raw.jsonl" ]; then
    printf 'elapsed: %ss\n' "$(( $(date +%s) - $(stat -f %B "$DIR/raw.jsonl" 2>/dev/null || date +%s) ))"
    printf 'steps:\n'
    jq -Rrn '[inputs | select(startswith("{")) | (fromjson? // empty)]
            | .[] | select(.type=="tool_execution_start" or .type=="tool_execution_end")
            | "  " + (if .type=="tool_execution_start" then "->" else "<-" end) + " " + .toolName' \
       "$DIR/raw.jsonl" 2>/dev/null | tail -20
    printf 'last text:\n'
    jq -Rrn '[inputs | select(startswith("{")) | (fromjson? // empty)]
            | [.[] | select(.type=="message_end" and .message.role=="assistant")
                   | .message.content[]? | select(.type=="text") | .text] | last // ""' \
       "$DIR/raw.jsonl" 2>/dev/null | tail -c 600
    printf '\n'
  fi
  exit 0
fi

# -------------------------------------------------------------------- args ---
PROFILE=recon MODEL=flash CWD=$PWD TIMEOUT='' SESSION='' THINKING=high
EXTRA_TOOLS='' LABEL='' PROMPT='' DRY_RUN=0 UNSAFE=0

# Preserve the supplied wrapper options for resume. Pin cwd, timeout and session
# after resolving their defaults and turning "new" into the actual session ID.
case "$0" in /*) RESUME=("$0") ;; *) RESUME=("$PWD/$0") ;; esac
while [ $# -gt 0 ]; do
  case "$1" in
    --unsafe-in-place) UNSAFE=1; RESUME+=("$1"); shift; continue ;;
    --dry-run) DRY_RUN=1; shift; continue ;;
    -h|--help) usage; exit 0 ;;
    --) shift; PROMPT=$*; break ;;
  esac
  [ $# -ge 2 ] || die "$1 needs a value"
  case "$1" in
    --cwd)     CWD=$2; shift 2; continue ;;
    --session) SESSION=$2; shift 2; continue ;;
    --timeout) [ -n "$2" ] || die "--timeout needs a non-empty integer"
               TIMEOUT=$2; shift 2; continue ;;
    --profile) PROFILE=$2 ;;
    --model) MODEL=$2 ;;
    --thinking) THINKING=$2 ;;
    --tools) EXTRA_TOOLS=$2 ;;
    --label) LABEL=$2 ;;
    *) die "unknown option: $1 (the prompt goes after --)" ;;
  esac
  RESUME+=("$1" "$2")
  shift 2
done

[ -n "$PROMPT" ] || { usage >&2; die "no prompt (put it after --)"; }
[ -d "$CWD" ] || die "--cwd is not a directory: $CWD"
case "$CWD" in /*) ;; *) CWD=$PWD/$CWD ;; esac
if [ -n "$LABEL" ]; then
  case "$LABEL" in
    *[!A-Za-z0-9._-]*) die "--label may only contain letters, digits, dot, dash, underscore" ;;
  esac
fi
if [ -n "$TIMEOUT" ]; then
  case "$TIMEOUT" in
    *[!0-9]*) die "--timeout must be a positive integer" ;;
  esac
  # 10# so 08 is eight seconds, not an invalid octal number.
  TIMEOUT=$((10#$TIMEOUT))
  [ "$TIMEOUT" -gt 0 ] || die "--timeout must be a positive integer"
fi
command -v pi >/dev/null || die "pi is not on PATH"
command -v jq >/dev/null || die "jq is not on PATH"

# ------------------------------------------------------------------- model ---
case "$MODEL" in
  flash) PROVIDER=deepseek     MODEL_ID=deepseek-flash MODEL_TIMEOUT=300  ;;
  astra) PROVIDER=openai-codex MODEL_ID=gpt-6-astra    MODEL_TIMEOUT=1200 ;;
  */*)   PROVIDER=${MODEL%%/*} MODEL_ID=${MODEL#*/}    MODEL_TIMEOUT=600  ;;
  *)     die "unknown model: $MODEL (use flash, astra, or provider/model)" ;;
esac

# ----------------------------------------------------------------- profile ---
CHROME_TOOLS='chrome_devtools_load,chrome_devtools_list_pages,chrome_devtools_select_page,chrome_devtools_navigate,chrome_devtools_evaluate,chrome_devtools_screenshot,chrome_devtools_snapshot,chrome_devtools_click,chrome_devtools_fill,chrome_devtools_press,chrome_devtools_wait_for,chrome_devtools_console,chrome_devtools_network,chrome_devtools_emulate,chrome_devtools_cdp_send'

case "$PROFILE" in
  search)
    TOOLS='web_search,read' PROFILE_TIMEOUT=180 SESSION_DEFAULT=off
    ROLE='Your job is to search the web and report findings. Every factual claim must carry the source URL it came from. If the searches do not answer the question, say so plainly instead of filling the gap from memory. Do not modify anything.' ;;
  recon)
    TOOLS='read,grep,find,ls' PROFILE_TIMEOUT=300 SESSION_DEFAULT=off
    ROLE='Your job is read-only reconnaissance of a codebase. Cite file:line for every claim. Never describe code you have not actually read. If the answer is not in the files, say so. Do not modify anything.' ;;
  test)
    TOOLS='bash,read,grep,find,ls' PROFILE_TIMEOUT=600 SESSION_DEFAULT=on
    ROLE='Your job is to run the requested build/tests and report what happened. You have no edit tool on purpose: do not try to fix anything. Report the failing command, the real error output, and your best diagnosis of the cause.' ;;
  edit)
    TOOLS='read,write,edit,bash,grep,find,ls' PROFILE_TIMEOUT=1200 SESSION_DEFAULT=on
    ROLE='Your job is to implement the change and verify it. Keep the diff minimal and match the style of the surrounding code. Run the project build/tests before you report. If you cannot verify, say exactly what is unverified rather than claiming success.' ;;
  browser)
    TOOLS="$CHROME_TOOLS,web_search,read" PROFILE_TIMEOUT=600 SESSION_DEFAULT=on
    ROLE='Your job is to drive a real Chrome and report what you observed. Report only what the page actually showed - console output, network results, rendered text - never what you expected it to show.' ;;
  free)
    [ -n "$EXTRA_TOOLS" ] || die "--profile free requires --tools"
    TOOLS="$EXTRA_TOOLS" PROFILE_TIMEOUT=300 SESSION_DEFAULT=off EXTRA_TOOLS=
    ROLE='Work within the tools you have been given.' ;;
  *) die "unknown profile: $PROFILE" ;;
esac

[ -n "$EXTRA_TOOLS" ] && TOOLS="$TOOLS,$EXTRA_TOOLS"

if [ -z "$TIMEOUT" ]; then
  TIMEOUT=$MODEL_TIMEOUT
  [ "$PROFILE_TIMEOUT" -gt "$TIMEOUT" ] && TIMEOUT=$PROFILE_TIMEOUT
fi

# ---------------------------------------------------------- write guardrail ---
if [ "$PROFILE" = edit ] && [ "$UNSAFE" -eq 0 ]; then
  BRANCH=$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null)
  case "$BRANCH" in
    pi/*) : ;;
    *) die "profile edit wants an isolated worktree (branch pi/*), got '${BRANCH:-no git repo}' in $CWD
       create one:  pi-wt.sh new <name>
       or override: --unsafe-in-place" ;;
  esac
fi

# ------------------------------------------------------------------ session ---
SID=
case "${SESSION:-}" in
  off)  SID= ;;
  new)  SID=$(uuidgen) ;;
  '')   [ "$SESSION_DEFAULT" = on ] && SID=$(uuidgen) ;;
  *)    SID=$SESSION ;;
esac

# ------------------------------------------------------------ system prompt ---
SYS="You are a subagent invoked by Claude Code to do one scoped task. Work autonomously and finish the task - there is no human watching this run and no one to ask.

$ROLE

Hard limits: never run git commit, git push, git reset --hard, git clean, rm -rf, or any deploy, publish or release command. Never touch files outside the working directory. Never edit git history.

Budget: you have ${TIMEOUT}s. If you are running out, stop and report what you have - a partial answer with an honest UNFINISHED section beats being killed mid-thought.

End your final message with exactly this block, in the language of the task:

## RESULT
<what you found or did>
## FILES
<files you changed, one per line, or: none>
## UNFINISHED
<anything incomplete, unverified, or needing human judgement, or: none>"

# --------------------------------------------------------------------- run ---
STAMP=$(date +%Y%m%d-%H%M%S)
SLUG=$PROFILE${LABEL:+-$LABEL}
mkdir -p "$RUN_ROOT" || die "cannot create $RUN_ROOT"
# mktemp is atomic: concurrent runs with the same label each get a directory.
LOG=$(mktemp -d "$RUN_ROOT/${STAMP}-${SLUG}.XXXXXX") || die "cannot create log dir"
RAW=$LOG/raw.jsonl

CMD=(pi -p --mode json --provider "$PROVIDER" --model "$MODEL_ID" -t "$TOOLS" --thinking "$THINKING" --append-system-prompt "$SYS")
if [ -n "$SID" ]; then CMD+=(--session-id "$SID"); else CMD+=(--no-session); fi
CMD+=(-- "$PROMPT")

{
  printf 'profile=%s model=%s/%s timeout=%ss thinking=%s\n' "$PROFILE" "$PROVIDER" "$MODEL_ID" "$TIMEOUT" "$THINKING"
  printf 'cwd=%s session=%s\n' "$CWD" "${SID:-none}"
  printf 'tools=%s\n\n' "$TOOLS"
  printf 'prompt:\n%s\n' "$PROMPT"
} > "$LOG/cmd.txt"

if [ "$DRY_RUN" -eq 1 ]; then
  printf '%q ' "${CMD[@]}"; printf '\n'
  exit 0
fi

command -v perl >/dev/null || die "perl is not on PATH (the watchdog has to be one process, not a bash sleep)"

START=$(date +%s)
# setsid + exec: PI_PID is the real pi process and the leader of its group.
# Killing the group delivers TERM to pi and to children that did not detach.
perl -e '
  use POSIX qw(setsid);
  my $dir = shift @ARGV;
  chdir $dir or die "chdir: $!\n";
  setsid() or die "setsid: $!\n";
  open STDIN, "<", "/dev/null" or die "stdin: $!\n";
  exec @ARGV or die "exec: $!\n";
' "$CWD" "${CMD[@]}" >"$RAW" 2>"$LOG/stderr.log" &
PI_PID=$!

# One perl process. Bash 3.2 does not deliver TERM to a background `sleep`,
# so a shell watchdog would keep running after this script returns.
perl -e '
  use strict;
  use warnings;
  my ($timeout, $pid, $flag, $grace) = @ARGV;
  $timeout = int($timeout);
  $pid = int($pid);
  $grace = int($grace);
  $SIG{TERM} = sub { exit 0 };
  $SIG{INT}  = sub { exit 0 };
  $SIG{HUP}  = sub { exit 0 };
  sub group_alive {
    return 1 if kill 0, -$pid;
    return 1 if kill 0, $pid;
    return 0;
  }
  my $end = time() + $timeout;
  while (time() < $end) {
    my $slice = $end - time();
    last if $slice <= 0;
    $slice = 0.2 if $slice > 0.2;
    select(undef, undef, undef, $slice);
  }
  exit 0 unless group_alive();
  open(my $fh, ">", $flag) or exit 0;
  print $fh "fired\n";
  close $fh;
  kill "TERM", -$pid;
  kill "TERM", $pid;
  $end = time() + $grace;
  while (time() < $end) {
    exit 0 unless group_alive();
    select(undef, undef, undef, 0.2);
  }
  if (group_alive()) {
    kill "KILL", -$pid;
    kill "KILL", $pid;
  }
' "$TIMEOUT" "$PI_PID" "$LOG/watchdog-fired" 10 >>"$LOG/watchdog.log" 2>&1 &
WD_PID=$!
printf '%s\n' "$WD_PID" >"$LOG/watchdog.pid"
printf '%s\n' "$PI_PID" >"$LOG/pi.pid"

stop_watchdog() {
  if [ -n "${WD_PID:-}" ]; then
    kill -TERM "$WD_PID" 2>/dev/null || true
    wait "$WD_PID" 2>/dev/null || true
    WD_PID=
  fi
}

reap_group() {
  [ -n "${PI_PID:-}" ] || return 0
  if kill -0 -- -"$PI_PID" 2>/dev/null || kill -0 "$PI_PID" 2>/dev/null; then
    kill -TERM -- -"$PI_PID" 2>/dev/null || kill -TERM "$PI_PID" 2>/dev/null || true
    sleep 0.2
    kill -KILL -- -"$PI_PID" 2>/dev/null || kill -KILL "$PI_PID" 2>/dev/null || true
  fi
  wait "$PI_PID" 2>/dev/null || true
}

on_stop() {
  stop_watchdog
  reap_group
  exit "$1"
}
trap 'on_stop 130' INT
trap 'on_stop 143' TERM
trap 'on_stop 129' HUP

RC=0
wait "$PI_PID" || RC=$?
trap - INT TERM HUP
stop_watchdog
reap_group
ELAPSED=$(( $(date +%s) - START ))

TIMED_OUT=0
# Only the watchdog flag means a timeout. An external TERM is a normal signal exit.
if [ -s "$LOG/watchdog-fired" ]; then
  TIMED_OUT=1
  RC=124
fi

# ----------------------------------------------------------------- extract ---
STATS=$(jq -Rrn '
  [inputs | select(startswith("{")) | (fromjson? // empty)] as $e
  | ($e | map(select(.type=="message_end" and .message.role=="assistant"))) as $am
  | {
      cost:   ([$am[] | .message.usage.cost.total // 0] | add // 0),
      tools:  ([$e[]  | select(.type=="tool_execution_end")] | length),
      terr:   ([$e[]  | select(.type=="tool_execution_end" and .isError==true)] | length),
      stop:   ($am | last | .message.stopReason // "none"),
      recent: ([$e[]  | select(.type=="tool_execution_end") | .toolName] | .[-3:] | join(" ")),
      think:  ([$am[] | .message.content[]? | select(.type=="thinking") | .thinking] | last // "")
    }' "$RAW" 2>/dev/null)
[ -n "$STATS" ] || STATS='{"cost":0,"tools":0,"terr":0,"stop":"none","recent":"","think":""}'
stat_of() { printf '%s' "$STATS" | jq -r ".$1 // empty"; }

FINAL=$(jq -Rrn '
  [inputs | select(startswith("{")) | (fromjson? // empty)]
  | map(select(.type=="message_end" and .message.role=="assistant")) as $am
  | ($am | last | [.message.content[]? | select(.type=="text") | .text] | join("\n")) as $last
  | if ($last | length) > 0 then $last
    else ([$am[] | .message.content[]? | select(.type=="text") | .text] | join("\n\n")) end' \
  "$RAW" 2>/dev/null)

printf '%s\n' "$FINAL" > "$LOG/result.md"

# ------------------------------------------------------------------ report ---
[ -n "$FINAL" ] && printf '%s\n' "$FINAL"

COST=$(printf '%s' "$(stat_of cost)" | awk '{ if ($1+0 < 0.0001 && $1+0 > 0) printf "<$0.0001"; else printf "$%.4f", $1 }')
TOOLS_N=$(stat_of tools); TERR=$(stat_of terr)
TOOL_TXT="$TOOLS_N tools"
[ "${TERR:-0}" -gt 0 ] 2>/dev/null && TOOL_TXT="$TOOL_TXT ($TERR failed)"

printf '\n-- pi | %s | %s | %ss | %s | %s | %s\n' \
  "$MODEL_ID" "$PROFILE" "$ELAPSED" "$COST" "$TOOL_TXT" "$LOG"
printf '   cost sums assistant usage.cost.total in this run log; it is not an account bill\n'

if [ -n "$SID" ]; then
  RESUME+=(--cwd "$CWD" --timeout "$TIMEOUT" --session "$SID" -- "...")
  printf '   session %s -- follow up:\n' "$SID"
  printf '   resume:'
  printf ' %q' "${RESUME[@]}"
  printf '\n'
fi

if [ "$TIMED_OUT" -eq 1 ]; then
  printf '   TIMED OUT after %ss - the text above is partial. Last tools: %s\n' "$TIMEOUT" "$(stat_of recent)"
  if [ -z "$FINAL" ]; then
    THINK=$(stat_of think | tr '\n' ' ' | tail -c 400)
    [ -n "$THINK" ] && printf '   it never wrote an answer; last reasoning: ...%s\n' "$THINK"
  fi
  [ -z "$SID" ] && printf '   (no session: this run cannot be resumed, rerun with --session new)\n'
elif [ "$RC" -ne 0 ]; then
  printf '   pi exited %s. stderr tail:\n' "$RC"
  tail -5 "$LOG/stderr.log" 2>/dev/null | sed 's/^/     /'
elif [ -z "$FINAL" ]; then
  printf '   no final text (stopReason=%s). stderr tail:\n' "$(stat_of stop)"
  tail -5 "$LOG/stderr.log" 2>/dev/null | sed 's/^/     /'
  RC=1
elif [ "$ELAPSED" -ge $(( TIMEOUT * 8 / 10 )) ]; then
  printf '   heads up: used %ss of a %ss budget - raise --timeout for tasks like this\n' "$ELAPSED" "$TIMEOUT"
fi

exit "$RC"
