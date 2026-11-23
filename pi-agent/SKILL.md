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
> asking. Profiles limit available tool names. A profile with `bash` can still write files.

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
| `browser` | core `chrome_devtools_*` names, `web_search`, `read` | on | drives real Chrome |
| `free` | whatever `--tools` says | off | depends |

`-t` accepts exact tool names and `*` patterns. Pi ignores unknown names. Install
`websearch` for `search` and both `websearch` and `chrome-devtools` for `browser`.
The browser profile lists the core Chrome tools individually to exclude WebMCP tools,
which cannot run under `pi -p`.

## Which model

Use `flash` (`deepseek/deepseek-flash`) for routine searches, code reading, builds and
mechanical edits. Use `astra` (`openai-codex/gpt-6-astra`) for architectural decisions,
subtle races, or a task flash could not resolve. Pass a full `provider/model` to use another
installed model. Check the local catalog with `pi --list-models`.

## Long runs

- Raise `--timeout` deliberately (1800-3000s for anything meaty). The budget is written into
  the subagent's prompt, so it knows to wrap up rather than get killed mid-thought.
- Keep the session (default for `test`/`edit`/`browser`; pass `--session new` for `recon`).
  The footer prints a shell-quoted `resume:` command with the supplied options, working
  directory, timeout and session ID. Resuming replays the session context.
- Exit `124` means the watchdog fired: it sent `TERM` to the pi process group, then `KILL`
  after 10 seconds if the group was still alive. An external `TERM`, or you interrupting the
  wrapper, is not reported as a timeout. The wrapper reaps that process group before it returns.

While one runs, watch it:

```bash
~/.claude/skills/pi-agent/scripts/pi-run.sh progress latest
```

## Parallel

Nothing in the scripts serialises anything. Run several read-only probes at once with the Bash
tool's `run_in_background`, each with its own `--label`, then collect. Do not fan out `edit`
jobs into the same worktree.

## Writing code

`edit` only checks that the branch name starts with `pi/`. A main worktree checked out on
`pi/something` passes that check. Use `pi-wt.sh` when you actually want a linked worktree:

```bash
WT=$(~/.claude/skills/pi-agent/scripts/pi-wt.sh new fix-timeout)   # prints the path
~/.claude/skills/pi-agent/scripts/pi-run.sh --profile edit --cwd "$WT" --model flash -- "..."
~/.claude/skills/pi-agent/scripts/pi-wt.sh diff fix-timeout        # read this yourself
~/.claude/skills/pi-agent/scripts/pi-wt.sh land fix-timeout        # unstaged, in the main tree
~/.claude/skills/pi-agent/scripts/pi-wt.sh drop fix-timeout
```

`new` registers the worktree with git and puts it under `~/.claude/pi-worktrees/<repo-key>/<name>`.
The key is the repository id, not the directory's basename, so two repos with the same folder
name do not share a worktree. `new` symlinks the root and workspace `node_modules` in so builds
and tests actually run there. Only those exact symlinks are left out of the diff. A real
`node_modules` directory is not a dependency link: untracked files in it are kept.

`land` copies the worktree's committed, staged, unstaged, and untracked bytes into the main
**working tree** and does not stage them. It will not create or replace a file by following a
symlink ancestor, so a link inside the main tree cannot redirect the write. It compares whole files. A repeated hunk elsewhere in
the file cannot satisfy the check. If the main index already has changes on a path being
landed, or the main file has diverged so the result would not stay an exact unstaged copy,
`land` stops before it changes the index and keeps the patch. Overlapping edits are not
auto-merged. An empty `land` does not delete an existing patch. A newer patch renames the
previous one to `*.patch.bak.<time>` instead of overwriting it.

`drop` without `--force` removes the worktree only when all of these hold:

- git has this worktree registered on branch `pi/<name>` in **this** repository
- that path is not the main worktree
- the index and the working tree do not disagree
- status and the index can be read (`index.lock` keeps the worktree)
- the branch has no commits that the main branch does not already have. A commit that
  exists only on `pi/<name>` keeps both the worktree and the branch, even when the files on
  disk have been put back to the baseline. Ordinary `drop` does not run `branch -D` for it
- every changed path is already byte-for-byte in the main working tree, including untracked
  files inside a real `node_modules` directory

It refuses a different repository, a branch that is no longer `pi/<name>`, edits made on either
side after `land`, and a main file that only happens to contain the same hunk somewhere else.
`--force` still requires the same identity and a readable worktree. It discards commits, the
index, and untracked files in that worktree only. It does not change the main index or the main
working tree, and it does not remove a worktree that has been switched to another branch.

Removing the directory also deletes gitignored files that live only there, including files you
created. Those files are not copied to the main worktree. `node_modules` symlinks created by
`new` are removed; their targets stay. `drop` does not delete the recovery patch.

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
   cost sums assistant usage.cost.total in this run log; it is not an account bill
```

`$0.0054` is the sum of `message.usage.cost.total` on assistant messages in this run's
`raw.jsonl`. Pi's own session total can also include tool and compaction usage. A resume is a
new run with its own sum. Two assistant messages of `0.20` and `0.30` print `$0.5000`.

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
