# Models

The skill exposes two aliases on purpose. A middle tier sounds useful and in practice just makes
the choice slower.

| alias | id | context | price in / out (per M) | measured |
|---|---|---|---|---|
| `flash` | `deepseek/deepseek-flash` | 1M | $0.30 / $1.20 | 4s web search, 11s 16-tool recon |
| `astra` | `openai-codex/gpt-6-astra` | 272K | $10 / $50 | 7s trivial answer, minutes on real work |

Above 272K input tokens astra doubles to $20 / $75. flash's 1M context is the reason bulk
read-only sweeps go to flash regardless of difficulty - it can hold what astra cannot.

Snapshot taken 2026-09-10 from pi's own catalog. To refresh:

```bash
pi --list-models
pi update
```

## Anything else installed

`pi --list-models` also shows `deepseek-v4-pro`, `deepseek-v4-flash`, and the `openai-codex`
`gpt-5.x` line, several of which sit between the two tiers on price. They are reachable without
touching the scripts:

```bash
pi-run.sh --model deepseek/deepseek-v4-pro --profile edit --cwd "$WT" -- "..."
```

A full `provider/model` gets a 600s default timeout, so set `--timeout` explicitly for anything
slow.

## Thinking

Every run passes `--thinking high` unless told otherwise; that matches the machine's own pi
default. Drop to `low` or `minimal` when a flash task is trivial and latency is what matters -
it is worth a second or two on a quick search, and nothing on a task with many tool calls.

## Tools

Extension tools come from the user's installed pi packages, so the whitelists in `pi-run.sh`
assume `websearch` (`web_search`) and `chrome-devtools` (`chrome_devtools_*`) are installed. If
a package is removed, the matching profile silently loses its tools - pi does not error on an
unknown name in `-t`. Check with:

```bash
pi -p --no-session -t read "List your available tool names, one per line. Do not call any tool."
```

`-t` matches names literally: no globs, no prefixes.
