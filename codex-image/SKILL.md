---
name: codex-image
description: 用本机 pi 的 Codex（ChatGPT 账号）会话调 gpt-image-2.5 生图。用户要求画图、生成图片、做插画/海报/图标/配图、"生图"时使用。
allowed-tools: Bash, Read
---

# Codex 生图

## 1. 生成

```bash
python3 ~/.claude/skills/codex-image/scripts/codex_image.py '<提示词>' -o <输出路径.png> [--size 1024x1024] [--quality medium]
```

- 令牌运行时通过 `pi auth print-bearer-token --provider openai-codex` 取，账号 ID 读 `~/.pi/agent/auth.json`。不要打印或保存令牌。
- `--size`：`1024x1024`（默认）、`1536x1024`（横）、`1024x1536`（竖）。
- `--quality`：`low` / `medium`（默认）/ `high`。草稿用 `low`，定稿再用 `high`。
- 一张图通常 30–90 秒，`timeout` 给 240000 以上。
- 成功时 stdout 输出一行 JSON，`output` 是图片路径。

输出路径：用户指定了就用用户的；在项目里做配图就放进项目合适的目录；否则放 scratchpad。

## 2. 提示词

用户给的是中文或很简略的描述时，改写成具体的英文提示词：主体、构图、风格、配色、光线、画面比例。图里需要文字时，把文字原样放进引号里。用户明确给了完整提示词就原样使用。

## 3. 交付

用 Read 打开生成的 PNG 自己看一眼，确认内容符合要求（主体对、没有明显崩坏、文字没拼错）。不符合就调整提示词重试一次，再告诉用户。

最后告诉用户文件路径，用 SendUserFile 把图片发给用户。

## 失败处理

- `pi auth 失败` / 401：Codex 登录过期，让用户在终端运行 `pi` 重新登录 openai-codex。
- 上游 HTTP 4xx 提到模型不可用：把原始报错告诉用户，可以用 `--outer-model` / `--image-model` 换模型再试。请求头要对齐本机 `codex --version`，旧版本号会被拒。
- 上游没有返回图片：通常是内容被拒，改写提示词后重试。
