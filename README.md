<div align="center">

# cc-skills

**Claude Code skills I build and actually use.**

<br/>

[![Claude Code](https://img.shields.io/badge/Claude%20Code-skill-d97757)](https://claude.com/claude-code)
[![pi](https://img.shields.io/badge/pi-subagent-2563eb)](https://pi.dev)
[![bash](https://img.shields.io/badge/bash-3.2%2B-4EAA25?logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![License](https://img.shields.io/badge/license-MIT-22c55e)](https://opensource.org/license/mit)

</div>

---

```bash
git clone https://github.com/Mist-wu/cc-skills.git
ln -s "$PWD/cc-skills/pi-agent" ~/.claude/skills/pi-agent
```

A skill is a directory with a `SKILL.md`, loaded from `~/.claude/skills/<name>/`. One directory
here per skill, named exactly as it should land — symlink the ones you want, skip the rest.

<br/>

## [pi-agent](./pi-agent) — hand work to Pi

Claude Code hands a scoped task to [pi](https://pi.dev) running as a subagent under `pi -p`: web
research, read-only code recon, builds and tests, or an edit fenced into a throwaway git worktree.
The answer comes back with its cost, its tool count, and a full transcript on disk.

```
search   recon   test   edit   browser   free
```

Each profile is a tool whitelist, because `pi -p` runs every tool it holds without ever asking.
Two models and a wide gap between them: `deepseek-flash` for breadth, `gpt-6-astra` for the ones
that have to be right.

Writes are fenced. The `edit` profile refuses to run outside a `pi/*` worktree, and the result
lands back in the main tree as an unstaged diff — nothing gets committed on your behalf.

Long `gpt-6-astra` runs keep a session, so a task killed by the watchdog resumes holding
everything it had already read instead of starting from nothing.

<br/>

## Layout

```text
cc-skills/
└── pi-agent/
    ├── SKILL.md          # the part Claude reads every time
    ├── scripts/          # pi-run.sh, pi-wt.sh
    └── reference/        # read on demand, never in the prompt
```

Keep `SKILL.md` short enough to stay worth loading. Anything long — model catalogs, protocol
notes, tables nobody needs mid-task — belongs in `reference/`, where it costs nothing until it
is actually opened.

## Requirements

`pi-agent` shells out to `pi` and `jq`, and needs `git` for its worktrees. Run logs go to
`~/.claude/pi-runs/`, worktrees to `~/.claude/pi-worktrees/`; `PI_RUN_DIR` and `PI_WT_DIR`
override both. The scripts are written for bash 3.2, so stock macOS is enough — no coreutils,
no Homebrew bash.

## License

MIT.
