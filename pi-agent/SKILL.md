---
name: pi-agent
description: "Delegate a scoped task to a pi coding agent running as a subagent - web research, read-only code recon, running builds and tests, and isolated code edits. Use when the user asks to hand work to pi, when a task is wide but shallow (sweep many files, check many sources) and would otherwise eat this session's context, or when several independent probes can run in parallel. Do not use for work that is faster done directly here, or for anything that must not be delegated unsupervised."
---

# pi as a subagent

`pi` is a full coding agent on this machine. `pi -p` runs it non-interactively, so it can be
handed a scoped task and report back. Two scripts wrap it:

```bash
~/.claude/skills/pi-agent/scripts/pi-run.sh   # dispatch a task
~/.claude/skills/pi-agent/scripts/pi-wt.sh    # throwaway worktrees for tasks that write code
```

Always call them by that absolute path. The skill works in any project, and `$PWD` belongs to the
task at hand, never to the skill.

> **In `pi -p` there is no approval prompt.** Every tool the subagent holds, it will use without
> asking. The tool whitelist in each profile *is* the sandbox. Never widen it casually.

## Dispatch

```bash
~/.claude/skills/pi-agent/scripts/pi-run.sh --profile recon --label auth -- "your task"
```

| Option | Default | Notes |
|---|---|---|
| `--profile` | `recon` | see the table below |
| `--model` | `flash` | `flash` or `astra`, or a full `provider/model` |
| `--cwd` | `$PWD` | pi reads the `AGENTS.md` / `CLAUDE.md` it finds here |
| `--timeout` | max(model, profile) | watchdog; SIGTERM then SIGKILL |
| `--session` | profile decides | `new` \| `<uuid>` \| `off` |
| `--thinking` | `high` | lower it only when you want speed over care |
| `--tools` | - | extra tools appended to the profile whitelist |
| `--label` | - | tags the log directory, worth setting |

The prompt goes after `--`. A leading `@path` in the prompt makes pi inline that file.

Exit codes: `0` ok, `1` pi failed, `2` bad usage, `124` timed out.

## Profiles

| profile | tools | session | writes? |
|---|---|---|---|
| `search` | `web_search,read` | off | no |
| `recon` | `read,grep,find,ls` | off | no |
| `test` | `bash,read,grep,find,ls` | on | no edit tool, on purpose |
| `edit` | `read,write,edit,bash,grep,find,ls` | on | yes, worktree only |
| `browser` | all `chrome_devtools_*`, `web_search`, `read` | on | drives real Chrome |
| `free` | whatever `--tools` says | off | depends |

`pi`'s `grep`, `find` and `ls` are off unless whitelisted, and `-t` does **not** take globs -
every tool name must be spelled out.

## Which model

Only two, and the gap between them is enormous - roughly 30x in price and 10x in latency.

**`flash`** (`deepseek/deepseek-flash`) is the default and handles most delegation: web search,
reading and summarising code, mechanical multi-file edits, running builds, drafting boilerplate.
Measured: 4s for a web search, 11s and half a cent for a 16-tool code recon.

**`astra`** (`openai-codex/gpt-6-astra`) is for work where being wrong is expensive: a bug that
survived one flash attempt, an architecture judgement, a subtle race, anything you would not
trust yourself to one-shot. It thinks slowly - 7s minimum, minutes on real tasks - so give it
room and expect roughly 25x the bill.

Escalate on evidence, not on vibes: run flash first, and reach for astra when its answer is
visibly thin, wrong, or it gives up.

## Long astra runs

astra will run past a default timeout on a real task. Two habits:

- Raise `--timeout` deliberately (1800-3000s for anything meaty). The budget is written into
  the subagent's prompt, so it knows to wrap up rather than get killed mid-thought.
- Keep the session (default for `test`/`edit`/`browser`; pass `--session new` for `recon`).
  A killed run is resumable: the footer prints the exact resume command, and the subagent keeps
  everything it had read. **A resume replays the whole context, so on astra it costs real money**
  - resuming is for salvaging work, not for chatting.

While one runs, watch it:

```bash
~/.claude/skills/pi-agent/scripts/pi-run.sh progress latest
```

## Parallel

Nothing in the scripts serialises anything. Run several read-only probes at once with the Bash
tool's `run_in_background`, each with its own `--label`, then collect. Three flash recons cost
about as much as one thought. Do not fan out `edit` jobs into the same worktree.

## Writing code

`edit` refuses to run outside a `pi/*` branch - it wants an isolated worktree:

```bash
WT=$(~/.claude/skills/pi-agent/scripts/pi-wt.sh new fix-timeout)   # prints the path
~/.claude/skills/pi-agent/scripts/pi-run.sh --profile edit --cwd "$WT" --model flash -- "..."
~/.claude/skills/pi-agent/scripts/pi-wt.sh diff fix-timeout        # read this yourself
~/.claude/skills/pi-agent/scripts/pi-wt.sh land fix-timeout        # unstaged, in the main tree
~/.claude/skills/pi-agent/scripts/pi-wt.sh drop fix-timeout
```

The worktree sits in `~/.claude/pi-worktrees/<repo>/<name>`, outside the repo. `new` symlinks
the root and workspace `node_modules` in so builds and tests actually run there; those symlinks
are excluded from every diff. `land` applies the diff to the main worktree **unstaged and
uncommitted** - the user decides what gets committed, always. `drop` refuses to discard unlanded
work unless forced.

`git apply` is not atomic: if `land` fails partway it says so, and the tree needs a look.

## Reading the result

The subagent's final message ends in a fixed block:

```
## RESULT      what it found or did
## FILES       files it changed, or none
## UNFINISHED  what is incomplete or unverified
```

Then the footer:

```
-- pi | deepseek-flash | recon | 11s | $0.0054 | 16 tools | ~/.claude/pi-runs/<run>
```

Read `UNFINISHED` before `RESULT` - it is where the subagent admits what it guessed.

**Its self-report is a claim, not evidence.** For anything it wrote: read the diff and run the
tests yourself before telling the user it works. Full transcripts, including every tool result,
are in the run directory (`raw.jsonl`, `result.md`, `cmd.txt`, `stderr.log`).

## Judgement

Delegate work that is wide but shallow, mechanical, or independently verifiable. Keep work that
needs this conversation's context, that is faster done directly, or where a wrong answer is hard
to detect.

The subagent is told never to run `git commit`, `git push`, `git reset --hard`, `rm -rf`, or any
deploy command, and never to leave its working directory. Do not hand it a task that needs one of
those anyway - do that part yourself, where the user can see it.
