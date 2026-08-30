#!/usr/bin/env python3
"""Local deterministic HTTP fixtures for Harbor's manual XCUITest suite."""

from __future__ import annotations

import argparse
import hashlib
import http.server
import json
import os
import shutil
import subprocess
import tempfile
import threading
import time
import urllib.parse
from pathlib import Path


SMALL_PAYLOAD = b"Harbor UI test fixture\n" * 4096
SLOW_PAYLOAD = bytes(range(256)) * 16384
PIECE_LENGTH = 16384


def bencode(value: object) -> bytes:
    if isinstance(value, bytes):
        return str(len(value)).encode() + b":" + value
    if isinstance(value, str):
        return bencode(value.encode())
    if isinstance(value, int):
        return b"i" + str(value).encode() + b"e"
    if isinstance(value, list):
        return b"l" + b"".join(bencode(item) for item in value) + b"e"
    if isinstance(value, dict):
        items = []
        for key in sorted(value, key=lambda item: item if isinstance(item, bytes) else str(item).encode()):
            items.append(bencode(key))
            items.append(bencode(value[key]))
        return b"d" + b"".join(items) + b"e"
    raise TypeError(f"Unsupported bencode value: {type(value)!r}")


def piece_hashes(payload: bytes) -> bytes:
    return b"".join(
        hashlib.sha1(payload[offset : offset + PIECE_LENGTH], usedforsecurity=False).digest()
        for offset in range(0, len(payload), PIECE_LENGTH)
    )


def single_torrent(base_url: str, webseed: bool) -> bytes:
    info = {
        b"length": len(SMALL_PAYLOAD),
        b"name": b"harbor-webseed.bin" if webseed else b"harbor-single.bin",
        b"piece length": PIECE_LENGTH,
        b"pieces": piece_hashes(SMALL_PAYLOAD),
    }
    root: dict[bytes, object] = {
        b"announce": b"http://127.0.0.1:1/announce",
        b"info": info,
    }
    if webseed:
        root[b"url-list"] = f"{base_url}/direct/small.bin"
    return bencode(root)


def multi_torrent() -> bytes:
    first = b"Docs fixture\n"
    second = b"Video fixture\n"
    payload = first + second
    return bencode(
        {
            b"announce": b"http://127.0.0.1:1/announce",
            b"info": {
                b"files": [
                    {b"length": len(first), b"path": [b"Docs", b"Readme.txt"]},
                    {b"length": len(second), b"path": [b"Video", b"Clip.mp4"]},
                ],
                b"name": b"Harbor UI Fixture",
                b"piece length": PIECE_LENGTH,
                b"pieces": piece_hashes(payload),
            },
        }
    )


def generate_media(ffmpeg_path: str | None, output: Path) -> None:
    if not ffmpeg_path:
        raise RuntimeError("Pass --ffmpeg to enable the media fixture")
    subprocess.run(
        [
            ffmpeg_path,
            "-hide_banner",
            "-loglevel",
            "error",
            "-f",
            "lavfi",
            "-i",
            "color=c=0x2f6fed:s=320x180:d=1",
            "-f",
            "lavfi",
            "-i",
            "anullsrc=r=44100:cl=stereo",
            "-shortest",
            "-c:v",
            "mpeg4",
            "-c:a",
            "aac",
            "-movflags",
            "+faststart",
            "-y",
            str(output),
        ],
        check=True,
        timeout=30,
    )


class FixtureState:
    def __init__(self, log_path: Path, media_path: Path | None):
        self.log_path = log_path
        self.media_path = media_path
        self.base_url = ""
        self.torrents: dict[str, bytes] = {}
        self.lock = threading.Lock()

    def record(self, method: str, path: str, headers: http.client.HTTPMessage) -> None:
        entry = {
            "timestamp": time.time(),
            "method": method,
            "path": path,
            "range": headers.get("Range"),
            "ifRange": headers.get("If-Range"),
            "userAgent": headers.get("User-Agent"),
        }
        with self.lock:
            with self.log_path.open("a", encoding="utf-8") as stream:
                stream.write(json.dumps(entry, sort_keys=True) + "\n")


class FixtureHandler(http.server.BaseHTTPRequestHandler):
    server_version = "HarborFixtureServer/1"

    @property
    def state(self) -> FixtureState:
        return self.server.fixture_state  # type: ignore[attr-defined]

    def log_message(self, format: str, *args: object) -> None:
        return

    def do_HEAD(self) -> None:
        self._handle(send_body=False)

    def do_GET(self) -> None:
        self._handle(send_body=True)

    def _handle(self, send_body: bool) -> None:
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        self.state.record(self.command, path, self.headers)

        if path == "/health":
            self._send_bytes(b"ok\n", "text/plain", send_body=send_body)
        elif path == "/direct/small.bin":
            self._send_ranged(SMALL_PAYLOAD, "application/octet-stream", send_body)
        elif path == "/direct/slow.bin":
            self._send_ranged(SLOW_PAYLOAD, "application/octet-stream", send_body, slow=True)
        elif path == "/direct/renamed":
            query = urllib.parse.parse_qs(parsed.query)
            requested_name = query.get("name", ["Harbor Renamed Fixture"])[0]
            safe_name = "".join(character for character in requested_name if character.isalnum() or character in " -_")
            filename = safe_name.strip() or "Harbor Renamed Fixture"
            self._send_ranged(
                SMALL_PAYLOAD,
                "application/octet-stream",
                send_body,
                extra_headers={"Content-Disposition": f'attachment; filename="{filename}.bin"'},
            )
        elif path == "/direct/redirect":
            self.send_response(302)
            self.send_header("Location", "/direct/small.bin")
            self.end_headers()
        elif path == "/errors/404.bin":
            self._send_bytes(b"missing\n", "text/plain", status=404, send_body=send_body)
        elif path == "/errors/html.bin":
            self._send_bytes(
                b"<!doctype html><title>Browser required</title>"
                b'<a id="fixture-download" href="/browser/file.bin">Download fixture</a>',
                "text/html",
                send_body=send_body,
            )
        elif path == "/errors/truncated.bin":
            body = SMALL_PAYLOAD[:1024]
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(len(SMALL_PAYLOAD)))
            self.end_headers()
            if send_body:
                self.wfile.write(body)
                self.close_connection = True
        elif path == "/errors/bad-range.bin":
            self.send_response(206)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Range", "bytes 9-3/20")
            self.send_header("Content-Length", "4")
            self.end_headers()
            if send_body:
                self.wfile.write(b"bad\n")
        elif path == "/browser/index":
            html = b"""<!doctype html><html><head><title>Harbor Browser Fixture</title></head>
            <body><a id="fixture-download" href="/browser/file.bin">Download fixture</a></body></html>"""
            self._send_bytes(html, "text/html", send_body=send_body)
        elif path == "/browser/file.bin":
            self._send_ranged(
                SMALL_PAYLOAD,
                "application/octet-stream",
                send_body,
                extra_headers={"Content-Disposition": 'attachment; filename="Harbor Browser Fixture.bin"'},
            )
        elif path == "/media/page":
            html = f"""<!doctype html><html><head>
            <title>Harbor Synthetic Media</title>
            <meta property="og:title" content="Harbor Synthetic Media">
            <meta property="og:video" content="{self.state.base_url}/media/sample.mp4">
            </head><body><video controls src="/media/sample.mp4"></video></body></html>""".encode()
            self._send_bytes(html, "text/html", send_body=send_body)
        elif path == "/media/sample.mp4" and self.state.media_path:
            self._send_ranged(self.state.media_path.read_bytes(), "video/mp4", send_body)
        elif path.startswith("/torrents/") and path in self.state.torrents:
            self._send_bytes(
                self.state.torrents[path],
                "application/x-bittorrent",
                send_body=send_body,
            )
        else:
            self._send_bytes(b"not found\n", "text/plain", status=404, send_body=send_body)

    def _send_bytes(
        self,
        payload: bytes,
        content_type: str,
        *,
        status: int = 200,
        send_body: bool,
    ) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        if send_body:
            self.wfile.write(payload)

    def _send_ranged(
        self,
        payload: bytes,
        content_type: str,
        send_body: bool,
        *,
        slow: bool = False,
        extra_headers: dict[str, str] | None = None,
    ) -> None:
        start = 0
        end = len(payload) - 1
        status = 200
        range_header = self.headers.get("Range")
        if range_header and range_header.startswith("bytes="):
            raw_start, raw_end = range_header.removeprefix("bytes=").split("-", 1)
            try:
                start = int(raw_start)
            except ValueError:
                start = 0
            try:
                end = min(int(raw_end), len(payload) - 1) if raw_end else len(payload) - 1
            except ValueError:
                end = len(payload) - 1
            if start >= len(payload):
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{len(payload)}")
                self.send_header("ETag", '"harbor-ui-fixture-v1"')
                self.end_headers()
                return
            if end < start:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{len(payload)}")
                self.end_headers()
                return
            status = 206

        body = payload[start : end + 1]
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("ETag", '"harbor-ui-fixture-v1"')
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{len(payload)}")
        for key, value in (extra_headers or {}).items():
            self.send_header(key, value)
        self.end_headers()

        if not send_body:
            return
        if not slow:
            self.wfile.write(body)
            return

        try:
            for offset in range(0, len(body), PIECE_LENGTH):
                self.wfile.write(body[offset : offset + PIECE_LENGTH])
                self.wfile.flush()
                time.sleep(0.025)
        except (BrokenPipeError, ConnectionResetError):
            return


def write_json(path: Path, payload: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ready-file", required=True)
    parser.add_argument("--log-file", required=True)
    parser.add_argument("--ffmpeg")
    parser.add_argument("--work-directory")
    arguments = parser.parse_args()

    ready_path = Path(arguments.ready_file)
    log_path = Path(arguments.log_file)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_path.write_text("", encoding="utf-8")

    work_root = (
        Path(arguments.work_directory)
        if arguments.work_directory
        else Path(tempfile.mkdtemp(prefix="harbor-ui-fixtures-"))
    )
    work_root.mkdir(parents=True, exist_ok=True)
    media_path: Path | None = work_root / "sample.mp4"
    try:
        generate_media(arguments.ffmpeg, media_path)
    except (RuntimeError, subprocess.SubprocessError, OSError):
        media_path = None

    state = FixtureState(log_path=log_path, media_path=media_path)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FixtureHandler)
    server.fixture_state = state  # type: ignore[attr-defined]
    state.base_url = f"http://127.0.0.1:{server.server_port}"
    state.torrents = {
        "/torrents/single.torrent": single_torrent(state.base_url, webseed=False),
        "/torrents/multi.torrent": multi_torrent(),
        "/torrents/webseed.torrent": single_torrent(state.base_url, webseed=True),
    }

    write_json(
        ready_path,
        {
            "baseURL": state.base_url,
            "pid": os.getpid(),
            "mediaAvailable": media_path is not None,
            "mediaSHA256": hashlib.sha256(media_path.read_bytes()).hexdigest() if media_path else None,
            "smallSHA256": hashlib.sha256(SMALL_PAYLOAD).hexdigest(),
            "slowSHA256": hashlib.sha256(SLOW_PAYLOAD).hexdigest(),
        },
    )

    try:
        server.serve_forever(poll_interval=0.1)
    finally:
        server.server_close()
        if not arguments.work_directory:
            shutil.rmtree(work_root, ignore_errors=True)


if __name__ == "__main__":
    main()
