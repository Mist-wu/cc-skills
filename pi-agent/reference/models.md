# Models

The skill exposes two aliases on purpose. A middle tier sounds useful and in practice just makes
the choice slower.

| alias | id | context | catalog price in / out (per M) |
|---|---|---|---|
| `flash` | `deepseek/deepseek-flash` | 1M | $0.30 / $1.20 |
| `astra` | `openai-codex/gpt-6-astra` | 272000 | $10 / $50 |

flash's 1M context is why bulk read-only sweeps go to flash: it can hold what astra cannot.

Checked against the local pi catalog on 2026-11-23. Astra's catalog also has a higher tier
when input tokens are greater than 272000: input $10 to $20, output $50 to $75. That is a
catalog rule, not a measured bill. The context window field itself is 272000. To refresh:

```bash
pi --list-models
pi update
```

## Anything else installed

`pi --list-models` on 2026-11-23 shows `deepseek-v4-pro` beside `deepseek-flash`, and on
`openai-codex` the `gpt-5.6`, `gpt-6` and `gpt-6.1` lines. `deepseek-v4-flash` and the `gpt-5.x`
names from the September snapshot are no longer in that catalog. Several of the current ids sit
between the two tiers on price. They are reachable without touching the scripts:

```bash
~/.claude/skills/pi-agent/scripts/pi-run.sh --model deepseek/deepseek-v4-pro --profile edit --cwd "$WT" -- "..."
```

A full `provider/model` only sets the model default of 600s. `pi-run.sh` then uses the greater
of that and the profile default, unless you pass `--timeout`. The `edit` profile's own default
is 1200s, so `edit` is at least 1200s unless you override it. `astra`'s model default is already
1200s. Set `--timeout` when the task needs longer than that.

## Thinking

Every run passes `--thinking high` unless told otherwise; that matches the machine's own pi
default. On `deepseek-flash` in Pi 1.5.2, `thinkingLevelMap` marks `minimal` and `medium` as
`null`. Pi clamps `minimal` up to `low` and `medium` up to `high`. `off` is not in that map and
stays available. For a fast flash task, pass `--thinking low`.

## Tools

Extension tools come from the user's installed pi packages, so the whitelists in `pi-run.sh`
assume `websearch` (`web_search`) and `chrome-devtools` (`chrome_devtools_*`) are installed. If
a package is removed, the matching profile silently loses its tools. Unknown names in `-t` are
ignored. Exact names and `*` patterns both work. `+name` and `-name` are exact names only, and
cannot be mixed into an allowlist. Check with:

```bash
pi -p --no-session -t read "List your available tool names, one per line. Do not call any tool."
```
