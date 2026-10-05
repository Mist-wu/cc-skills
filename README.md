<div align="center">

# cc-skills

**我自己写、每天在用的 Claude Code 技能。**

目前收录三个技能：

- pi-agent：让 Claude Code 把调研、查代码、跑测试和隔离修改交给 [pi](https://pi.dev) 子代理完成。
- bvsum：总结 B站视频。下载音频，取官方字幕或本地转录，必要时联网补充，按视频内容自由组织总结。
- codex-image：借本机 pi 登录的 Codex（ChatGPT 账号）会话调用 gpt-image-2.5 生图，也能传入图片改图、换风格、多图合成，不需要 OpenAI API key。

[![Claude Code](https://img.shields.io/badge/Claude%20Code-skill-d97757)](https://claude.com/claude-code)
[![pi](https://img.shields.io/badge/pi-subagent-2563eb)](https://pi.dev)
[![bash](https://img.shields.io/badge/bash-3.2%2B-4EAA25?logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![License](https://img.shields.io/badge/license-MIT-22c55e)](LICENSE)

</div>

---

## 亮点

- 按权限分档的子代理：pi-agent 提供 `search`、`recon`、`test`、`edit`、`browser` 和 `free` 六个档位，每档是一份工具白名单。`pi -p` 执行任何工具都不会询问，所以白名单就是沙箱。
- 写操作隔离：`edit` 档只能在 `pi/*` git worktree 里运行。改动以未暂存 diff 的形式回到主工作区，不会替你提交。
- 记录花费：每次任务返回结果时附带花费、工具调用次数和完整对话记录，日志存在 `~/.claude/pi-runs/`。
- 两个模型：`deepseek-flash` 处理面广但简单的任务，`gpt-6-astra` 处理必须做对的任务。
- 超时可续跑：`gpt-6-astra` 的长任务保留会话。任务被看门狗终止后，可以带着已读过的内容继续，不用从头开始。
- B站视频总结：bvsum 读完整份字稿再动笔，必要时用 WebSearch 补充。总结不套固定模板，形式由视频内容决定。
- 用订阅额度生图：codex-image 运行时向 `pi auth` 取 Codex 令牌，请求身份对齐本机 Codex CLI，令牌不落盘。出图后 Claude 会自己打开检查，不对就改提示词重试。
- 兼容 macOS 自带 bash：脚本按 bash 3.2 编写，不需要装 coreutils 或 Homebrew 版 bash。

## 工作原理

```
Claude Code ──pi-run.sh --profile <档位>──> pi -p（子代理）
                                              │
                    ┌─────────────────────────┤
                    ▼                         ▼
             只读档：直接在当前目录运行    edit 档：pi-wt.sh 建临时 worktree
                    │                         │
                    ▼                         ▼
             返回结论 + 花费 + 记录        返回结论 + 未暂存 diff
```

## 快速开始

```bash
git clone https://github.com/Mist-wu/cc-skills.git
ln -s "$PWD/cc-skills/pi-agent" ~/.claude/skills/pi-agent
```

每个技能是一个带 `SKILL.md` 的目录，Claude Code 从 `~/.claude/skills/<名字>/` 加载。这里一个目录对应一个技能，目录名就是安装后的名字，需要哪个就链接哪个。

pi-agent 依赖 `pi`、`jq` 和 `git`。运行日志默认写到 `~/.claude/pi-runs/`，worktree 写到 `~/.claude/pi-worktrees/`，可以用 `PI_RUN_DIR` 和 `PI_WT_DIR` 改位置。

bvsum 依赖 Python 3、ffmpeg，以及 `uvx`（mlx-whisper）或 `whisper-cli`。音频和字稿写到 `/tmp/bvsum/<BV号>/`，重启后清空。pi 版本在 [pi-extensions](https://github.com/Mist-wu/pi-extensions) 里。

codex-image 依赖 Python 3、已登录 openai-codex 的 `pi`（账号 ID 读 `~/.pi/agent/auth.json`），以及 `codex` CLI（用来取版本号拼请求头）。

## 使用

安装后直接对 Claude Code 说“交给 pi 查一下……”即可触发 pi-agent；发一个 B站链接说“总结一下”即可触发 bvsum；说“生一张……的图”或给出图片路径说“把这张图改成……”即可触发 codex-image。也可以手动调用脚本：

```bash
~/.claude/skills/pi-agent/scripts/pi-run.sh --profile recon --label auth -- "找出登录流程涉及的文件"
```

## 项目结构

```text
cc-skills/
├── pi-agent/
│   ├── SKILL.md          # Claude 每次都会读的部分
│   ├── scripts/          # pi-run.sh、pi-wt.sh
│   └── reference/        # 按需读取，不进提示词
├── bvsum/
│   ├── SKILL.md
│   └── scripts/          # prepare.py：下载音频、取字幕或转录
└── codex-image/
    ├── SKILL.md
    └── scripts/          # codex_image.py：用 Codex 会话生图
```

`SKILL.md` 要保持简短，每次加载才划算。模型列表、协议说明这类长内容放在 `reference/`，只有真正打开时才占用上下文。

## License

[MIT](LICENSE)
