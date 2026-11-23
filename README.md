<div align="center">

# cc-skills

**我自己写、每天在用的 Claude Code 技能。**

目前收录三个技能：

- pi-agent：让 Claude Code 把调研、查代码、跑测试和隔离修改交给 [pi](https://pi.dev) 子代理完成。
- bvsum：总结 B 站视频。下载音频，取官方字幕或本地转录，必要时联网补充。
- image-gen：借本机 pi 登录的 Codex（ChatGPT 账号）会话生图或改图，不需要 OpenAI API key。

[![Claude Code](https://img.shields.io/badge/Claude%20Code-skill-d97757)](https://claude.com/claude-code)
[![pi](https://img.shields.io/badge/pi-subagent-2563eb)](https://pi.dev)
[![bash](https://img.shields.io/badge/bash-3.2%2B-4EAA25?logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![License](https://img.shields.io/badge/license-MIT-22c55e)](LICENSE)

</div>

---

## 安装

新环境先创建技能目录，再克隆仓库，按需要链接。

```bash
mkdir -p ~/.claude/skills
git clone https://github.com/Mist-wu/cc-skills.git
ln -s "$PWD/cc-skills/pi-agent" ~/.claude/skills/pi-agent
ln -s "$PWD/cc-skills/bvsum" ~/.claude/skills/bvsum
ln -s "$PWD/cc-skills/image-gen" ~/.claude/skills/image-gen
```

每个技能是一个带 `SKILL.md` 的目录。Claude Code 从 `~/.claude/skills/<名字>/` 加载。需要哪个就链接哪个。

## 依赖

pi-agent 依赖 `pi`、`jq`、`git`，以及系统自带的 `perl`（看门狗要能在脚本退出时停掉）。运行日志默认写到 `~/.claude/pi-runs/`，worktree 写到 `~/.claude/pi-worktrees/`，可以用 `PI_RUN_DIR` 和 `PI_WT_DIR` 改位置。档位、模型和 worktree 的删除规则写在 [pi-agent/SKILL.md](pi-agent/SKILL.md)。这里用到的 pi 扩展在 [pi-extensions](https://github.com/Mist-wu/pi-extensions)。

bvsum 依赖 Python 3（本机 `/usr/bin/python3` 3.9.6 跑过 `--help`、短链和字稿复用）、ffmpeg，以及 `uvx`（mlx-whisper）或 `whisper-cli`。音频和字稿写到 `/tmp/bvsum/<BV号>/`，重启后清空。Pi 里还有一份同名入口：[Pi 版 bvsum](https://github.com/Mist-wu/pi-extensions/blob/main/skills/bvsum/SKILL.md)。

image-gen 依赖 Python 3、已登录 openai-codex 的 `pi`（账号 ID 读 `~/.pi/agent/auth.json`），以及 `codex` CLI（用来取版本号拼请求头）。版本号解析失败时脚本会停，不会改用旧版本号。

## 使用

安装后直接对 Claude Code 说“交给 pi 查一下……”即可触发 pi-agent；发一个 B 站链接说“总结一下”即可触发 bvsum；说“生一张……的图”或给出图片路径说“把这张图改成……”即可触发 image-gen。也可以手动调用脚本：

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
└── image-gen/
    ├── SKILL.md
    └── scripts/          # codex_image.py：用 Codex 会话生图
```

`SKILL.md` 要保持简短，每次加载才划算。模型列表、协议说明这类长内容放在 `reference/`，只有真正打开时才占用上下文。

## License

[MIT](LICENSE)
