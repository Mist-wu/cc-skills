#!/usr/bin/env python3
"""用本机 Codex OAuth 会话生图。

外层对话模型默认 gpt-6-luna，生图工具默认 gpt-image-2.5。
请求身份对齐本机 Codex TUI（originator=codex-tui，CLI 0.158.0）。
旧的 codex_cli_rs/0.125.0 会被 ChatGPT 账号拒绝 gpt-6-luna。
访问令牌运行时向 pi 读取，不写入本文件。
"""

from __future__ import annotations

import argparse
import base64
import json
import platform
import subprocess
import sys
import uuid
import urllib.error
import urllib.request
from pathlib import Path

CODEX_URL = "https://chatgpt.com/backend-api/codex/responses"
AUTH_PATH = Path.home() / ".pi" / "agent" / "auth.json"
DEFAULT_OUTER_MODEL = "gpt-6-luna"
DEFAULT_IMAGE_MODEL = "gpt-image-2.5"


def bearer_token() -> str:
    try:
        token = subprocess.check_output(
            ["pi", "auth", "print-bearer-token", "--provider", "openai-codex"],
            text=True,
            stderr=subprocess.PIPE,
        ).strip()
    except subprocess.CalledProcessError as exc:
        detail = (exc.stderr or "").strip() or "pi auth 失败"
        raise SystemExit(detail) from exc
    if not token:
        raise SystemExit("pi 没有返回 Codex bearer token")
    return token


def chatgpt_account_id() -> str:
    try:
        data = json.loads(AUTH_PATH.read_text())
    except FileNotFoundError as exc:
        raise SystemExit(f"找不到 {AUTH_PATH}") from exc
    account_id = str((data.get("openai-codex") or {}).get("accountId") or "").strip()
    if not account_id:
        raise SystemExit(f"{AUTH_PATH} 里没有 openai-codex.accountId")
    return account_id


def codex_cli_version() -> str:
    raw = subprocess.check_output(["codex", "--version"], text=True, stderr=subprocess.DEVNULL).strip()
    version = raw.split()[-1]
    if not version or not version[0].isdigit():
        return "0.158.0"
    return version


def codex_user_agent(version: str) -> str:
    return f"codex_cli_rs/{version} ({platform.system().lower()}; {platform.machine()})"


def build_body(
    prompt: str,
    outer_model: str,
    image_model: str,
    size: str,
    quality: str,
    session_id: str,
) -> dict:
    return {
        "model": outer_model,
        "instructions": "You are a helpful assistant.",
        "stream": True,
        "store": False,
        "reasoning": {"effort": "low", "summary": "auto"},
        "parallel_tool_calls": True,
        "include": ["reasoning.encrypted_content"],
        "text": {"verbosity": "low"},
        "prompt_cache_key": session_id,
        "tool_choice": {"type": "image_generation"},
        "input": [
            {
                "type": "message",
                "role": "user",
                "content": [{"type": "input_text", "text": prompt}],
            }
        ],
        "tools": [
            {
                "type": "image_generation",
                "action": "generate",
                "model": image_model,
                "size": size,
                "quality": quality,
                "output_format": "png",
            }
        ],
    }


def request_sse(body: dict, token: str, account_id: str, session: str, timeout: int) -> tuple[int, str]:
    version = codex_cli_version()
    req = urllib.request.Request(
        CODEX_URL,
        data=json.dumps(body).encode(),
        method="POST",
        headers={
            "Authorization": "Bearer " + token,
            "Content-Type": "application/json",
            "Accept": "text/event-stream",
            "OpenAI-Beta": "responses=experimental",
            "originator": "codex-tui",
            "version": version,
            "User-Agent": codex_user_agent(version),
            "chatgpt-account-id": account_id,
            "session-id": session,
            "x-client-request-id": session,
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")
        raise SystemExit(f"上游 HTTP {exc.code}: {detail[:2000]}") from exc


def iter_sse(text: str):
    for line in text.splitlines():
        if not line.startswith("data:"):
            continue
        data = line[5:].strip()
        if not data or data == "[DONE]":
            continue
        try:
            yield json.loads(data)
        except json.JSONDecodeError:
            continue


def take_image(item: dict, current: str | None) -> str | None:
    if item.get("type") != "image_generation_call":
        return current
    result = str(item.get("result") or "").strip()
    if result.startswith("data:") and "," in result:
        result = result.split(",", 1)[1]
    if result and (current is None or len(result) > len(current)):
        return result
    return current


def parse_response(text: str) -> tuple[str | None, dict | None, str | None]:
    image_b64 = None
    usage = None
    error = None
    for event in iter_sse(text):
        kind = event.get("type")
        if kind == "error" or (kind != "response.completed" and event.get("error")):
            error = json.dumps(event.get("error") or event, ensure_ascii=False)
        if kind == "response.output_item.done":
            image_b64 = take_image(event.get("item") or {}, image_b64)
        if kind == "response.completed":
            response = event.get("response") or {}
            usage = response.get("usage") or usage
            for item in response.get("output") or []:
                image_b64 = take_image(item, image_b64)
    return image_b64, usage, error


def main() -> None:
    parser = argparse.ArgumentParser(description="用本机 Codex 会话调用 gpt-image-2.5")
    parser.add_argument("prompt", help="生图提示词")
    parser.add_argument("-o", "--output", default="codex-image.png", help="输出 PNG 路径")
    parser.add_argument("--outer-model", default=DEFAULT_OUTER_MODEL, help="外层对话模型")
    parser.add_argument("--image-model", default=DEFAULT_IMAGE_MODEL, help="生图工具模型")
    parser.add_argument("--size", default="1024x1024")
    parser.add_argument("--quality", default="medium")
    parser.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args()

    prompt = args.prompt.strip()
    if not prompt:
        raise SystemExit("提示词不能为空")

    session_id = str(uuid.uuid4())
    body = build_body(
        prompt,
        args.outer_model,
        args.image_model,
        args.size,
        args.quality,
        session_id,
    )
    status, text = request_sse(body, bearer_token(), chatgpt_account_id(), session_id, args.timeout)
    image_b64, usage, error = parse_response(text)
    if error and not image_b64:
        raise SystemExit(error)
    if not image_b64:
        raise SystemExit(f"HTTP {status}，上游没有返回图片")

    image = base64.b64decode(image_b64)
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(image)
    print(
        json.dumps(
            {
                "http_status": status,
                "outer_model": args.outer_model,
                "image_model": args.image_model,
                "bytes": len(image),
                "output": str(output),
                "usage": usage,
            },
            ensure_ascii=False,
        )
    )


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
