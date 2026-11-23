#!/usr/bin/env python3
"""Download audio and prepare official subtitles or a local transcript for a Bilibili video.

Output goes to /tmp/bvsum/<BV号>/ (cleared on reboot).

Usage:
  python3 prepare.py URL_OR_BVID [--language auto|zh|en] [--force] [--no-audio]
"""

from __future__ import annotations

import argparse
import fcntl
import html
import json
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

API = "https://api.bilibili.com"
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/138 Safari/537.36"
DEFAULT_OUTPUT = Path("/tmp/bvsum")
MLX_MODEL = "mlx-community/whisper-small-mlx"
MLX_CACHE = Path.home() / ".cache" / "huggingface" / "hub" / "models--mlx-community--whisper-small-mlx"
WHISPER_CPP_MODEL = Path.home() / ".cache" / "whisper" / "ggml-small-q5_1.bin"


def log(message: str) -> None:
    print(f"[bvsum] {message}", file=sys.stderr, flush=True)


BILIBILI_HOSTS = {
    "b23.tv",
    "www.b23.tv",
    "bilibili.com",
    "www.bilibili.com",
    "m.bilibili.com",
}
BV_ERROR = "未找到有效 BV 号；请传入 Bilibili URL、b23.tv 短链或 BVxxxxxxxxxx"


def extract_bvid(value: str) -> str:
    match = re.search(r"BV[0-9A-Za-z]{10}", value)
    if not match:
        raise ValueError(BV_ERROR)
    return match.group(0)


def _host(url: str) -> str:
    return (urllib.parse.urlparse(url).hostname or "").lower()


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


_VIDEO_PATH = re.compile(r"/video/(BV[0-9A-Za-z]{10})(?:/|$)")


def bvid_from_video_url(url: str, hosts: set[str]) -> str | None:
    """BV id from a /video/<BV> path on an allowed host. Query text is ignored."""
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme not in ("http", "https") or _host(url) not in hosts:
        return None
    match = _VIDEO_PATH.search(parsed.path)
    return match.group(1) if match else None


def canonical_urls(page: str) -> list[str]:
    """href/content of rel=canonical and og:url only, not every BV in the page."""
    found: list[str] = []
    for tag in re.findall(r"<link\b[^>]*>", page, flags=re.I):
        if not re.search(r"\brel\s*=\s*['\"]canonical['\"]", tag, flags=re.I):
            continue
        href = re.search(r"\bhref\s*=\s*['\"]([^'\"]+)['\"]", tag, flags=re.I)
        if href:
            found.append(html.unescape(href.group(1)))
    for tag in re.findall(r"<meta\b[^>]*>", page, flags=re.I):
        if not re.search(r"\bproperty\s*=\s*['\"]og:url['\"]", tag, flags=re.I):
            continue
        content = re.search(r"\bcontent\s*=\s*['\"]([^'\"]+)['\"]", tag, flags=re.I)
        if content:
            found.append(html.unescape(content.group(1)))
    return found


def _follow_bvid(start: str, hosts: set[str]) -> tuple[str, str]:
    opener = urllib.request.build_opener(_NoRedirect)
    current = start
    seen: set[str] = set()
    for _ in range(5):
        if current in seen:
            break
        seen.add(current)
        request = urllib.request.Request(
            current,
            headers={"User-Agent": UA, "Referer": "https://www.bilibili.com/"},
            method="GET",
        )
        try:
            with opener.open(request, timeout=20) as response:
                final = response.geturl()
                head = response.read(65536)
        except urllib.error.HTTPError as exc:
            if exc.code not in (301, 302, 303, 307, 308):
                raise RuntimeError(f"短链解析失败：HTTP {exc.code}") from exc
            location = exc.headers.get("Location")
            if not location:
                break
            nxt = urllib.parse.urljoin(exc.geturl() or current, location)
            parsed = urllib.parse.urlparse(nxt)
            # A foreign host is not followed, even when its URL contains a BV id.
            if parsed.scheme not in ("http", "https") or _host(nxt) not in hosts:
                break
            found = bvid_from_video_url(nxt, hosts)
            if found:
                return found, nxt
            current = nxt
            continue
        else:
            if _host(final) not in hosts:
                break
            found = bvid_from_video_url(final, hosts)
            if found:
                return found, final
            text = head.decode("utf-8", "replace")
            for raw_url in canonical_urls(text):
                absolute = urllib.parse.urljoin(final, raw_url)
                found = bvid_from_video_url(absolute, hosts)
                if found:
                    return found, absolute
            break
    raise ValueError(BV_ERROR)


def resolve_bvid(value: str, *, allowed_hosts: set[str] | None = None) -> tuple[str, str]:
    """Return the BV id and the URL whose query may contain `p`.

    A bare BV id needs no network. An http(s) URL must stay on an allowed host.
    The id comes from the /video/<BV> path, or from rel=canonical / og:url.
    The first BV in the HTML is not used: recommended videos often appear first.
    """
    raw = value.strip()
    if re.fullmatch(r"BV[0-9A-Za-z]{10}", raw):
        return raw, raw

    hosts = set(BILIBILI_HOSTS if allowed_hosts is None else allowed_hosts)
    parsed = urllib.parse.urlparse(raw)
    if parsed.scheme in ("http", "https"):
        if _host(raw) not in hosts:
            raise ValueError(BV_ERROR)
        found = bvid_from_video_url(raw, hosts)
        if found:
            return found, raw
        return _follow_bvid(raw, hosts)
    return extract_bvid(raw), raw


def requested_page(value: str) -> int | None:
    try:
        parsed = urllib.parse.urlparse(value)
        raw = urllib.parse.parse_qs(parsed.query).get("p", [None])[0]
        return int(raw) if raw else None
    except (TypeError, ValueError):
        return None


def request_bytes(url: str, *, referer: str = "https://www.bilibili.com/", retries: int = 3) -> bytes:
    headers = {"User-Agent": UA, "Referer": referer, "Accept": "*/*"}
    last_error: Exception | None = None
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=60) as response:
                return response.read()
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            last_error = exc
            if attempt + 1 < retries:
                time.sleep(2 ** attempt)
    raise RuntimeError(f"请求失败：{url} ({last_error})")


def request_json(url: str, *, referer: str = "https://www.bilibili.com/") -> dict[str, Any]:
    try:
        payload = json.loads(request_bytes(url, referer=referer).decode("utf-8"))
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"接口未返回 JSON：{url}") from exc
    if isinstance(payload, dict) and "code" in payload and payload.get("code") != 0:
        raise RuntimeError(f"B站接口错误 {payload.get('code')}：{payload.get('message', '')}")
    return payload


def api_url(path: str, **params: Any) -> str:
    return f"{API}{path}?{urllib.parse.urlencode(params)}"


def fetch_info(bvid: str) -> dict[str, Any]:
    payload = request_json(api_url("/x/web-interface/view", bvid=bvid))
    data = payload.get("data") or {}
    if not data:
        raise RuntimeError("视频元数据为空，可能不存在或需要权限")
    return data


def fetch_player(bvid: str, cid: int) -> dict[str, Any]:
    payload = request_json(api_url("/x/player/v2", bvid=bvid, cid=cid))
    return payload.get("data") or {}


def normalize_url(url: str) -> str:
    if url.startswith("//"):
        return "https:" + url
    return url


def timestamp(seconds: float, sep: str = ",") -> str:
    millis = max(0, round(seconds * 1000))
    hours, millis = divmod(millis, 3_600_000)
    minutes, millis = divmod(millis, 60_000)
    secs, millis = divmod(millis, 1000)
    return f"{hours:02d}:{minutes:02d}:{secs:02d}{sep}{millis:03d}"


def choose_subtitle(subtitles: list[dict[str, Any]]) -> dict[str, Any] | None:
    if not subtitles:
        return None
    preferences = ("zh-CN", "zh-Hans", "ai-zh", "zh", "en")
    for lang in preferences:
        for subtitle in subtitles:
            if str(subtitle.get("lan", "")).lower() == lang.lower():
                return subtitle
    return subtitles[0]


def save_official_subtitle(subtitle: dict[str, Any], prefix: Path) -> tuple[Path, Path]:
    raw_url = subtitle.get("subtitle_url") or subtitle.get("subtitleUrl")
    if not raw_url:
        raise RuntimeError("字幕条目缺少下载地址")
    payload = json.loads(request_bytes(normalize_url(str(raw_url))).decode("utf-8"))
    body = payload.get("body") or []
    if not body:
        raise RuntimeError("官方字幕正文为空")

    lang = re.sub(r"[^0-9A-Za-z_-]+", "-", str(subtitle.get("lan") or "unknown"))
    txt_path = prefix.with_name(prefix.name + f".official.{lang}.txt")
    srt_path = prefix.with_name(prefix.name + f".official.{lang}.srt")

    lines: list[str] = []
    srt: list[str] = []
    cue = 1
    for item in body:
        content = html.unescape(str(item.get("content", ""))).strip()
        if not content:
            continue
        lines.append(content)
        srt.extend([
            str(cue),
            f"{timestamp(float(item.get('from', 0)))} --> {timestamp(float(item.get('to', 0)))}",
            content,
            "",
        ])
        cue += 1
    if not lines:
        raise RuntimeError("官方字幕正文为空")
    txt_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    srt_path.write_text("\n".join(srt), encoding="utf-8")
    return txt_path, srt_path


def fetch_audio_candidates(bvid: str, cid: int) -> list[str]:
    endpoints = ("/x/player/wbi/playurl", "/x/player/playurl")
    last_error: Exception | None = None
    for endpoint in endpoints:
        try:
            payload = request_json(api_url(endpoint, bvid=bvid, cid=cid, fnval=4048, fourk=1))
            audio = ((payload.get("data") or {}).get("dash") or {}).get("audio") or []
            if not audio:
                continue
            best = max(audio, key=lambda item: int(item.get("bandwidth") or 0))
            urls = [best.get("baseUrl") or best.get("base_url")]
            urls.extend(best.get("backupUrl") or best.get("backup_url") or [])
            return [normalize_url(str(url)) for url in urls if url]
        except Exception as exc:  # try the non-WBI public endpoint next
            last_error = exc
    raise RuntimeError(f"没有可访问的 DASH 音频（可能需要登录、付费或仅开放预览）：{last_error}")


def download_file(urls: list[str], destination: Path, referer: str) -> None:
    last_error: Exception | None = None
    for url in urls:
        try:
            headers = {"User-Agent": UA, "Referer": referer, "Accept": "*/*"}
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=90) as response, destination.open("wb") as output:
                shutil.copyfileobj(response, output, length=1024 * 1024)
            if destination.stat().st_size < 1024:
                raise RuntimeError("下载文件异常地小")
            return
        except (urllib.error.URLError, TimeoutError, OSError, RuntimeError) as exc:
            last_error = exc
            destination.unlink(missing_ok=True)
    raise RuntimeError(f"音频下载失败：{last_error}")


def save_audio(bvid: str, cid: int, page: dict[str, Any], page_number: int, prefix: Path) -> tuple[Path, float]:
    audio_path = prefix.with_suffix(".m4a")
    if audio_path.exists() and audio_path.stat().st_size > 0:
        log(f"复用已有音频：{audio_path}")
        return audio_path, ffprobe_duration(audio_path)

    referer = f"https://www.bilibili.com/video/{bvid}/?p={page_number}"
    with tempfile.TemporaryDirectory(prefix=f"bvsum-{bvid}-p{page_number}-") as temp:
        raw_audio = Path(temp) / "audio.m4s"
        log("下载公开 DASH 音频…")
        download_file(fetch_audio_candidates(bvid, cid), raw_audio, referer)
        actual_duration = ffprobe_duration(raw_audio)
        expected_duration = float(page.get("duration") or 0)
        if expected_duration and abs(actual_duration - expected_duration) > max(8, expected_duration * 0.05):
            raise RuntimeError(
                f"音频时长不完整：下载 {actual_duration:.1f}s，页面标注 {expected_duration:.1f}s"
            )
        subprocess.run(
            [require_binary("ffmpeg"), "-hide_banner", "-loglevel", "error", "-y", "-i", str(raw_audio),
             "-vn", "-c:a", "copy", str(audio_path)],
            check=True,
        )
    return audio_path, actual_duration


def require_binary(name: str) -> str:
    path = shutil.which(name)
    if not path:
        raise RuntimeError(f"缺少依赖：{name}")
    return path


def ffprobe_duration(path: Path) -> float:
    result = subprocess.run(
        [require_binary("ffprobe"), "-v", "error", "-show_entries", "format=duration",
         "-of", "default=noprint_wrappers=1:nokey=1", str(path)],
        capture_output=True, text=True, check=True,
    )
    return float(result.stdout.strip())


def convert_to_wav(source: Path, destination: Path) -> None:
    subprocess.run(
        [require_binary("ffmpeg"), "-hide_banner", "-loglevel", "error", "-y", "-i", str(source),
         "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", str(destination)],
        check=True,
    )


def select_backend(requested: str) -> str:
    if requested != "auto":
        return requested
    if shutil.which("uvx") and MLX_CACHE.exists():
        return "mlx"
    if shutil.which("whisper-cli") and WHISPER_CPP_MODEL.exists():
        return "whisper-cpp"
    if shutil.which("uvx"):
        return "mlx"
    raise RuntimeError("未找到转录后端：需要 uvx + mlx-whisper，或 whisper-cli + 本地模型")


def run_logged(command: list[str], log_path: Path) -> None:
    with log_path.open("w", encoding="utf-8") as output:
        result = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, text=True)
    if result.returncode != 0:
        tail = log_path.read_text(encoding="utf-8", errors="replace")[-3000:]
        raise RuntimeError(f"转录命令失败（退出码 {result.returncode}）：\n{tail}")
    log_path.unlink(missing_ok=True)


def transcribe_mlx(wav: Path, prefix: Path, language: str) -> None:
    command = [
        require_binary("uvx"), "--from", "mlx-whisper", "mlx_whisper", str(wav),
        "--model", MLX_MODEL,
        "--task", "transcribe",
        "--output-format", "all",
        "--output-name", prefix.name,
        "--output-dir", str(prefix.parent),
        "--condition-on-previous-text", "False",
    ]
    if language != "auto":
        command.extend(["--language", language])
    run_logged(command, prefix.with_suffix(".transcribe.log"))


def transcribe_whisper_cpp(wav: Path, prefix: Path, language: str) -> None:
    require_binary("whisper-cli")
    if not WHISPER_CPP_MODEL.exists():
        raise RuntimeError(f"本地 whisper.cpp 模型不存在：{WHISPER_CPP_MODEL}")
    command = [
        "whisper-cli", "-m", str(WHISPER_CPP_MODEL), "-f", str(wav),
        "-l", language, "-otxt", "-osrt", "-ovtt", "-oj", "-of", str(prefix), "-np",
    ]
    run_logged(command, prefix.with_suffix(".transcribe.log"))


def existing_transcript(prefix: Path) -> Path | None:
    txt = prefix.with_suffix(".txt")
    return txt if txt.exists() and txt.stat().st_size > 0 else None


def sidecar_path(prefix: Path) -> Path:
    return prefix.with_name(prefix.name + ".transcript.json")


def read_json_file(path: Path) -> dict[str, Any] | None:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    return data if isinstance(data, dict) else None


def _as_int(value: Any) -> int | None:
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def manifest_page(
    manifest: dict[str, Any] | None,
    bvid: str,
    page: int,
    cid: int | None = None,
) -> dict[str, Any] | None:
    if not manifest or manifest.get("bvid") != bvid:
        return None
    for item in manifest.get("pages") or []:
        if not isinstance(item, dict) or _as_int(item.get("page")) != page:
            continue
        if cid is not None and _as_int(item.get("cid")) != cid:
            continue
        return item
    return None


def cached_transcript_fields(
    prefix: Path,
    *,
    bvid: str,
    page: int,
    cid: int,
    old_manifest: dict[str, Any] | None,
) -> dict[str, Any] | None:
    """Read the existing machine transcript's provenance before reusing its files."""
    transcript = existing_transcript(prefix)
    if transcript is None:
        return None

    side = read_json_file(sidecar_path(prefix)) or {}
    side_bvid = str(side.get("bvid") or "")
    side_page = _as_int(side.get("page"))
    side_cid = _as_int(side.get("cid"))
    if side_bvid and side_bvid != bvid:
        raise RuntimeError(f"已有字稿属于 {side_bvid}，与当前 {bvid} 不同；未覆盖。要重转请加 --force")
    if side_page is not None and side_page != page:
        raise RuntimeError(f"已有字稿属于 P{side_page}，与当前 P{page} 不同；未覆盖。要重转请加 --force")
    if side_cid is not None and side_cid != cid:
        raise RuntimeError(f"已有字稿的 cid 是 {side_cid}，当前 cid 是 {cid}；未复用也未覆盖。要重转请加 --force")

    if old_manifest and old_manifest.get("bvid") == bvid and side_cid is None:
        for item in old_manifest.get("pages") or []:
            if not isinstance(item, dict) or _as_int(item.get("page")) != page:
                continue
            old_cid = _as_int(item.get("cid"))
            if old_cid is not None and old_cid != cid:
                raise RuntimeError(f"清单里 P{page} 的 cid 是 {old_cid}，当前是 {cid}；未复用。要重转请加 --force")

    matched = manifest_page(old_manifest, bvid, page, cid) or {}
    # Older reuse records copied the request language and had no backend.
    if matched.get("source") == "official-subtitle" or (
        matched.get("source") == "existing-machine-transcript" and "backend" not in matched
    ):
        matched = {}
    language = str(side.get("language") or matched.get("language") or "").strip() or "unknown"
    backend = str(side.get("backend") or matched.get("backend") or "").strip() or "unknown"
    srt = prefix.with_suffix(".srt")
    info: dict[str, Any] = {
        "source": "existing-machine-transcript",
        "language": language,
        "backend": backend,
        "transcript_path": str(transcript),
        "srt_path": str(srt) if srt.exists() else None,
    }
    audio = prefix.with_suffix(".m4a")
    if audio.exists():
        info["audio_path"] = str(audio)
    return info


def transcribe(wav: Path, prefix: Path, language: str, backend_request: str) -> str:
    backend = select_backend(backend_request)
    log(f"本地转录：backend={backend}, language={language}")
    try:
        if backend == "mlx":
            transcribe_mlx(wav, prefix, language)
        else:
            transcribe_whisper_cpp(wav, prefix, language)
        return backend
    except Exception as first_error:
        if backend_request == "auto" and backend == "mlx" and shutil.which("whisper-cli") and WHISPER_CPP_MODEL.exists():
            log(f"MLX 转录失败，改用 whisper-cli：{first_error}")
            transcribe_whisper_cpp(wav, prefix, language)
            return "whisper-cpp"
        raise


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="为 Bilibili 视频准备官方字幕或本地转录")
    parser.add_argument("input", help="Bilibili URL 或 BV号")
    parser.add_argument("--language", choices=("auto", "zh", "en"), default="auto")
    parser.add_argument("--backend", choices=("auto", "mlx", "whisper-cpp"), default="auto")
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--force", action="store_true", help="忽略已有机器字稿并重新转录")
    parser.add_argument("--metadata-only", action="store_true", help="只获取元数据，不下载或转录")
    parser.add_argument("--no-audio", action="store_true", help="有官方字幕时不下载音频")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        bvid, page_source = resolve_bvid(args.input)
    except ValueError as exc:
        log(str(exc))
        return 2
    except (urllib.error.URLError, TimeoutError, OSError, RuntimeError) as exc:
        log(f"ERROR: {exc}")
        return 1

    output_dir = (args.output_dir.expanduser() / bvid).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    manifest_path = output_dir / f"{bvid}.bvsum.json"
    lock_path = Path(tempfile.gettempdir()) / f"bvsum-{bvid}.lock"

    with lock_path.open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            log(f"同一视频已有 bvsum 任务运行：{bvid}")
            return 3

        try:
            info = fetch_info(bvid)
            all_pages = info.get("pages") or [{"cid": info.get("cid"), "page": 1, "part": info.get("title", "")}]
            selected = requested_page(page_source)
            if selected is None:
                selected = requested_page(args.input)
            pages = [p for p in all_pages if int(p.get("page") or 1) == selected] if selected else all_pages
            if not pages:
                raise RuntimeError(f"链接指定的分P不存在：p={selected}")

            manifest: dict[str, Any] = {
                "bvid": bvid,
                "title": info.get("title", ""),
                "owner": (info.get("owner") or {}).get("name", ""),
                "description": info.get("desc", ""),
                "duration_seconds": info.get("duration", 0),
                "pubdate": time.strftime("%Y-%m-%d", time.localtime(info.get("pubdate") or 0)),
                "url": f"https://www.bilibili.com/video/{bvid}/",
                "selected_page": selected,
                "pages": [],
            }
            log(f"{manifest['title']} | UP主：{manifest['owner']} | {manifest['duration_seconds']} 秒")
            old_manifest = read_json_file(manifest_path)

            for page_index, page in enumerate(pages, 1):
                page_number = int(page.get("page") or page_index)
                cid = int(page.get("cid") or 0)
                page_result: dict[str, Any] = {
                    "page": page_number,
                    "cid": cid,
                    "title": page.get("part", ""),
                    "duration_seconds": page.get("duration", 0),
                }
                manifest["pages"].append(page_result)
                if args.metadata_only:
                    previous = manifest_page(old_manifest, bvid, page_number, cid) or {}
                    for key in (
                        "source", "language", "backend", "transcript_path",
                        "srt_path", "audio_path", "audio_duration_seconds",
                    ):
                        if previous.get(key) not in (None, ""):
                            page_result[key] = previous[key]
                    continue

                if not cid:
                    raise RuntimeError(f"P{page_number} 缺少 cid")
                prefix_name = bvid if len(all_pages) == 1 else f"{bvid}_p{page_number:02d}"
                prefix = output_dir / prefix_name
                log(f"处理 P{page_number}：{page_result['title']}")

                player = fetch_player(bvid, cid)
                page_result["chapters"] = player.get("view_points") or []
                subtitles = ((player.get("subtitle") or {}).get("subtitles") or [])
                official = choose_subtitle(subtitles)
                if official:
                    try:
                        txt_path, srt_path = save_official_subtitle(official, prefix)
                        page_result.update({
                            "source": "official-subtitle",
                            "language": official.get("lan"),
                            "transcript_path": str(txt_path),
                            "srt_path": str(srt_path),
                        })
                        log(f"使用 B站官方字幕：{txt_path}")
                        if not args.no_audio:
                            try:
                                audio_path, duration = save_audio(bvid, cid, page, page_number, prefix)
                                page_result["audio_path"] = str(audio_path)
                                page_result["audio_duration_seconds"] = round(duration, 3)
                            except Exception as exc:
                                log(f"音频下载失败（字幕已就绪，继续）：{exc}")
                        continue
                    except Exception as exc:
                        log(f"官方字幕不可下载，回退本地转录：{exc}")

                cached = None if args.force else cached_transcript_fields(
                    prefix, bvid=bvid, page=page_number, cid=cid, old_manifest=old_manifest,
                )
                if cached:
                    page_result.update(cached)
                    log(f"复用已有机器字稿：{cached['transcript_path']}"
                        f"（language={cached['language']}, backend={cached['backend']}）")
                else:
                    audio_path, duration = save_audio(bvid, cid, page, page_number, prefix)
                    page_result["audio_path"] = str(audio_path)
                    page_result["audio_duration_seconds"] = round(duration, 3)
                    with tempfile.TemporaryDirectory(prefix=f"bvsum-{bvid}-p{page_number}-") as temp:
                        wav_audio = Path(temp) / "audio.wav"
                        convert_to_wav(audio_path, wav_audio)
                        used_backend = transcribe(wav_audio, prefix, args.language, args.backend)

                    transcript_path = existing_transcript(prefix)
                    if not transcript_path:
                        raise RuntimeError("转录进程结束但未生成 TXT")
                    page_result.update({
                        "source": "machine-transcript",
                        "backend": used_backend,
                        "language": args.language,
                        "transcript_path": str(transcript_path),
                        "srt_path": str(prefix.with_suffix('.srt')) if prefix.with_suffix('.srt').exists() else None,
                    })
                keys = ("page", "cid", "language", "backend", "source", "transcript_path")
                sidecar = {"bvid": bvid, **{key: page_result[key] for key in keys}}
                sidecar_path(prefix).write_text(json.dumps(sidecar, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
                if not cached and page_index < len(pages):
                    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

            manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            if not args.metadata_only:
                log(f"音频与字稿保存在 {output_dir}（重启后自动清空）")
            print(manifest_path)
            return 0
        except Exception as exc:
            log(f"ERROR: {exc}")
            return 1


if __name__ == "__main__":
    raise SystemExit(main())
