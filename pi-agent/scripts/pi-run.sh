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
  DIR=${2:-latest}
  [ "$DIR" = "latest" ] && DIR=$(ls -dt "$RUN_ROOT"/*/ 2>/dev/null | head -1)
  [ -n "$DIR" ] && [ -d "$DIR" ] || die "no run directory found"
  DIR=${DIR%/}
  printf 'run: %s\n' "$DIR"
  [ -f "$DIR/cmd.txt" ] && sed -n '1,2p' "$DIR/cmd.txt"
  if [ -f "$DIR/raw.jsonl" ]; then
    printf 'elapsed: %ss\n' "$(( $(date +%s) - $(stat -f %B "$DIR/raw.jsonl" 2>/dev/null || echo "$(date +%s)") ))"
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
PROFILE=recon MODEL=flash CWD=$PWD TIMEOUT= SESSION= THINKING=high
EXTRA_TOOLS= LABEL= PROMPT= DRY_RUN=0 UNSAFE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --profile)        [ $# -ge 2 ] || die "--profile needs a value"; PROFILE=$2; shift 2 ;;
    --model)          [ $# -ge 2 ] || die "--model needs a value"; MODEL=$2; shift 2 ;;
    --cwd)            [ $# -ge 2 ] || die "--cwd needs a value"; CWD=$2; shift 2 ;;
    --timeout)        [ $# -ge 2 ] || die "--timeout needs a value"; TIMEOUT=$2; shift 2 ;;
    --session)        [ $# -ge 2 ] || die "--session needs a value"; SESSION=$2; shift 2 ;;
    --thinking)       [ $# -ge 2 ] || die "--thinking needs a value"; THINKING=$2; shift 2 ;;
    --tools)          [ $# -ge 2 ] || die "--tools needs a value"; EXTRA_TOOLS=$2; shift 2 ;;
    --label)          [ $# -ge 2 ] || die "--label needs a value"; LABEL=$2; shift 2 ;;
    --unsafe-in-place) UNSAFE=1; shift ;;
    --dry-run)        DRY_RUN=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    --)               shift; PROMPT=$*; break ;;
    *)                die "unknown option: $1 (the prompt goes after --)" ;;
  esac
done

[ -n "$PROMPT" ] || { usage >&2; die "no prompt (put it after --)"; }
[ -d "$CWD" ] || die "--cwd is not a directory: $CWD"
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
LOG=$RUN_ROOT/$STAMP-$SLUG
[ -e "$LOG" ] && LOG=$LOG-$$
mkdir -p "$LOG" || die "cannot create log dir $LOG"
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

START=$(date +%s)
( cd "$CWD" && "${CMD[@]}" ) >"$RAW" 2>"$LOG/stderr.log" &
PI_PID=$!
( sleep "$TIMEOUT"; kill -TERM "$PI_PID" 2>/dev/null; sleep 10; kill -KILL "$PI_PID" 2>/dev/null ) >/dev/null 2>&1 &
WD_PID=$!
RC=0; wait "$PI_PID" || RC=$?
kill "$WD_PID" 2>/dev/null; wait "$WD_PID" 2>/dev/null
ELAPSED=$(( $(date +%s) - START ))

TIMED_OUT=0
if [ "$RC" -eq 143 ] || [ "$RC" -eq 137 ] || { [ "$RC" -ne 0 ] && [ "$ELAPSED" -ge "$TIMEOUT" ]; }; then
  TIMED_OUT=1; RC=124
fi

# ----------------------------------------------------------------- extract ---
STATS=$(jq -Rrn '
  [inputs | select(startswith("{")) | (fromjson? // empty)] as $e
  | ($e | map(select(.type=="message_end" and .message.role=="assistant"))) as $am
  | {
      cost:   ([$am[] | .message.usage.cost.total // 0] | add // 0),
      tin:    ([$am[] | .message.usage.input      // 0] | add // 0),
      tout:   ([$am[] | .message.usage.output     // 0] | add // 0),
      tools:  ([$e[]  | select(.type=="tool_execution_end")] | length),
      terr:   ([$e[]  | select(.type=="tool_execution_end" and .isError==true)] | length),
      stop:   ($am | last | .message.stopReason // "none"),
      recent: ([$e[]  | select(.type=="tool_execution_end") | .toolName] | .[-3:] | join(" ")),
      think:  ([$am[] | .message.content[]? | select(.type=="thinking") | .thinking] | last // "")
    }' "$RAW" 2>/dev/null)
[ -n "$STATS" ] || STATS='{"cost":0,"tin":0,"tout":0,"tools":0,"terr":0,"stop":"none","recent":"","think":""}'
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

if [ -n "$SID" ]; then
  printf '   session %s -- follow up: pi-run.sh --profile %s --model %s --cwd %s --session %s -- "..."\n' \
    "$SID" "$PROFILE" "$MODEL" "$CWD" "$SID"
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
