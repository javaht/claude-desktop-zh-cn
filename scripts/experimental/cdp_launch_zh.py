#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Experimental: bypass Claude Desktop CDP gate, launch a temp app copy with
--remote-debugging-port, and inject the existing online DOM Chinese translation
via Chromium DevTools Protocol.

This does NOT modify /Applications/Claude.app by default and is not wired into
install-mac.command. Prefer the normal asar/resource installer for daily use.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import re
import signal
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

SCRIPTS_DIR = Path(__file__).resolve().parent.parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

import patch_claude_zh_cn as patch  # noqa: E402

try:
    import websockets
except ImportError as exc:  # pragma: no cover
    raise SystemExit(
        "Missing dependency 'websockets'. Install with: python3 -m pip install websockets"
    ) from exc


# Minified detector name changes across builds (kRA / SRA / ...).
# Discover via fixed suffix (avoid catastrophic regex on multi-MB JS).
GATE_OLD = b"kRA(process.argv)&&!yR()&&process.exit(1)"
GATE_NEW = b"kRA(process.argv)&&false&&process.exit(1)"
assert len(GATE_OLD) == len(GATE_NEW)
GATE_SUFFIX = b"(process.argv)&&!yR()&&process.exit(1)"
GATE_SUFFIX_PATCHED = b"(process.argv)&&false&&process.exit(1)"

INJECT_MARKER = "v1"
DEFAULT_PORT = 19350
DEFAULT_WORK_DIR = Path.home() / ".cache" / "claude-cdp-zh"
CDP_WAIT_SECONDS = 30.0
WATCHDOG_INTERVAL = 1.5


def log(message: str) -> None:
    print(message, flush=True)


def http_json(url: str, timeout: float = 1.0) -> Any:
    with urllib.request.urlopen(url, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def port_listening(port: int) -> bool:
    try:
        http_json(f"http://127.0.0.1:{port}/json/version", timeout=0.4)
        return True
    except Exception:
        return False


def work_paths(work_dir: Path) -> tuple[Path, Path, Path]:
    app = work_dir / "Claude.app"
    userdata = work_dir / "userdata"
    state = work_dir / "launcher-state.json"
    return app, userdata, state


def save_state(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(tmp, path)


def load_state(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def source_fingerprint(app: Path) -> dict[str, Any]:
    asar = app / patch.APP_ASAR_REL
    binary = app / "Contents/MacOS/Claude"
    return {
        "app": str(app.resolve()),
        "asar_size": asar.stat().st_size if asar.exists() else None,
        "asar_mtime_ns": asar.stat().st_mtime_ns if asar.exists() else None,
        "binary_mtime_ns": binary.stat().st_mtime_ns if binary.exists() else None,
    }


def _ident_start(content: bytes, idx: int) -> int:
    start = idx
    while start > 0:
        c = content[start - 1]
        if (
            (48 <= c <= 57)
            or (65 <= c <= 90)
            or (97 <= c <= 122)
            or c == 36
            or c == 95
        ):
            start -= 1
            continue
        break
    return start


def find_gate_bytes(content: bytes) -> tuple[bytes, bytes] | None:
    idx = content.find(GATE_SUFFIX)
    if idx < 0:
        return None
    start = _ident_start(content, idx)
    if start == idx:
        return None
    first = content[start]
    if not ((65 <= first <= 90) or (97 <= first <= 122) or first == 36 or first == 95):
        return None
    gate_old = content[start : idx + len(GATE_SUFFIX)]
    gate_new = gate_old.replace(b"&&!yR()&&", b"&&false&&", 1)
    if len(gate_new) != len(gate_old) or b"&&false&&" not in gate_new:
        raise SystemExit("Failed equal-length CDP gate rewrite")
    return gate_old, gate_new


def discover_gate(content: bytes) -> tuple[bytes, bytes] | None:
    """Return (gate_old, gate_new) equal-length pair if found in content."""
    if GATE_OLD in content:
        return GATE_OLD, GATE_NEW
    return find_gate_bytes(content)


def content_gate_patched(content: bytes) -> bool:
    if GATE_NEW in content and GATE_OLD not in content:
        return True
    if GATE_SUFFIX in content:
        return False
    return GATE_SUFFIX_PATCHED in content


def find_gate_file(app: Path) -> tuple[str, bytes, bytes, bytes]:
    """Return (file_path, content, gate_old, gate_new)."""
    asar_path = app / patch.APP_ASAR_REL
    patch.require_file(asar_path)
    data = asar_path.read_bytes()
    header_size, _header_string, header = patch.read_asar_header(data, asar_path)

    matches: list[tuple[str, bytes, bytes, bytes]] = []
    for file_path, entry in patch.iter_asar_files(header):
        if "offset" not in entry or "size" not in entry:
            continue
        if not file_path.endswith(".js"):
            continue
        content = patch.read_asar_entry_content(data, header_size, entry, file_path)
        discovered = discover_gate(content)
        if discovered is not None:
            gate_old, gate_new = discovered
            matches.append((file_path, content, gate_old, gate_new))
            continue
        if content_gate_patched(content):
            idx = content.find(GATE_SUFFIX_PATCHED)
            if idx < 0:
                continue
            start = _ident_start(content, idx)
            gate_new = content[start : idx + len(GATE_SUFFIX_PATCHED)]
            gate_old = gate_new.replace(b"&&false&&", b"&&!yR()&&", 1)
            matches.append((file_path, content, gate_old, gate_new))

    if not matches:
        raise SystemExit(
            "CDP gate pattern not found in app.asar. "
            "This Claude Desktop version may have changed; experimental CDP launch cannot continue."
        )
    if len(matches) > 1:
        vite = [m for m in matches if m[0].startswith(".vite/build/")]
        if len(vite) == 1:
            return vite[0]
        paths = ", ".join(path for path, *_ in matches)
        raise SystemExit(f"Ambiguous CDP gate matches in multiple asar files: {paths}")
    return matches[0]


def patch_cdp_gate(app: Path) -> str:
    file_path, content, gate_old, gate_new = find_gate_file(app)
    if content_gate_patched(content) and gate_old not in content:
        log(f"CDP gate already patched in {file_path}")
        return file_path
    if gate_old not in content:
        raise SystemExit(
            f"Found related gate file {file_path} but original pattern is missing. "
            "Refuse to patch an unknown layout."
        )
    count = content.count(gate_old)
    if count != 1:
        raise SystemExit(f"Expected exactly one CDP gate occurrence, found {count} in {file_path}")
    patched = content.replace(gate_old, gate_new, 1)
    if len(patched) != len(content):
        raise SystemExit("Internal error: CDP gate replacement changed length.")
    log(f"Patching CDP gate in {file_path}: {gate_old.decode('ascii')} -> {gate_new.decode('ascii')}")
    changed = patch.replace_asar_file_content(app, file_path, patched)
    if not changed and gate_old in (app / patch.APP_ASAR_REL).read_bytes():
        raise SystemExit("Failed to write CDP gate patch into app.asar")
    if gate_old in (app / patch.APP_ASAR_REL).read_bytes():
        raise SystemExit("CDP gate still present after patch")
    log("CDP gate patched (integrity metadata updated)")
    return file_path


def prepare_work_app(
    source_app: Path,
    work_app: Path,
    *,
    force_repatch: bool,
    state_path: Path,
) -> None:
    patch.require_file(source_app / "Contents/MacOS/Claude")
    fp = source_fingerprint(source_app)
    state = load_state(state_path)

    reuse = False
    if not force_repatch and work_app.exists() and state.get("source_fingerprint") == fp:
        try:
            _fp, content, gate_old, gate_new = find_gate_file(work_app)
            reuse = content_gate_patched(content) and gate_old not in content
        except SystemExit:
            reuse = False
        if reuse:
            try:
                patch.verify_electron_asar_integrity(work_app)
                log(f"Reusing patched work app: {work_app}")
                return
            except SystemExit as exc:
                log(f"Cached work app failed integrity check ({exc}); rebuilding")

    if work_app.exists():
        log(f"Removing old work app: {work_app}")
        shutil.rmtree(work_app)

    work_app.parent.mkdir(parents=True, exist_ok=True)
    patch.copy_app(source_app, work_app)
    file_path = patch_cdp_gate(work_app)
    log("Re-signing work app (ad-hoc)")
    patch.resign_app(work_app)
    patch.clear_quarantine(work_app)
    patch.verify_electron_asar_integrity(work_app)
    # Persist whatever gate pair we actually used.
    _fp2, _c2, gate_old, gate_new = find_gate_file(work_app)
    save_state(
        state_path,
        {
            "source_fingerprint": fp,
            "work_app": str(work_app),
            "gate_file": file_path,
            "gate_old": gate_old.decode("ascii"),
            "gate_new": gate_new.decode("ascii"),
            "patched_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
        },
    )


def build_inject_script(work_app: Path, lang: str) -> str:
    """Build inject expression that runs the existing DOM IIFE then returns status."""
    mapping = patch.build_online_translation_map(work_app, lang)
    if not mapping:
        raise SystemExit("Online translation map is empty; check en-US.json and resources/")
    log(f"Built online translation map: {len(mapping)} entries")
    dom_iife = patch.build_online_dom_translation_script(lang, mapping)
    # dom_iife is already a full IIFE: (()=>{...})()
    return (
        "(()=>{"
        f'if(window.__claudeZhCdpInjected==="{INJECT_MARKER}")'
        "return{ok:true,skipped:true,href:String(location.href||''),title:String(document.title||'')};"
        f'window.__claudeZhCdpInjected="{INJECT_MARKER}";'
        f"try{{{dom_iife}}}"
        "catch(e){return{ok:false,error:String(e),href:String(location.href||'')}};"
        "return{ok:true,skipped:false,href:String(location.href||''),title:String(document.title||'')}"
        "})()"
    )


def choose_page_targets(targets: list[dict[str, Any]]) -> list[dict[str, Any]]:
    pages = [
        t
        for t in targets
        if t.get("type") == "page" and t.get("webSocketDebuggerUrl")
    ]
    preferred = [t for t in pages if "claude.ai" in str(t.get("url") or "")]
    # Always include preferred; also local shell pages.
    others = [t for t in pages if t not in preferred]
    # Prefer claude.ai first for logging/order, but inject all pages with ws.
    return preferred + others


async def cdp_call(
    ws: Any,
    msg_id: int,
    method: str,
    params: dict[str, Any] | None = None,
    timeout: float = 8.0,
) -> dict[str, Any]:
    payload: dict[str, Any] = {"id": msg_id, "method": method}
    if params is not None:
        payload["params"] = params
    await ws.send(json.dumps(payload))
    deadline = time.monotonic() + timeout
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(f"CDP timeout waiting for {method}")
        raw = await asyncio.wait_for(ws.recv(), timeout=remaining)
        data = json.loads(raw)
        if data.get("id") == msg_id:
            if "error" in data:
                raise RuntimeError(f"{method} failed: {data['error']}")
            return data


async def inject_target(ws_url: str, script: str, target_label: str) -> dict[str, Any]:
    async with websockets.connect(ws_url, max_size=16_000_000, open_timeout=5) as ws:
        await cdp_call(ws, 1, "Page.enable")
        await cdp_call(ws, 2, "Page.addScriptToEvaluateOnNewDocument", {"source": script})
        result = await cdp_call(
            ws,
            3,
            "Runtime.evaluate",
            {
                "expression": script,
                "returnByValue": True,
                "awaitPromise": False,
            },
        )
        value = (
            result.get("result", {})
            .get("result", {})
            .get("value")
        )
        log(f"Injected {target_label}: {value!r}")
        return value if isinstance(value, dict) else {"ok": True, "raw": value}


async def inject_all_pages(
    port: int,
    script: str,
    seen: dict[str, tuple[float, str]],
) -> None:
    try:
        targets = http_json(f"http://127.0.0.1:{port}/json", timeout=1.5)
    except Exception as exc:
        log(f"CDP /json failed: {exc}")
        return
    if not isinstance(targets, list):
        return
    pages = choose_page_targets(targets)
    for target in pages:
        target_id = str(target.get("id") or "")
        ws_url = target.get("webSocketDebuggerUrl")
        url = str(target.get("url") or "")
        if not target_id or not ws_url:
            continue
        # Skip pure blank intermediates unless never injected.
        if url in {"", "about:blank"} and target_id in seen:
            continue
        last_ts, last_url = seen.get(target_id, (0.0, ""))
        url_changed = bool(last_url) and last_url != url
        recently = (time.monotonic() - last_ts) < 8.0
        if recently and not url_changed:
            continue
        label = f"{target.get('type')} {url[:90]}"
        try:
            value = await inject_target(str(ws_url), script, label)
            seen[target_id] = (time.monotonic(), url)
            if isinstance(value, dict) and value.get("ok") is False:
                log(f"Inject reported failure on {label}: {value}")
        except Exception as exc:
            log(f"Inject error on {label}: {exc}")


def launch_claude(work_app: Path, userdata: Path, port: int) -> subprocess.Popen[str]:
    userdata.mkdir(parents=True, exist_ok=True)
    binary = work_app / "Contents/MacOS/Claude"
    patch.require_file(binary)
    if port_listening(port):
        raise SystemExit(
            f"Port {port} is already serving CDP. "
            f"Stop the other process or pass --port."
        )
    env = os.environ.copy()
    env["CLAUDE_USER_DATA_DIR"] = str(userdata)
    cmd = [
        str(binary),
        f"--remote-debugging-port={port}",
        f"--user-data-dir={str(userdata)}",
        "--no-first-run",
    ]
    log_path = userdata.parent / "launch.log"
    log(f"Launching: {' '.join(cmd)}")
    log(f"user-data-dir={userdata}")
    handle = log_path.open("w", encoding="utf-8")
    proc = subprocess.Popen(
        cmd,
        stdout=handle,
        stderr=subprocess.STDOUT,
        env=env,
        text=True,
    )
    # Keep file open for process lifetime; store on proc for cleanup.
    proc._claude_zh_log_handle = handle  # type: ignore[attr-defined]
    return proc


def wait_for_cdp(port: int, proc: subprocess.Popen[str], timeout: float = CDP_WAIT_SECONDS) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    attempt = 0
    while time.monotonic() < deadline:
        attempt += 1
        if proc.poll() is not None:
            raise SystemExit(
                f"Claude exited early with code {proc.returncode} before CDP became ready. "
                "See work-dir/launch.log for details."
            )
        try:
            version = http_json(f"http://127.0.0.1:{port}/json/version", timeout=0.5)
            log(f"CDP ready after {attempt} attempts")
            return version
        except Exception:
            time.sleep(0.5)
    raise SystemExit(f"Timed out waiting for CDP on 127.0.0.1:{port}")


def terminate_process(proc: subprocess.Popen[str] | None) -> None:
    if proc is None:
        return
    if proc.poll() is not None:
        handle = getattr(proc, "_claude_zh_log_handle", None)
        if handle:
            handle.close()
        return
    log(f"Stopping Claude pid={proc.pid}")
    proc.terminate()
    try:
        proc.wait(timeout=8)
    except subprocess.TimeoutExpired:
        log("Force killing Claude")
        proc.kill()
        proc.wait(timeout=3)
    handle = getattr(proc, "_claude_zh_log_handle", None)
    if handle:
        handle.close()


async def run_watchdog(port: int, script: str, proc: subprocess.Popen[str]) -> None:
    seen: dict[str, tuple[float, str]] = {}
    # Immediate inject burst while pages settle (about:blank -> claude.ai/login).
    for _ in range(8):
        if proc.poll() is not None:
            return
        await inject_all_pages(port, script, seen)
        await asyncio.sleep(1.0)

    while proc.poll() is None:
        now = time.monotonic()
        stale = [tid for tid, (ts, _url) in seen.items() if now - ts > 20.0]
        for tid in stale:
            del seen[tid]
        await inject_all_pages(port, script, seen)
        await asyncio.sleep(WATCHDOG_INTERVAL)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Experimental Claude Desktop CDP launcher: patch CDP gate in a temp app copy, "
            "start with --remote-debugging-port, inject online Chinese DOM translation."
        )
    )
    parser.add_argument(
        "--app",
        type=Path,
        default=Path("/Applications/Claude.app"),
        help="Source Claude.app (copied; not modified by default)",
    )
    parser.add_argument(
        "--work-dir",
        type=Path,
        default=DEFAULT_WORK_DIR,
        help=f"Working directory for patched app copy and userdata (default: {DEFAULT_WORK_DIR})",
    )
    parser.add_argument(
        "--lang",
        choices=["zh-CN", "zh-TW", "zh-HK"],
        default="zh-CN",
        help="Language for DOM translation resources",
    )
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help="CDP remote debugging port")
    parser.add_argument(
        "--no-inject",
        action="store_true",
        help="Only bypass gate and launch with CDP; do not inject translation",
    )
    parser.add_argument(
        "--force-repatch",
        action="store_true",
        help="Rebuild work app even if a patched copy already exists",
    )
    parser.add_argument(
        "--no-quit",
        action="store_true",
        help="Do not quit an already-running Claude before launch",
    )
    parser.add_argument(
        "--clean",
        action="store_true",
        help="Delete work-dir on exit",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    if sys.platform != "darwin":
        log("Warning: this experimental launcher is implemented/tested for macOS only.")

    args = parse_args(argv)
    source_app = args.app.expanduser().resolve()
    work_dir = args.work_dir.expanduser().resolve()
    work_app, userdata, state_path = work_paths(work_dir)
    port = int(args.port)

    if not source_app.exists():
        raise SystemExit(f"Source Claude.app not found: {source_app}")

    # Validate language resources early.
    lang_cfg = patch.get_language_config(args.lang)
    patch.require_file(lang_cfg["frontend_translation"])
    patch.require_file(lang_cfg["frontend_hardcoded"])

    if not args.no_quit:
        log("Quitting existing Claude instances (if any)")
        patch.quit_claude()
        time.sleep(0.8)

    prepare_work_app(
        source_app,
        work_app,
        force_repatch=args.force_repatch,
        state_path=state_path,
    )

    script = ""
    if not args.no_inject:
        script = build_inject_script(work_app, args.lang)

    proc: subprocess.Popen[str] | None = None
    exit_code = 0

    def _handle_signal(signum: int, _frame: Any) -> None:
        log(f"Received signal {signum}")
        terminate_process(proc)
        if args.clean and work_dir.exists():
            log(f"Cleaning work-dir {work_dir}")
            shutil.rmtree(work_dir, ignore_errors=True)
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGINT, _handle_signal)
    signal.signal(signal.SIGTERM, _handle_signal)

    try:
        proc = launch_claude(work_app, userdata, port)
        version = wait_for_cdp(port, proc)
        log(f"CDP browser: {version.get('Browser')}")
        log(f"CDP websocket: {version.get('webSocketDebuggerUrl')}")

        if args.no_inject:
            log("Launch complete (--no-inject). CDP is up; press Ctrl+C to stop.")
            while proc.poll() is None:
                time.sleep(1.0)
        else:
            log("Starting CDP inject watchdog")
            asyncio.run(run_watchdog(port, script, proc))
            # If watchdog returns because process exited:
            if proc.poll() is not None:
                log(f"Claude exited with code {proc.returncode}")
                exit_code = proc.returncode or 0
    except SystemExit:
        terminate_process(proc)
        raise
    except Exception as exc:
        log(f"Fatal error: {exc}")
        terminate_process(proc)
        exit_code = 1
    else:
        terminate_process(proc)

    if args.clean and work_dir.exists():
        log(f"Cleaning work-dir {work_dir}")
        shutil.rmtree(work_dir, ignore_errors=True)

    return int(exit_code or 0)


if __name__ == "__main__":
    raise SystemExit(main())
