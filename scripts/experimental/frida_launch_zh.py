#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Experimental: Frida Chinese for official Claude Desktop (no disk asar writes).

Modes:
  - spawn (default): Frida-spawn Claude with CDP, inject DOM + native menus
  - --watch / resident: watch for official Claude, replace process with Frida
    spawn so full DOM + menu Chinese works after clicking the app

Does NOT write app.asar on disk and does not copy the app to another path.

By default also installs zh locale resources in place (ion-dist/desktop JSON +
language whitelist + user config locale). Pure DOM inject is not enough for
onboarding/local UI while config locale stays en-US.

Resident / --watch auto-heals after Claude Desktop updates when the app
fingerprint changes (asar/binary/signature): reinstall locale resources,
re-sign for Frida, rebuild runtime gate patches. Unchanged fingerprints are
skipped (cheap poll).

Under SIP-enabled macOS, the official Developer ID + hardened runtime seal
blocks Frida attach; by default this launcher re-signs the existing
/Applications/Claude.app in place (ad-hoc, get-task-allow, no hardened
runtime) so inject works. Use --no-prepare-debug / --no-install-locale to
refuse those steps.
"""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import importlib.util
import json
import os
import re
import shutil
import signal
import sys
import time
from pathlib import Path
from typing import Any

EXPERIMENTAL_DIR = Path(__file__).resolve().parent
SCRIPTS_DIR = EXPERIMENTAL_DIR.parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))
if str(EXPERIMENTAL_DIR) not in sys.path:
    sys.path.insert(0, str(EXPERIMENTAL_DIR))

import patch_claude_zh_cn as patch  # noqa: E402

try:
    import frida
except ImportError as exc:  # pragma: no cover
    raise SystemExit(
        "Missing dependency 'frida'. Install with: python3 -m pip install frida frida-tools"
    ) from exc

try:
    import websockets  # noqa: F401
except ImportError as exc:  # pragma: no cover
    raise SystemExit(
        "Missing dependency 'websockets'. Install with: python3 -m pip install websockets"
    ) from exc

# Reuse CDP inject helpers from the asar-copy launcher without forking logic.
_cdp_spec = importlib.util.spec_from_file_location(
    "cdp_launch_zh",
    EXPERIMENTAL_DIR / "cdp_launch_zh.py",
)
if _cdp_spec is None or _cdp_spec.loader is None:
    raise SystemExit("Cannot load cdp_launch_zh.py for inject helpers")
cdp = importlib.util.module_from_spec(_cdp_spec)
_cdp_spec.loader.exec_module(cdp)

DEFAULT_PORT = 19351
CDP_WAIT_SECONDS = 35.0
FRIDA_AGENT = EXPERIMENTAL_DIR / "frida_cdp_gate.js"
FRIDA_CACHE_DIR = Path.home() / ".cache" / "frida"


def log(msg: str) -> None:
    print(msg, flush=True)


def frida_cache_dir() -> Path:
    """Directory where Frida extracts helper/agent binaries."""
    env = (
        os.environ.get("FRIDA_CACHE_DIR")
        or os.environ.get("FRIDA_CACHE")
        or ""
    ).strip()
    return Path(env).expanduser() if env else FRIDA_CACHE_DIR


def prune_frida_cache(*, keep: int = 1, reason: str = "") -> dict[str, Any]:
    """Keep only the newest *keep* frida-* cache dirs; delete older ones.

    Frida extracts ~40MB helper+agent per hash dir and never GC's them.
    After repeated spawn/attach/reinstall we can accumulate hundreds of MB.
    Safe to call anytime: only removes sibling cache dirs, never the active
    in-use helper process memory.
    """
    root = frida_cache_dir()
    summary: dict[str, Any] = {
        "root": str(root),
        "keep": int(keep),
        "before": 0,
        "removed": [],
        "kept": [],
        "reason": reason,
    }
    if keep < 1:
        keep = 1
    if not root.is_dir():
        return summary

    entries: list[tuple[float, Path]] = []
    for path in root.iterdir():
        if not path.is_dir():
            continue
        # Frida uses names like frida-<hash>
        if not path.name.startswith("frida-"):
            continue
        try:
            mtime = path.stat().st_mtime
        except OSError:
            continue
        entries.append((mtime, path))

    summary["before"] = len(entries)
    if len(entries) <= keep:
        summary["kept"] = [p.name for _, p in sorted(entries, reverse=True)]
        return summary

    entries.sort(key=lambda t: t[0], reverse=True)  # newest first
    keep_list = entries[:keep]
    drop_list = entries[keep:]
    summary["kept"] = [p.name for _, p in keep_list]
    freed = 0
    for _mtime, path in drop_list:
        try:
            # Approximate size before delete (best-effort).
            size = 0
            for dirpath, _dirnames, filenames in os.walk(path):
                for name in filenames:
                    try:
                        size += (Path(dirpath) / name).stat().st_size
                    except OSError:
                        pass
            shutil.rmtree(path, ignore_errors=True)
            if not path.exists():
                summary["removed"].append(path.name)
                freed += size
        except Exception as exc:
            log(f"Frida cache prune failed for {path.name}: {exc}")
    summary["freed_bytes"] = freed
    if summary["removed"]:
        mb = freed / (1024 * 1024)
        note = f" ({reason})" if reason else ""
        log(
            f"Frida cache prune{note}: kept {len(summary['kept'])}, "
            f"removed {len(summary['removed'])} old dir(s), ~{mb:.0f} MB freed "
            f"under {root}"
        )
    return summary


# Frida 17 removed built-in ObjC from the default QJS runtime. First access to
# globalThis.ObjC must request the bridge from the host (frida-tools ships
# bridges/objc.js). Same protocol as frida-tools REPL.
OBJC_BRIDGE_BOOTSTRAP = r"""
(function () {
  if (Object.prototype.hasOwnProperty.call(globalThis, 'ObjC')) {
    return;
  }
  Object.defineProperty(globalThis, 'ObjC', {
    enumerable: true,
    configurable: true,
    get: function () {
      var bridgeObj;
      send({ type: 'frida:load-bridge', name: 'objc' });
      recv('frida:bridge-loaded', function (message) {
        bridgeObj = Script.evaluate(
          '/frida/bridges/' + message.filename,
          '(function () { ' +
            message.source +
            ";\nObject.defineProperty(globalThis, 'ObjC', { value: bridge });\nreturn bridge;" +
            ' })();'
        );
      }).wait();
      return bridgeObj;
    },
  });
})();
"""


def asar_fingerprint(app: Path) -> dict[str, Any]:
    """Full asar fingerprint including sha256 (expensive: reads whole file)."""
    asar = app / patch.APP_ASAR_REL
    patch.require_file(asar)
    data = asar.read_bytes()
    st = asar.stat()
    return {
        "path": str(asar.resolve()),
        "sha256": hashlib.sha256(data).hexdigest(),
        "size": st.st_size,
        "mtime_ns": st.st_mtime_ns,
    }


def asar_stat_fingerprint(app: Path) -> dict[str, Any]:
    """Cheap asar fingerprint (size+mtime only; no full-file read/hash)."""
    asar = app / patch.APP_ASAR_REL
    patch.require_file(asar)
    st = asar.stat()
    return {
        "path": str(asar.resolve()),
        "sha256": None,
        "size": st.st_size,
        "mtime_ns": st.st_mtime_ns,
    }


def format_fp(fp: dict[str, Any]) -> str:
    sha = fp.get("sha256")
    sha_s = sha if sha else "stat-only"
    return f"sha256={sha_s} size={fp['size']} mtime_ns={fp['mtime_ns']}"


GATE_SUFFIX = b"(process.argv)&&!yR()&&process.exit(1)"
GATE_SUFFIX_PATCHED = b"(process.argv)&&false&&process.exit(1)"


def find_gate_bytes(content: bytes) -> tuple[bytes, bytes] | None:
    """Find CDP gate in JS content; return equal-length (old, new) or None."""
    idx = content.find(GATE_SUFFIX)
    if idx < 0:
        # Already patched?
        if content.find(GATE_SUFFIX_PATCHED) >= 0:
            return None
        return None
    # Walk back over minified identifier: [A-Za-z_$][\w$]*
    start = idx
    while start > 0:
        c = content[start - 1]
        if (
            (48 <= c <= 57)
            or (65 <= c <= 90)
            or (97 <= c <= 122)
            or c == 36
            or c == 95
        ):  # 0-9A-Za-z$_
            start -= 1
            continue
        break
    if start == idx:
        return None
    # First char must be letter / _ / $
    first = content[start]
    if not (
        (65 <= first <= 90) or (97 <= first <= 122) or first == 36 or first == 95
    ):
        return None
    gate_old = content[start : idx + len(GATE_SUFFIX)]
    gate_new = gate_old.replace(b"&&!yR()&&", b"&&false&&", 1)
    if len(gate_new) != len(gate_old) or b"&&false&&" not in gate_new:
        raise SystemExit("Failed equal-length gate rewrite")
    if content.count(gate_old) != 1:
        raise SystemExit(f"Expected exactly one CDP gate occurrence, found {content.count(gate_old)}")
    return gate_old, gate_new


def build_runtime_replacements(app: Path) -> list[dict[str, str]]:
    """
    Equal-length search/replace pairs so Frida can patch app.asar + Info.plist
    *in memory* while Electron loads them. Disk files stay stock.
    """
    asar_path = app / patch.APP_ASAR_REL
    patch.require_file(asar_path)
    data = asar_path.read_bytes()
    header_size, header_string, header = patch.read_asar_header(data, asar_path)

    # Prefer main-process vite bundles; fall back to any .js containing the gate.
    candidates: list[str] = []
    others: list[str] = []
    for file_path, entry in patch.iter_asar_files(header):
        if "offset" not in entry or "size" not in entry:
            continue
        if not file_path.endswith(".js"):
            continue
        if file_path.startswith(".vite/build/"):
            candidates.append(file_path)
        else:
            others.append(file_path)

    gate_file: str | None = None
    gate_old = b""
    gate_new = b""
    content = b""
    for file_path in candidates + others:
        entry = patch.get_asar_file_entry(header, file_path)
        # Slice without re-copying via helper when possible.
        content_offset = 8 + header_size + int(entry["offset"])
        content_size = int(entry["size"])
        blob = data[content_offset : content_offset + content_size]
        discovered = find_gate_bytes(blob)
        if discovered is None:
            continue
        gate_old, gate_new = discovered
        gate_file = file_path
        content = blob
        break

    if not gate_file:
        raise SystemExit(
            "CDP gate pattern not found in app.asar. "
            "This Claude Desktop version may have changed; Frida PoC cannot continue."
        )

    entry = patch.get_asar_file_entry(header, gate_file)
    patched = content.replace(gate_old, gate_new, 1)
    if len(patched) != len(content):
        raise SystemExit("Internal error: gate replacement changed length")

    old_integrity = entry.get("integrity")
    if not isinstance(old_integrity, dict) or "hash" not in old_integrity:
        raise SystemExit(f"Missing integrity metadata for {gate_file}")
    new_integrity = patch.calculate_file_integrity(patched)

    old_int_json = json.dumps(old_integrity, separators=(",", ":"), ensure_ascii=False)
    new_int_json = json.dumps(new_integrity, separators=(",", ":"), ensure_ascii=False)
    if len(old_int_json) != len(new_int_json):
        raise SystemExit(
            "Integrity JSON length changed after gate patch; refuse unsafe runtime patch"
        )

    header_copy = json.loads(header_string)

    def _update_integrity(node: Any, parts: list[str]) -> bool:
        if not parts:
            return False
        files = node.get("files") if isinstance(node, dict) else None
        if not isinstance(files, dict):
            return False
        head, *tail = parts
        child = files.get(head)
        if child is None:
            return False
        if not tail:
            if isinstance(child, dict):
                child["integrity"] = new_integrity
                return True
            return False
        return _update_integrity(child, tail)

    parts = gate_file.split("/")
    if not _update_integrity(header_copy, parts):
        if old_int_json not in header_string:
            raise SystemExit("Could not locate integrity JSON in asar header")
        new_header_string = header_string.replace(old_int_json, new_int_json, 1)
    else:
        new_header_string = json.dumps(header_copy, separators=(",", ":"), ensure_ascii=False)
        if len(new_header_string) != len(header_string):
            if old_int_json not in header_string:
                raise SystemExit(
                    f"Header length drift ({len(header_string)} -> {len(new_header_string)}) "
                    "and integrity blob missing from header string"
                )
            new_header_string = header_string.replace(old_int_json, new_int_json, 1)

    if len(new_header_string) != len(header_string):
        raise SystemExit(
            f"Header string length changed ({len(header_string)} -> {len(new_header_string)})"
        )

    old_header_hash = hashlib.sha256(header_string.encode("utf-8")).hexdigest()
    new_header_hash = hashlib.sha256(new_header_string.encode("utf-8")).hexdigest()

    gate_old_s = gate_old.decode("ascii")
    gate_new_s = gate_new.decode("ascii")
    replacements: list[dict[str, str]] = [
        {"old": gate_old_s, "new": gate_new_s, "label": "gate"},
        {
            "old": str(old_integrity["hash"]),
            "new": str(new_integrity["hash"]),
            "label": "file-hash",
        },
    ]
    old_blocks = old_integrity.get("blocks") or []
    new_blocks = new_integrity.get("blocks") or []
    for i, (ob, nb) in enumerate(zip(old_blocks, new_blocks)):
        if ob != nb:
            if len(str(ob)) != len(str(nb)):
                raise SystemExit(f"Block hash length mismatch at {i}")
            replacements.append({"old": str(ob), "new": str(nb), "label": f"block-{i}"})
    replacements.append(
        {"old": old_header_hash, "new": new_header_hash, "label": "header-hash-plist"}
    )

    if old_int_json in header_string and old_int_json != new_int_json:
        replacements.insert(
            1,
            {"old": old_int_json, "new": new_int_json, "label": "integrity-json"},
        )

    log(f"Prepared {len(replacements)} runtime replacements for {gate_file}")
    log(f"  gate: {gate_old_s} -> {gate_new_s}")
    for item in replacements:
        if item["label"] == "gate":
            continue
        log(f"  - {item['label']}: {item['old'][:28]}… -> {item['new'][:28]}…")
    return replacements


def build_menu_map(lang_code: str) -> dict[str, str]:
    """English -> Chinese labels for native NSMenuItem title rewrite under Frida.

    Unlike asar equal-length patching, this map is free of byte-length limits
    because we rewrite titles at the Cocoa layer after Electron builds menus.
    """
    labels = patch.get_main_process_menu_replacements(lang_code)
    roles = patch.get_main_process_menu_role_replacements(lang_code)

    menu_map: dict[str, str] = dict(labels)

    # Role fallbacks use the same human-readable English titles Electron shows
    # when a MenuItem has role but no explicit label.
    role_english_defaults = {
        "about": "About Claude",
        "hide": "Hide Claude",
        "hideOthers": "Hide Others",
        "unhide": "Show All",
        "quit": "Quit Claude",
        "close": "Close Window",
        "minimize": "Minimize",
        "zoom": "Zoom",
        "front": "Bring All to Front",
        "window": "Window",
        "help": "Help",
        "services": "Services",
        "undo": "Undo",
        "redo": "Redo",
        "cut": "Cut",
        "copy": "Copy",
        "paste": "Paste",
        "pasteAndMatchStyle": "Paste and Match Style",
        "delete": "Delete",
        "selectAll": "Select All",
        "reload": "Reload",
        "forceReload": "Force Reload",
        "toggleDevTools": "Toggle Developer Tools",
        "resetZoom": "Actual Size",
        "zoomIn": "Zoom In",
        "zoomOut": "Zoom Out",
        "togglefullscreen": "Toggle Full Screen",
        "startSpeaking": "Start Speaking",
        "stopSpeaking": "Stop Speaking",
    }
    for role, en in role_english_defaults.items():
        zh = roles.get(role) or roles.get(role[0].lower() + role[1:] if role else role)
        if zh and en not in menu_map:
            menu_map[en] = zh

    # Titles that appear in Help but may not be in the main label map.
    extras = {
        "zh-CN": {
            "Claude Help": "Claude 帮助",
            "Window": "窗口",
        },
        "zh-TW": {
            "Claude Help": "Claude 說明",
            "Window": "視窗",
        },
        "zh-HK": {
            "Claude Help": "Claude 說明",
            "Window": "視窗",
        },
    }
    menu_map.update(extras.get(lang_code, extras["zh-CN"]))
    return menu_map


def process_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def wait_for_cdp_pid(port: int, pid: int, timeout: float = CDP_WAIT_SECONDS) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    attempt = 0
    while time.monotonic() < deadline:
        attempt += 1
        if not process_alive(pid):
            raise SystemExit(
                f"Claude pid={pid} exited before CDP became ready "
                f"(after {attempt} attempts). Frida gate may have failed."
            )
        try:
            version = cdp.http_json(f"http://127.0.0.1:{port}/json/version", timeout=0.5)
            log(f"CDP ready after {attempt} attempts")
            return version
        except Exception:
            time.sleep(0.5)
    raise SystemExit(f"Timed out waiting for CDP on 127.0.0.1:{port}")


class PidProc:
    """Minimal stand-in so cdp.run_watchdog can poll process liveness."""

    def __init__(self, pid: int) -> None:
        self.pid = pid
        self.returncode: int | None = None

    def poll(self) -> int | None:
        if self.returncode is not None:
            return self.returncode
        if process_alive(self.pid):
            return None
        self.returncode = 0
        return self.returncode


def find_frida_objc_bridge() -> Path | None:
    """Locate frida-tools' ObjC bridge (required on Frida 17+).

    Search order:
      1) FRIDA_OBJC_BRIDGE / FRIDA_BRIDGE_OBJC env
      2) installed frida_tools package
      3) interpreter purelib site-packages
      4) bundled vendor/frida-bridges/objc.js next to this launcher
    """
    # 1) Explicit override
    env = os.environ.get("FRIDA_OBJC_BRIDGE") or os.environ.get("FRIDA_BRIDGE_OBJC")
    if env:
        p = Path(env).expanduser()
        if p.is_file():
            return p

    # 2) frida_tools package
    try:
        import frida_tools  # type: ignore

        candidate = Path(frida_tools.__file__).resolve().parent / "bridges" / "objc.js"
        if candidate.is_file():
            return candidate
    except Exception:
        pass

    # 3) Common site-packages layouts next to the running interpreter
    try:
        import sysconfig

        purelib = Path(sysconfig.get_paths().get("purelib", ""))
        candidate = purelib / "frida_tools" / "bridges" / "objc.js"
        if candidate.is_file():
            return candidate
    except Exception:
        pass

    # 4) Bundled fallback shipped with this repo (no frida-tools import needed)
    bundled = EXPERIMENTAL_DIR / "objc.js"
    if bundled.is_file():
        return bundled

    return None


def make_frida_message_handler(
    script_holder: dict[str, Any],
) -> Any:
    """Build a Frida on_message callback that can serve the ObjC bridge.

    Frida 17 no longer embeds ObjC in the default runtime. Agent code that
    touches `ObjC` must send `{type:'frida:load-bridge', name:'objc'}` and the
    host must reply with the bridge source — same protocol frida-tools REPL uses.
    """

    bridge_cache: dict[str, str] = {}

    def _load_bridge_source(stem: str) -> tuple[str, str] | None:
        stem = (stem or "objc").lower()
        if stem in bridge_cache:
            return f"{stem}.js", bridge_cache[stem]
        if stem in {"objc", "frida-objc-bridge"}:
            path = find_frida_objc_bridge()
            if path is None:
                return None
            text = path.read_text(encoding="utf-8")
            bridge_cache["objc"] = text
            bridge_cache["frida-objc-bridge"] = text
            return path.name, text
        # Try frida_tools/bridges/<stem>.js for swift/java if ever needed.
        try:
            import frida_tools  # type: ignore

            path = Path(frida_tools.__file__).resolve().parent / "bridges" / f"{stem}.js"
            if path.is_file():
                text = path.read_text(encoding="utf-8")
                bridge_cache[stem] = text
                return path.name, text
        except Exception:
            pass
        return None

    def on_frida_message(message: dict[str, Any], data: Any) -> None:
        if message.get("type") == "send":
            payload = message.get("payload")
            if isinstance(payload, dict) and payload.get("type") == "frida:load-bridge":
                stem = str(payload.get("name") or "objc")
                loaded = _load_bridge_source(stem)
                script = script_holder.get("script")
                if loaded is None or script is None:
                    log(
                        f"[frida] ObjC bridge unavailable for name={stem!r}. "
                        "Install frida-tools or set FRIDA_OBJC_BRIDGE=/path/to/objc.js"
                    )
                    return
                filename, source = loaded
                try:
                    script.post(
                        {
                            "type": "frida:bridge-loaded",
                            "filename": filename,
                            "source": source,
                        }
                    )
                    log(f"[frida] served bridge {filename} ({len(source)} bytes)")
                except Exception as exc:
                    log(f"[frida] failed to post bridge {filename}: {exc}")
                return
            if isinstance(payload, dict) and payload.get("type") == "log":
                log(str(payload.get("message") or payload))
            else:
                log(f"[frida] {payload!r}")
        elif message.get("type") == "error":
            log(f"[frida-error] {message}")

    return on_frida_message


def process_cmdline(pid: int) -> str:
    import subprocess

    try:
        out = subprocess.check_output(
            ["ps", "-p", str(pid), "-o", "command="],
            text=True,
            stderr=subprocess.DEVNULL,
        )
        return out.strip()
    except Exception:
        return ""


def find_claude_pids(binary: Path) -> list[int]:
    """PIDs whose command is the main Claude Desktop binary (not Helpers)."""
    import subprocess

    target = str(binary.expanduser().resolve())
    target_name = binary.name  # usually "Claude"
    try:
        out = subprocess.check_output(
            ["ps", "-ax", "-o", "pid=,command="],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except Exception:
        return []

    pids: list[int] = []
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(None, 1)
        if len(parts) < 2:
            continue
        pid_s, cmd = parts[0], parts[1]
        if "Helper" in cmd:
            continue
        if target in cmd or (
            f"Claude.app/Contents/MacOS/{target_name}" in cmd and "Helper" not in cmd
        ):
            try:
                pids.append(int(pid_s))
            except ValueError:
                continue
    return sorted(set(pids))


def cmdline_has_cdp(pid: int, port: int | None = None) -> bool:
    cmd = process_cmdline(pid)
    if "--remote-debugging-port" not in cmd:
        return False
    if port is None:
        return True
    return f"--remote-debugging-port={port}" in cmd or (
        f"--remote-debugging-port {port}" in cmd
    )


def discover_cdp_port(pid: int, preferred: int) -> int | None:
    if cmdline_has_cdp(pid, preferred) and cdp.port_listening(preferred):
        return preferred
    cmd = process_cmdline(pid)
    m = re.search(r"--remote-debugging-port(?:=|\s+)(\d+)", cmd)
    if m:
        p = int(m.group(1))
        if cdp.port_listening(p):
            return p
    if cdp.port_listening(preferred):
        return preferred
    return None


def detach_only(
    session: frida.core.Session | None, script: frida.core.Script | None
) -> None:
    """Leave Claude running; only drop Frida hooks."""
    if script is not None:
        try:
            script.unload()
        except Exception:
            pass
    if session is not None:
        try:
            session.detach()
        except Exception:
            pass


def attach_to_pid(
    pid: int,
    mode: str,
    replacements: list[dict[str, str]],
    menu_map: dict[str, str] | None = None,
) -> tuple[Any, frida.core.Session, frida.core.Script, int]:
    """Attach to an already-running official Claude (Dock / open -a)."""
    if not FRIDA_AGENT.exists():
        raise SystemExit(f"Missing Frida agent: {FRIDA_AGENT}")

    device = frida.get_local_device()
    log(f"Frida attach to running Claude pid={pid}")
    log(f"  cmdline: {process_cmdline(pid)[:180]}")
    try:
        session = device.attach(pid)
    except frida.PermissionDeniedError as exc:
        raise SystemExit(
            f"Frida attach permission denied on pid={pid}.\n"
            + _frida_blocked_hint(Path("/Applications/Claude.app"))
        ) from exc
    except Exception as exc:
        raise SystemExit(
            f"Frida attach failed on pid={pid}: {type(exc).__name__}: {exc}\n"
            + _frida_blocked_hint(Path("/Applications/Claude.app"))
        ) from exc

    source = FRIDA_AGENT.read_text(encoding="utf-8")
    if "installBridgeGetter" not in source and "frida:load-bridge" not in source:
        source = OBJC_BRIDGE_BOOTSTRAP + "\n" + source
    script_holder: dict[str, Any] = {"script": None}
    script = session.create_script(source)
    script_holder["script"] = script
    script.on("message", make_frida_message_handler(script_holder))
    if menu_map and find_frida_objc_bridge() is None:
        log(
            "WARNING: frida-tools ObjC bridge not found; native menu rewrite will "
            "stay disabled. pip install frida-tools  (or set FRIDA_OBJC_BRIDGE)"
        )
    script.load()
    try:
        status = script.exports_sync.configure(
            {
                "mode": mode,
                "replacements": replacements,
                "menuMap": menu_map or {},
            }
        )
        log(f"Frida agent status: {json.dumps(status, ensure_ascii=False)}")
        if menu_map:
            log(
                f"Menu map: {len(menu_map)} labels; "
                f"native_hook={status.get('menuHooked')} "
                f"map_size={status.get('menuMapSize')}"
            )
        # Attach path: asar already mapped — IO hooks miss it; scan memory.
        try:
            result = script.exports_sync.rescan()
            log(
                "Mem rescan after attach: "
                + json.dumps(result, ensure_ascii=False)[:500]
            )
        except Exception as exc:
            log(f"Mem rescan failed: {exc}")
    except Exception as exc:
        try:
            session.detach()
        except Exception:
            pass
        raise SystemExit(f"Frida configure on attach failed: {exc}") from exc

    # New helper/agent cache dir may have been created on attach.
    prune_frida_cache(keep=1, reason="after-attach")
    return device, session, script, int(pid)


def _frida_blocked_hint(app: Path) -> str:
    """Human-readable next steps when Frida cannot attach under SIP."""
    try:
        info = patch.codesign_info(app)
        detail = (
            f"codesign flags={info.get('flags')!r} "
            f"get_task_allow={info.get('get_task_allow')} "
            f"hardened_runtime={info.get('hardened_runtime')}"
        )
    except Exception as exc:  # pragma: no cover
        detail = f"codesign probe failed: {exc}"
    return (
        "macOS blocked Frida inject (common with official Developer ID + hardened "
        "runtime while SIP is still on). Fix without copying the app:\n"
        "  1) Re-run without --no-prepare-debug (default auto re-signs in place: "
        "ad-hoc + get-task-allow, no hardened runtime; app.asar stays stock), OR\n"
        "  2) Fully disable SIP from Recovery (csrutil disable) and reboot, then "
        "confirm `csrutil status` shows disabled.\n"
        f"Current signature: {detail}"
    )


def locale_resources_ready(app: Path, lang_code: str) -> bool:
    """True when zh locale files + language whitelist look installed for Frida i18n."""
    frontend = app / patch.FRONTEND_I18N_REL / f"{lang_code}.json"
    desktop = app / patch.DESKTOP_RESOURCES_REL / f"{lang_code}.json"
    if not frontend.is_file() or not desktop.is_file():
        return False
    # Whitelist: ion-dist frontend JS must mention the lang code.
    assets = app / patch.FRONTEND_ASSETS_REL
    if not assets.is_dir():
        return False
    needle = f'"{lang_code}"'
    for path in assets.glob("*.js"):
        try:
            # Only scan reasonably small bundles first; whitelist lives in shared-*.js.
            if path.stat().st_size > 8_000_000:
                continue
            if needle in path.read_text(encoding="utf-8", errors="ignore"):
                return True
        except Exception:
            continue
    return False


def user_config_locale_paths(user_home: Path) -> list[Path]:
    paths = [user_home / "Library/Application Support/Claude/config.json"]
    p3 = user_home / "Library/Application Support/Claude-3p/config.json"
    if p3.parent.exists():
        paths.append(p3)
    return paths


def read_user_locales(user_home: Path) -> dict[str, str | None]:
    """Return {config_path: locale_or_None} for Claude user configs."""
    out: dict[str, str | None] = {}
    for config in user_config_locale_paths(user_home):
        if not config.is_file():
            out[str(config)] = None
            continue
        try:
            data = json.loads(config.read_text(encoding="utf-8"))
            if isinstance(data, dict):
                loc = data.get("locale")
                out[str(config)] = str(loc) if loc is not None else None
            else:
                out[str(config)] = None
        except Exception:
            out[str(config)] = None
    return out


def user_locale_needs_fix(user_home: Path, lang_code: str) -> bool:
    """True if any Claude config is missing or not the target locale (e.g. en-US)."""
    locales = read_user_locales(user_home)
    if not locales:
        return True
    for _path, loc in locales.items():
        if loc != lang_code:
            return True
    return False


def ensure_user_locale_if_wrong(
    user_home: Path,
    lang_code: str,
    *,
    reason: str = "",
) -> bool:
    """Write locale only when config is wrong/missing. Returns True if a write was attempted."""
    if not user_locale_needs_fix(user_home, lang_code):
        return False
    before = read_user_locales(user_home)
    wrong = {p: loc for p, loc in before.items() if loc != lang_code}
    note = f" ({reason})" if reason else ""
    log(
        f"User locale not {lang_code}{note}: "
        + ", ".join(f"{Path(p).name}={loc!r}" for p, loc in wrong.items())
        + f" → set {lang_code}"
    )
    try:
        patch.set_user_locale(user_home, lang_code)
    except Exception as exc:
        log(f"set_user_locale warning: {exc}")
        return False
    return True


def app_runtime_fingerprint(app: Path, *, cheap: bool = True) -> dict[str, Any]:
    """Fingerprint used to detect Claude Desktop updates / reinstalls.

    cheap=True (default for watch polls): only stat() size/mtime of asar + binary.
    Does NOT read the ~37MB asar or run codesign — those dominate idle CPU.

    cheap=False: full asar sha256 + codesign summary (for logging / prepare).
    """
    asar = asar_stat_fingerprint(app) if cheap else asar_fingerprint(app)
    binary = app / "Contents/MacOS/Claude"
    try:
        bst = binary.stat()
        binary_meta = {"size": bst.st_size, "mtime_ns": bst.st_mtime_ns}
    except OSError:
        binary_meta = {"size": None, "mtime_ns": None}
    if cheap:
        sig_meta = {}
    else:
        try:
            sig = patch.codesign_info(app)
            sig_meta = {
                "flags": sig.get("flags"),
                "get_task_allow": sig.get("get_task_allow"),
                "hardened_runtime": sig.get("hardened_runtime"),
                "adhoc": sig.get("adhoc"),
            }
        except Exception:
            sig_meta = {}
    return {
        "asar": asar,
        "binary": binary_meta,
        "signature": sig_meta,
        "locale_ready": False,  # filled by caller when lang known
        "cheap": cheap,
    }


def fingerprints_equal(a: dict[str, Any] | None, b: dict[str, Any] | None) -> bool:
    if not a or not b:
        return False
    try:
        aa, ba = a.get("asar") or {}, b.get("asar") or {}
        # Prefer size+mtime (always present). sha256 only if both sides have it.
        if aa.get("size") != ba.get("size") or aa.get("mtime_ns") != ba.get("mtime_ns"):
            return False
        sa, sb = aa.get("sha256"), ba.get("sha256")
        if sa and sb and sa != sb:
            return False
        ab, bb = a.get("binary") or {}, b.get("binary") or {}
        if ab.get("size") != bb.get("size") or ab.get("mtime_ns") != bb.get("mtime_ns"):
            return False
        # Signature only compared when both fingerprints carried it (non-cheap).
        sig_a, sig_b = a.get("signature") or {}, b.get("signature") or {}
        if sig_a and sig_b and sig_a != sig_b:
            return False
        return True
    except Exception:
        return False


def ensure_locale_resources(
    app: Path,
    lang_code: str,
    *,
    user_home: Path,
    install: bool,
    force: bool = False,
) -> bool:
    """Install zh locale resources into official app if missing.

    Returns True if the app tree was modified (caller should re-sign).
    Does not write app.asar and does not copy the app bundle.

    User config locale is written only when wrong/missing (startup prepare or
    detected en-US), not forced on every call.
    """
    try:
        ensure_user_locale_if_wrong(user_home, lang_code, reason="prepare")
    except Exception as exc:
        log(f"set_user_locale warning: {exc}")

    ready = locale_resources_ready(app, lang_code)
    if ready and not force:
        log(f"Locale resources already present for {lang_code}")
        return False

    if not install:
        if force and ready:
            return False
        raise SystemExit(
            f"Locale resources for {lang_code} are not installed in {app} and "
            "--no-install-locale was set. Onboarding/local UI will stay English.\n"
            "Re-run without --no-install-locale (default installs ion-dist/desktop "
            "zh JSON + language whitelist; still no app.asar write / no app copy)."
        )

    why = "forced re-install after app change" if force and ready else "missing"
    log(
        f"Installing {lang_code} locale resources into official app ({why}; "
        "ion-dist/desktop JSON + language whitelist; no app.asar, no app copy)…"
    )
    asar_before = asar_fingerprint(app)
    try:
        summary = patch.install_locale_resources_in_place(
            app,
            lang_code,
            user_home=user_home,
            patch_frontend_js=True,
        )
        log(f"Locale install summary: {json.dumps(summary, ensure_ascii=False)[:800]}")
    except SystemExit:
        raise
    except Exception as exc:
        raise SystemExit(
            f"Failed to install locale resources: {type(exc).__name__}: {exc}"
        ) from exc
    asar_after = asar_fingerprint(app)
    if asar_before["sha256"] != asar_after["sha256"]:
        raise SystemExit(
            "Refusing to continue: app.asar changed while installing locale resources "
            f"({asar_before['sha256']} -> {asar_after['sha256']})."
        )
    if not locale_resources_ready(app, lang_code):
        raise SystemExit(
            f"Locale resources for {lang_code} still missing after install. "
            "Check write permission on /Applications/Claude.app/Contents/Resources."
        )
    log("Locale resources installed (app.asar unchanged)")
    return True


def ensure_app_frida_ready(
    app: Path,
    *,
    allow_resign: bool,
    force_resign: bool = False,
) -> bool:
    """Make sure *app* can be Frida-spawned. Optionally re-sign in place.

    Returns True if a re-sign was performed.
    Does not copy Claude.app and does not write app.asar. Only the code
    signature / entitlements of the existing official bundle are changed when
    allow_resign=True.
    """
    if patch.app_frida_debug_ready(app) and not force_resign:
        log(
            "Claude.app already Frida-ready "
            "(ad-hoc, get-task-allow, no hardened runtime); skip re-sign"
        )
        return False

    if not allow_resign:
        raise SystemExit(
            "Claude.app is not Frida-ready and --no-prepare-debug was set.\n"
            + _frida_blocked_hint(app)
        )

    log(
        "Preparing official Claude.app for Frida (in-place ad-hoc re-sign only; "
        "no app copy, no app.asar writes)…"
    )
    asar_before = asar_fingerprint(app)
    try:
        patch.resign_app_for_frida(app)
    except SystemExit:
        raise
    except Exception as exc:
        raise SystemExit(
            f"Failed to re-sign Claude.app for Frida: {type(exc).__name__}: {exc}\n"
            "Need write access to /Applications/Claude.app (re-run with sudo if required)."
        ) from exc
    asar_after = asar_fingerprint(app)
    if asar_before["sha256"] != asar_after["sha256"]:
        raise SystemExit(
            "Refusing to continue: app.asar fingerprint changed during debug re-sign "
            f"({asar_before['sha256']} -> {asar_after['sha256']}). "
            "This step must only touch the code signature."
        )
    log(f"ASAR after debug re-sign: {format_fp(asar_after)} (unchanged)")
    return True


def prepare_runtime_payload(
    app: Path,
    lang_code: str,
    *,
    user_home: Path,
    install_locale: bool,
    allow_resign: bool,
    no_inject: bool,
    force_locale: bool = False,
    reason: str = "startup",
) -> dict[str, Any]:
    """Prepare official app + build Frida/CDP runtime artifacts.

    Safe to call repeatedly from the resident watch loop after Claude updates:
    - reinstall zh locale resources if missing / force
    - re-sign for Frida if needed
    - rebuild gate replacements + DOM inject script for the current asar
    """
    log(f"Prepare runtime payload ({reason})")
    resources_changed = ensure_locale_resources(
        app,
        lang_code,
        user_home=user_home,
        install=install_locale,
        force=force_locale,
    )
    ensure_app_frida_ready(
        app,
        allow_resign=allow_resign,
        force_resign=resources_changed,
    )

    before = asar_fingerprint(app)
    replacements = build_runtime_replacements(app)
    menu_map = build_menu_map(lang_code)
    log(f"Prepared native menu map: {len(menu_map)} entries for {lang_code}")
    script_src = ""
    if not no_inject:
        script_src = cdp.build_inject_script(app, lang_code)

    fp = app_runtime_fingerprint(app, cheap=False)
    # Still store a cheap-comparable asar view for watch polls (size+mtime).
    fp["asar"] = {
        "path": before.get("path"),
        "sha256": None,  # watch compares size/mtime only
        "size": before.get("size"),
        "mtime_ns": before.get("mtime_ns"),
    }
    fp["locale_ready"] = locale_resources_ready(app, lang_code)
    fp["asar_full"] = before
    return {
        "before": before,
        "replacements": replacements,
        "menu_map": menu_map,
        "script_src": script_src,
        "fingerprint": fp,
        "resources_changed": resources_changed,
    }


def spawn_with_frida(
    binary: Path,
    port: int,
    mode: str,
    replacements: list[dict[str, str]],
    menu_map: dict[str, str] | None = None,
) -> tuple[Any, frida.core.Session, frida.core.Script, int]:
    if not FRIDA_AGENT.exists():
        raise SystemExit(f"Missing Frida agent: {FRIDA_AGENT}")
    # Port freeness is enforced by ensure_cdp_port_free() in main() right
    # before spawn; keep a last-moment guard here in case something raced in.
    if cdp.port_listening(port):
        ensure_cdp_port_free(port, soft_quit=False, wait_seconds=3.0)
        if cdp.port_listening(port):
            raise SystemExit(
                f"Port {port} is already serving CDP. Stop the other process or pass --port."
            )

    argv = [
        str(binary),
        f"--remote-debugging-port={port}",
    ]
    env = {**os.environ}
    # Do NOT set CLAUDE_USER_DATA_DIR or --user-data-dir: Claude's internal
    # Ta() appends "-3p" to the userData path when deploymentMode is "3p",
    # but skips that when CLAUDE_USER_DATA_DIR is set.  Overriding the
    # userdata breaks 3p mode because the app reads config/session/cookies
    # from the wrong directory.  Let the app use its own directory resolution.
    log(f"Frida spawn: {' '.join(argv)}")
    log(f"gate mode={mode}")

    device = frida.get_local_device()
    try:
        pid = device.spawn(
            [str(binary), *argv[1:]],
            env=env,
            cwd=str(binary.parent),
            stdio="pipe",
        )
    except frida.ExecutableNotFoundError as exc:
        raise SystemExit(f"Frida could not spawn binary: {binary}: {exc}") from exc
    except frida.PermissionDeniedError as exc:
        raise SystemExit(
            "Frida spawn permission denied.\n" + _frida_blocked_hint(binary.parent.parent.parent)
        ) from exc
    except Exception as exc:
        raise SystemExit(f"Frida spawn failed: {type(exc).__name__}: {exc}") from exc

    log(f"Spawned pid={pid} (suspended); loading agent")
    try:
        session = device.attach(pid)
    except Exception as exc:
        try:
            device.kill(pid)
        except Exception:
            pass
        raise SystemExit(
            f"Frida attach failed on pid={pid}: {type(exc).__name__}: {exc}\n"
            + _frida_blocked_hint(binary.parent.parent.parent)
        ) from exc

    source = FRIDA_AGENT.read_text(encoding="utf-8")
    # Frida 17+: ObjC is an on-demand bridge. Prepend a getter that requests it
    # the first time agent code touches globalThis.ObjC.
    if "installBridgeGetter" not in source and "frida:load-bridge" not in source:
        source = OBJC_BRIDGE_BOOTSTRAP + "\n" + source
    script_holder: dict[str, Any] = {"script": None}
    script = session.create_script(source)
    script_holder["script"] = script
    script.on("message", make_frida_message_handler(script_holder))
    # Fail fast with a clear message if frida-tools bridge is missing.
    if menu_map and find_frida_objc_bridge() is None:
        log(
            "WARNING: frida-tools ObjC bridge not found; native menu rewrite will "
            "stay disabled. pip install frida-tools  (or set FRIDA_OBJC_BRIDGE)"
        )
    script.load()
    try:
        status = script.exports_sync.configure(
            {
                "mode": mode,
                "replacements": replacements,
                "menuMap": menu_map or {},
            }
        )
        log(f"Frida agent status: {json.dumps(status, ensure_ascii=False)}")
        if menu_map:
            log(
                f"Menu map: {len(menu_map)} labels; "
                f"native_hook={status.get('menuHooked')} "
                f"map_size={status.get('menuMapSize')}"
            )
    except Exception as exc:
        try:
            device.kill(pid)
        except Exception:
            pass
        raise SystemExit(f"Frida configure failed: {exc}") from exc

    # IO hooks must be active before resume so open/read of app.asar is patched.
    device.resume(pid)
    log(f"Resumed pid={pid}")

    # Brief wait for first IO patches; never call expensive mem rescan here.
    for i in range(25):
        if not process_alive(int(pid)):
            break
        try:
            st = script.exports_sync.get_status()
            if st.get("ioPatches"):
                log(
                    "Gate patch progress: "
                    f"io={st.get('ioPatches')} mem={st.get('memPatchHits')} "
                    f"fds={st.get('trackedFds')}"
                )
                break
        except Exception as exc:
            log(f"Status poll failed: {exc}")
            break
        time.sleep(0.15)

    # Menu hooks intentionally deferred until after CDP is up (see main):
    # installing NSMenuItem interceptors too early can abort Electron startup.
    prune_frida_cache(keep=1, reason="after-spawn")
    return device, session, script, int(pid)


def _call_menu_install(script: frida.core.Script) -> dict[str, Any]:
    """Call agent installMenuHooks via Frida RPC (camelCase or snake_case)."""
    exports = script.exports_sync
    for name in ("install_menu_hooks", "installMenuHooks"):
        fn = getattr(exports, name, None)
        if callable(fn):
            result = fn()
            return result if isinstance(result, dict) else {"ok": bool(result), "raw": result}
    raise AttributeError("Frida agent has no installMenuHooks export")


def install_native_menu_hooks(
    script: frida.core.Script,
    pid: int,
    *,
    attempts: int = 20,
    interval: float = 0.25,
) -> bool:
    """Retry ObjC NSMenuItem hooks until the runtime is live or attempts run out."""
    last: dict[str, Any] = {}
    for i in range(attempts):
        if not process_alive(int(pid)):
            log("Menu hook install aborted: process exited")
            return False
        try:
            last = _call_menu_install(script)
        except Exception as exc:
            log(f"Menu hook install attempt {i + 1}/{attempts} failed: {exc}")
            time.sleep(interval)
            continue

        hooked = bool(last.get("menuHooked") or last.get("ok"))
        objc = last.get("objc")
        patches = last.get("menuPatches", 0)
        rewritten = last.get("rewritten", 0)
        if hooked:
            log(
                f"Native menu hooks ready "
                f"(attempt {i + 1}/{attempts}, objc={objc}, "
                f"rewritten={rewritten}, menuPatches={patches})"
            )
            return True
        if i == 0 or (i + 1) % 5 == 0:
            log(
                f"Waiting for ObjC/AppKit menu hooks "
                f"({i + 1}/{attempts}, objc={objc}, hooked={hooked})"
            )
        time.sleep(interval)

    log(
        "WARNING: native menu hooks did not attach "
        f"(last={json.dumps(last, ensure_ascii=False)}). "
        "Top menu bar may stay English; DOM inject still works."
    )
    return False


def kill_pid(pid: int) -> None:
    if pid <= 0 or not process_alive(pid):
        return
    log(f"Stopping Claude pid={pid}")
    for sig in (signal.SIGKILL,):
        try:
            os.kill(pid, sig)
        except ProcessLookupError:
            return
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        if not process_alive(pid):
            return
        time.sleep(0.05)


def kill_frida_tree(device: Any | None, pid: int) -> None:
    """Best-effort teardown: Frida device.kill + SIGKILL + helper cleanup."""
    if device is not None and pid:
        try:
            device.kill(pid)
        except Exception:
            pass
    kill_pid(pid)
    try:
        import subprocess

        subprocess.run(
            ["pkill", "-9", "-f", "frida-helper"],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except Exception:
        pass


def _pids_listening_on_port(port: int) -> list[int]:
    """Return PIDs with a TCP LISTEN socket on 127.0.0.1:port (best-effort)."""
    import subprocess

    try:
        proc = subprocess.run(
            ["lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-t"],
            check=False,
            capture_output=True,
            text=True,
        )
    except Exception:
        return []
    pids: list[int] = []
    for line in (proc.stdout or "").splitlines():
        line = line.strip()
        if line.isdigit():
            pids.append(int(line))
    return pids


def ensure_cdp_port_free(port: int, *, soft_quit: bool = True, wait_seconds: float = 5.0) -> None:
    """Make sure nothing is already serving CDP on *port* before Frida spawn.

    Previous Frida runs (or a normal Claude still shutting down) can leave
    127.0.0.1:port in LISTEN.  A soft AppleScript quit alone is not enough for
    Frida-spawned processes, so we escalate: soft quit → pkill Claude → kill
    listeners on the port → wait until /json/version stops answering.
    """
    import subprocess

    if soft_quit:
        try:
            patch.quit_claude()
        except Exception:
            pass
        time.sleep(0.4)

    if not cdp.port_listening(port) and not _pids_listening_on_port(port):
        return

    log(f"CDP port {port} still busy; forcing cleanup")
    try:
        subprocess.run(
            ["pkill", "-9", "-x", "Claude"],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except Exception:
        pass
    try:
        subprocess.run(
            ["pkill", "-9", "-f", "frida-helper"],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except Exception:
        pass
    try:
        subprocess.run(
            ["pkill", "-9", "-f", "frida_launch_zh"],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except Exception:
        pass

    for listener_pid in _pids_listening_on_port(port):
        log(f"Killing listener pid={listener_pid} on port {port}")
        kill_pid(listener_pid)

    deadline = time.monotonic() + wait_seconds
    while time.monotonic() < deadline:
        if not cdp.port_listening(port) and not _pids_listening_on_port(port):
            log(f"CDP port {port} is free")
            return
        time.sleep(0.15)

    still = _pids_listening_on_port(port)
    detail = f" listeners={still}" if still else ""
    raise SystemExit(
        f"Port {port} is still serving CDP after cleanup{detail}. "
        f"Stop the other process manually or pass --port."
    )


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Experimental: Frida-spawn official Claude, keep CDP gate from exiting, "
            "inject online Chinese DOM translation. Does not modify app.asar on disk."
        )
    )
    parser.add_argument(
        "--app",
        type=Path,
        default=Path("/Applications/Claude.app"),
        help="Official Claude.app (not modified)",
    )
    parser.add_argument(
        "--lang",
        choices=["zh-CN", "zh-TW", "zh-HK"],
        default="zh-CN",
        help="Language for DOM translation resources",
    )
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help="CDP port")
    parser.add_argument(
        "--mode",
        choices=["exit-hook", "mem-patch", "both"],
        default="both",
        help="Frida gate strategy (default: both)",
    )
    parser.add_argument(
        "--no-inject",
        action="store_true",
        help="Only open CDP under Frida; do not inject translation",
    )
    parser.add_argument(
        "--no-quit",
        action="store_true",
        help="Do not quit an already-running Claude before launch",
    )
    parser.add_argument(
        "--watch-seconds",
        type=float,
        default=0.0,
        help="If >0, run inject watchdog for this many seconds then exit (CI-friendly)",
    )
    parser.add_argument(
        "--watch",
        action="store_true",
        help=(
            "Do not spawn immediately; watch for official Claude processes and "
            "handle them (see --watch-strategy). Ideal for LaunchAgent resident."
        ),
    )
    parser.add_argument(
        "--watch-strategy",
        choices=["relaunch"],
        default="relaunch",
        help=(
            "watch mode strategy (only relaunch): replace Dock-launched Claude "
            "with Frida spawn for full DOM + menu Chinese. Default: relaunch"
        ),
    )
    parser.add_argument(
        "--watch-interval",
        type=float,
        default=float(os.environ.get("CLAUDE_FRIDA_WATCH_INTERVAL") or 3.0),
        help=(
            "Seconds between process scans in --watch mode "
            "(default 3.0, or CLAUDE_FRIDA_WATCH_INTERVAL). "
            "Idle polls are cheap (stat + ps only)."
        ),
    )
    parser.add_argument(
        "--no-prepare-debug",
        action="store_true",
        help=(
            "Do not re-sign Claude.app for Frida. By default the launcher will "
            "ad-hoc re-sign in place (get-task-allow, no hardened runtime) when "
            "needed. Never copies the app; never writes app.asar."
        ),
    )
    parser.add_argument(
        "--no-install-locale",
        action="store_true",
        help=(
            "Do not install zh locale JSON / language whitelist into the official "
            "app. Default installs them in place (still no app.asar write / no copy) "
            "so onboarding and local UI can switch to Chinese; DOM inject alone is "
            "not enough when config locale stays en-US."
        ),
    )
    parser.add_argument(
        "--prepare-only",
        action="store_true",
        help=(
            "Only prepare Claude.app (locale resources + Frida debug re-sign), "
            "then exit (no spawn)"
        ),
    )
    parser.add_argument(
        "--user-home",
        type=Path,
        default=Path.home(),
        help="Home directory for Claude config.json locale write (default: ~)",
    )
    return parser.parse_args(argv)


def run_session_lifecycle(
    *,
    device: Any,
    session: frida.core.Session,
    script: frida.core.Script,
    pid: int,
    port: int | None,
    script_src: str,
    menu_map: dict[str, str],
    no_inject: bool,
    watch_seconds: float,
    kill_on_cleanup: bool,
    before: dict[str, Any],
    source_app: Path,
) -> int:
    """Shared post-attach/spawn: menu hooks, CDP inject, wait until exit."""

    def _cleanup() -> None:
        if kill_on_cleanup and pid:
            kill_frida_tree(device, pid)
        else:
            detach_only(session, script)
            log(f"Detached from pid={pid} (Claude left running)")
        after = asar_fingerprint(source_app)
        log(f"ASAR after:  {format_fp(after)}")
        unchanged = (
            after["sha256"] == before["sha256"]
            and after["size"] == before["size"]
            and after["mtime_ns"] == before["mtime_ns"]
        )
        log(f"ASAR_UNCHANGED={'yes' if unchanged else 'NO'}")

    cleaned = False

    def _cleanup_once() -> None:
        nonlocal cleaned
        if cleaned:
            return
        cleaned = True
        _cleanup()

    # Menu hooks after app is up
    if script is not None and menu_map:
        ok = install_native_menu_hooks(script, pid, attempts=24, interval=0.3)
        if ok:
            try:
                late = _call_menu_install(script)
                log(
                    "Late menu rewrite: "
                    f"rewritten={late.get('rewritten')} "
                    f"menuPatches={late.get('menuPatches')}"
                )
            except Exception as exc:
                log(f"Late menu rewrite failed: {exc}")

    cdp_port = port
    if cdp_port is None:
        cdp_port = discover_cdp_port(pid, DEFAULT_PORT)
        if cdp_port:
            log(f"Discovered CDP on port {cdp_port}")
        else:
            log(
                "No CDP port on this process — DOM inject skipped "
                "(native menu rewrite still attempted). "
                "Use --watch-strategy relaunch for full page Chinese."
            )

    try:
        if no_inject or not script_src or not cdp_port:
            if cdp_port:
                try:
                    version = wait_for_cdp_pid(cdp_port, pid)
                    log(f"CDP browser: {version.get('Browser')}")
                except Exception as exc:
                    log(f"CDP wait: {exc}")
            log("Watching process (no DOM inject). Ctrl+C detaches/stops.")
            proc = PidProc(pid)
            if watch_seconds > 0:
                deadline = time.monotonic() + watch_seconds
                while time.monotonic() < deadline and proc.poll() is None:
                    if menu_map and script is not None:
                        try:
                            _call_menu_install(script)
                        except Exception:
                            pass
                    time.sleep(0.5)
            else:
                while proc.poll() is None:
                    if menu_map and script is not None:
                        try:
                            _call_menu_install(script)
                        except Exception:
                            pass
                    time.sleep(1.0)
            if proc.poll() is not None:
                log(f"Claude exited (pid={pid})")
        else:
            version = wait_for_cdp_pid(cdp_port, pid)
            log(f"CDP browser: {version.get('Browser')}")
            log(f"CDP websocket: {version.get('webSocketDebuggerUrl')}")
            log("Starting CDP inject watchdog")
            proc = PidProc(pid)

            async def _watch() -> None:
                if watch_seconds and watch_seconds > 0:
                    seen: dict[str, tuple[float, str]] = {}
                    deadline = time.monotonic() + watch_seconds
                    while time.monotonic() < deadline and proc.poll() is None:
                        await cdp.inject_all_pages(cdp_port, script_src, seen)
                        if menu_map and script is not None:
                            try:
                                _call_menu_install(script)
                            except Exception:
                                pass
                        await asyncio.sleep(1.0)
                else:
                    # Periodic menu refresh alongside DOM watchdog
                    seen: dict[str, tuple[float, str]] = {}
                    while proc.poll() is None:
                        await cdp.inject_all_pages(cdp_port, script_src, seen)
                        if menu_map and script is not None:
                            try:
                                _call_menu_install(script)
                            except Exception:
                                pass
                        await asyncio.sleep(1.0)

            asyncio.run(_watch())
            if proc.poll() is not None:
                log(f"Claude exited (pid={pid})")
    finally:
        _cleanup_once()
    return 0


def run_watch_loop(
    *,
    binary: Path,
    source_app: Path,
    port: int,
    mode: str,
    replacements: list[dict[str, str]],
    menu_map: dict[str, str],
    script_src: str,
    interval: float,
    no_inject: bool,
    watch_seconds: float,
    before: dict[str, Any],
    lang_code: str = "zh-CN",
    user_home: Path | None = None,
    install_locale: bool = True,
    allow_resign: bool = True,
    fingerprint: dict[str, Any] | None = None,
) -> int:
    """Monitor official Claude launches and attach or relaunch under Frida.

    Survives Claude Desktop updates when possible:
    if app.asar / binary / signature changes, reinstall locale resources,
    re-sign for Frida, and rebuild gate replacements + DOM script before the
    next spawn. Unchanged fingerprints are a cheap no-op.
    """
    user_home = (user_home or Path.home()).expanduser().resolve()
    # Normalize interval: idle should be cheap; floor 1.0s to avoid busy loops.
    interval = max(1.0, float(interval or 3.0))
    state_fp = fingerprint or app_runtime_fingerprint(source_app, cheap=True)
    # locale_ready is expensive (JS scan); cache and recheck on a slow timer only.
    locale_ready_cache = locale_resources_ready(source_app, lang_code)
    state_fp["locale_ready"] = locale_ready_cache
    last_prepare_error_log = 0.0
    last_locale_check = 0.0
    last_locale_ready_check = 0.0
    last_frida_ready_check = 0.0
    frida_ready_cache = patch.app_frida_debug_ready(source_app)
    # Locale policy: write once at startup (via prepare); later only if we see
    # en-US / wrong locale — not a periodic force-write every N seconds.
    locale_check_interval = 60.0
    locale_ready_check_interval = 60.0
    frida_ready_check_interval = 60.0
    # Fingerprint (stat-only) can run every loop; full heal only when changed.

    log(
        f"Watch mode ON strategy=relaunch interval={interval}s "
        f"binary={binary}"
    )
    log("Click the official Claude.app / Dock icon; this agent will handle new PIDs.")
    log(
        "Auto-heal after Claude updates: re-install zh resources + Frida re-sign "
        "when app fingerprint changes; skip when unchanged."
    )
    log(
        f"User locale: write at prepare if needed; later only when config is not "
        f"{lang_code} (e.g. en-US), not periodic force-write."
    )
    log(
        "Idle poll is cheap (ps + stat only); no full asar hash / codesign each tick."
    )
    log("Ctrl+C stops the watcher (does not uninstall LaunchAgent).")

    # pids we currently own (attached or spawned)
    active: dict[int, dict[str, Any]] = {}
    # pids we failed to attach (don't spin)
    blacklist: dict[int, float] = {}
    stop = False

    def _handle_signal(signum: int, _frame: Any) -> None:
        nonlocal stop
        log(f"Received signal {signum}; stopping watcher")
        stop = True

    signal.signal(signal.SIGINT, _handle_signal)
    signal.signal(signal.SIGTERM, _handle_signal)

    deadline = (
        time.monotonic() + watch_seconds if watch_seconds and watch_seconds > 0 else None
    )

    def refresh_payload_if_needed(*, force: bool = False, reason: str = "change") -> bool:
        """Return True if payload was rebuilt. Updates outer replacements/script."""
        nonlocal replacements, menu_map, script_src, before, state_fp
        nonlocal last_prepare_error_log, locale_ready_cache, frida_ready_cache
        nonlocal last_locale_ready_check, last_frida_ready_check

        now = time.monotonic()
        # Cheap fingerprint every call (stat only).
        current = app_runtime_fingerprint(source_app, cheap=True)

        # Expensive checks on a slow timer (or when force/fingerprint changed).
        same = fingerprints_equal(state_fp, current)
        if force or not same or (now - last_locale_ready_check >= locale_ready_check_interval):
            last_locale_ready_check = now
            if install_locale:
                locale_ready_cache = locale_resources_ready(source_app, lang_code)
        if force or not same or (now - last_frida_ready_check >= frida_ready_check_interval):
            last_frida_ready_check = now
            frida_ready_cache = patch.app_frida_debug_ready(source_app)

        current["locale_ready"] = locale_ready_cache
        locale_ok = bool(locale_ready_cache)
        frida_ready = bool(frida_ready_cache)
        need = force or (not same) or (not frida_ready) or (install_locale and not locale_ok)
        if not need:
            return False
        if not same:
            log(
                f"Claude.app fingerprint changed ({reason}); "
                f"asar_size={current.get('asar', {}).get('size')} "
                f"mtime={current.get('asar', {}).get('mtime_ns')} "
                "re-preparing locale + Frida signature + runtime patches"
            )
        elif not frida_ready:
            log("Claude.app no longer Frida-ready (signature restored?); re-preparing")
        elif not locale_ok:
            log("Locale resources missing after app change; re-installing")
        try:
            # Force locale reinstall when asar/binary stats changed so
            # whitelist/json match the new build.
            force_locale = (not same) and (
                ((state_fp or {}).get("asar") or {}).get("size")
                != ((current.get("asar") or {}).get("size"))
                or ((state_fp or {}).get("asar") or {}).get("mtime_ns")
                != ((current.get("asar") or {}).get("mtime_ns"))
                or ((state_fp or {}).get("binary") or {}) != (current.get("binary") or {})
            )
            payload = prepare_runtime_payload(
                source_app,
                lang_code,
                user_home=user_home,
                install_locale=install_locale,
                allow_resign=allow_resign,
                no_inject=no_inject,
                force_locale=force_locale,
                reason=reason,
            )
            replacements = payload["replacements"]
            menu_map = payload["menu_map"]
            script_src = payload["script_src"]
            before = payload["before"]
            state_fp = payload["fingerprint"]
            locale_ready_cache = bool(state_fp.get("locale_ready"))
            frida_ready_cache = patch.app_frida_debug_ready(source_app)
            log("Runtime payload refreshed for current Claude.app")
            return True
        except SystemExit as exc:
            now2 = time.monotonic()
            if now2 - last_prepare_error_log > 20:
                log(f"Auto-prepare after app change failed: {exc}")
                last_prepare_error_log = now2
            return False
        except Exception as exc:
            now2 = time.monotonic()
            if now2 - last_prepare_error_log > 20:
                log(f"Auto-prepare error: {type(exc).__name__}: {exc}")
                last_prepare_error_log = now2
            return False

    while not stop:
        if deadline is not None and time.monotonic() >= deadline:
            log("--watch-seconds elapsed; exiting watch loop")
            break

        # Detect Claude Desktop updates / reinstalls even when idle (cheap).
        refresh_payload_if_needed(reason="watch-poll")

        # Locale: do NOT rewrite every tick. Only when we observe wrong/missing
        # locale (typically Claude rewrote config back to en-US).
        now = time.monotonic()
        if install_locale and now - last_locale_check >= locale_check_interval:
            last_locale_check = now
            try:
                ensure_user_locale_if_wrong(
                    user_home, lang_code, reason="watch-detected-wrong-locale"
                )
            except Exception:
                pass

        # Drop dead sessions
        for pid in list(active.keys()):
            if not process_alive(pid):
                info = active.pop(pid)
                log(f"Tracked pid={pid} exited; cleaning session")
                detach_only(info.get("session"), info.get("script"))

        live = find_claude_pids(binary)
        for pid in live:
            if pid in active:
                # Refresh menus periodically on owned sessions
                sc = active[pid].get("script")
                if sc is not None and menu_map:
                    try:
                        _call_menu_install(sc)
                    except Exception:
                        pass
                continue
            if pid in blacklist and time.monotonic() < blacklist[pid]:
                continue

            # New official process: prepare for current app bytes first.
            refresh_payload_if_needed(reason="before-relaunch")

            cmd = process_cmdline(pid)
            ours = cmdline_has_cdp(pid, port)

            if ours and cdp.port_listening(port):
                # Likely already a Frida-spawned instance (or manual CDP).
                log(f"pid={pid} already has CDP :{port}; trying attach")
                try:
                    device, session, script, apid = attach_to_pid(
                        pid, mode, replacements, menu_map
                    )
                    active[apid] = {
                        "device": device,
                        "session": session,
                        "script": script,
                        "kind": "attach",
                        "cdp_port": port,
                        "seen_pages": {},
                    }
                    if menu_map:
                        install_native_menu_hooks(
                            script, apid, attempts=16, interval=0.25
                        )
                except Exception as exc:
                    log(f"Attach to CDP instance failed: {exc}")
                    # Signature/gate may have changed under our feet.
                    if "Permission" in type(exc).__name__ or "Permission" in str(exc):
                        refresh_payload_if_needed(force=True, reason="attach-permission")
                    blacklist[pid] = time.monotonic() + 15.0
                continue

            log(
                f"pid={pid} is official launch (no our CDP). "
                f"strategy=relaunch → replace with Frida spawn"
            )
            log(f"  cmdline: {cmd[:160]}")
            kill_pid(pid)
            # Wait until it dies so we don't double-instance
            t0 = time.monotonic()
            while process_alive(pid) and time.monotonic() - t0 < 5.0:
                time.sleep(0.1)
            try:
                ensure_cdp_port_free(port, soft_quit=False, wait_seconds=3.0)
            except SystemExit as exc:
                log(f"Port cleanup: {exc}")
                continue
            try:
                device, session, script, spid = spawn_with_frida(
                    binary, port, mode, replacements, menu_map
                )
            except SystemExit as exc:
                log(f"Respawn failed: {exc}")
                # Common after updates: Developer ID restored, Frida blocked.
                refresh_payload_if_needed(force=True, reason="respawn-failed")
                time.sleep(2.0)
                continue
            active[spid] = {
                "device": device,
                "session": session,
                "script": script,
                "kind": "spawn",
                "cdp_port": port,
                "seen_pages": {},
            }
            if menu_map:
                install_native_menu_hooks(script, spid, attempts=20, interval=0.3)
            log(f"Replaced with Frida-spawned pid={spid} (full DOM path)")

        # DOM inject for any active sessions that have CDP
        if script_src and not no_inject:
            for pid, info in list(active.items()):
                cdp_port = info.get("cdp_port")
                if not cdp_port or not process_alive(pid):
                    continue
                if not cdp.port_listening(int(cdp_port)):
                    continue
                seen = info.setdefault("seen_pages", {})
                try:
                    asyncio.run(cdp.inject_all_pages(int(cdp_port), script_src, seen))
                except Exception as exc:
                    # Avoid spamming; log occasionally
                    now = time.monotonic()
                    if now - info.get("last_inject_err", 0) > 10:
                        log(f"inject pid={pid}: {exc}")
                        info["last_inject_err"] = now

        time.sleep(max(0.2, float(interval)))

    # Watcher stopping: detach all; only kill processes we spawned
    for pid, info in list(active.items()):
        if info.get("kind") == "spawn":
            kill_frida_tree(info.get("device"), pid)
        else:
            detach_only(info.get("session"), info.get("script"))
    active.clear()

    after = asar_fingerprint(source_app)
    log(f"ASAR after:  {format_fp(after)}")
    unchanged = (
        after["sha256"] == before["sha256"]
        and after["size"] == before["size"]
        and after["mtime_ns"] == before["mtime_ns"]
    )
    log(f"ASAR_UNCHANGED={'yes' if unchanged else 'NO'}")
    return 0


def main(argv: list[str] | None = None) -> int:
    if sys.platform != "darwin":
        log("Warning: this experimental launcher is implemented/tested for macOS only.")

    # Drop stale Frida helper/agent extracts early (keep newest only).
    try:
        prune_frida_cache(keep=1, reason="startup")
    except Exception as exc:
        log(f"Frida cache prune at startup skipped: {exc}")

    args = parse_args(argv)
    source_app = args.app.expanduser().resolve()
    port = int(args.port)
    binary = source_app / "Contents/MacOS/Claude"
    watch_mode = bool(getattr(args, "watch", False)) or (
        os.environ.get("CLAUDE_FRIDA_RESIDENT", "").strip() == "1"
        and os.environ.get("CLAUDE_FRIDA_WATCH", "1").strip() not in ("0", "n", "N", "false")
    )
    # Resident defaults to watch+relaunch so Dock clicks get Chinese.
    if os.environ.get("CLAUDE_FRIDA_RESIDENT", "").strip() == "1" and not getattr(
        args, "watch", False
    ):
        # Only auto-enable when launched via resident wrapper without explicit flags.
        if "--watch" not in (argv or sys.argv[1:]):
            watch_mode = True

    if not source_app.exists():
        raise SystemExit(f"Claude.app not found: {source_app}")
    patch.require_file(binary)

    # Default: auto re-sign official app for Frida when needed (SIP still on).
    # CLAUDE_FRIDA_PREPARE_DEBUG=0 disables; --no-prepare-debug disables.
    allow_resign = not bool(args.no_prepare_debug)
    env_prepare = os.environ.get("CLAUDE_FRIDA_PREPARE_DEBUG", "").strip().lower()
    if env_prepare in {"0", "n", "no", "false"}:
        allow_resign = False
    elif env_prepare in {"1", "y", "yes", "true"}:
        allow_resign = True
    if args.prepare_only:
        allow_resign = True

    install_locale = not bool(args.no_install_locale)
    env_locale = os.environ.get("CLAUDE_FRIDA_INSTALL_LOCALE", "").strip().lower()
    if env_locale in {"0", "n", "no", "false"}:
        install_locale = False
    elif env_locale in {"1", "y", "yes", "true"}:
        install_locale = True

    lang_cfg = patch.get_language_config(args.lang)
    patch.require_file(lang_cfg["frontend_translation"])
    patch.require_file(lang_cfg["frontend_hardcoded"])

    user_home = args.user_home.expanduser().resolve()
    payload = prepare_runtime_payload(
        source_app,
        args.lang,
        user_home=user_home,
        install_locale=install_locale,
        allow_resign=allow_resign,
        no_inject=bool(args.no_inject),
        force_locale=False,
        reason="startup",
    )
    if args.prepare_only:
        log(
            "Prepare-only done (locale resources + Frida debug signature). "
            "Launch again without --prepare-only."
        )
        return 0

    before = payload["before"]
    replacements = payload["replacements"]
    menu_map = payload["menu_map"]
    script_src = payload["script_src"]
    log(f"ASAR before: {format_fp(before)}")

    # -------- Watch / attach resident path --------
    if watch_mode:
        interval = float(getattr(args, "watch_interval", 1.0) or 1.0)
        log(
            "Mode=watch strategy=relaunch "
            "(Dock/official Claude will be replaced with Frida spawn)"
        )
        if not args.no_quit:
            # Soft clear only our CDP port leftovers; leave a running official
            # Claude for the loop to detect and replace (better UX: user clicks
            # Dock, we swap). If nothing is running, just ensure port free.
            if cdp.port_listening(port):
                log(f"Clearing leftover CDP on :{port} before watch")
                try:
                    ensure_cdp_port_free(port, soft_quit=False, wait_seconds=2.0)
                except SystemExit as exc:
                    log(f"Port cleanup note: {exc}")
        return run_watch_loop(
            binary=binary,
            source_app=source_app,
            port=port,
            mode=args.mode,
            replacements=replacements,
            menu_map=menu_map,
            script_src=script_src,
            interval=interval,
            no_inject=bool(args.no_inject),
            watch_seconds=float(args.watch_seconds or 0),
            before=before,
            lang_code=args.lang,
            user_home=user_home,
            install_locale=install_locale,
            allow_resign=allow_resign,
            fingerprint=payload.get("fingerprint"),
        )

    # -------- One-shot spawn path (original) --------
    if not args.no_quit:
        log("Quitting existing Claude instances (if any)")
        ensure_cdp_port_free(port, soft_quit=True)
    elif cdp.port_listening(port):
        raise SystemExit(
            f"Port {port} is already serving CDP. Stop the other process, "
            f"omit --no-quit, or pass --port."
        )

    if not args.no_quit:
        ensure_cdp_port_free(port, soft_quit=False, wait_seconds=2.0)

    session: frida.core.Session | None = None
    script: frida.core.Script | None = None
    device: Any | None = None
    pid = 0
    exit_code = 0

    def _cleanup() -> None:
        nonlocal session, script, device
        if pid:
            kill_frida_tree(device, pid)
        script = None
        session = None
        device = None
        after = asar_fingerprint(source_app)
        log(f"ASAR after:  {format_fp(after)}")
        unchanged = (
            after["sha256"] == before["sha256"]
            and after["size"] == before["size"]
            and after["mtime_ns"] == before["mtime_ns"]
        )
        log(f"ASAR_UNCHANGED={'yes' if unchanged else 'NO'}")
        if not unchanged:
            log("WARNING: asar fingerprint changed; investigate unexpected writers.")

    cleaned = False

    def _cleanup_once() -> None:
        nonlocal cleaned
        if cleaned:
            return
        cleaned = True
        _cleanup()

    def _handle_signal(signum: int, _frame: Any) -> None:
        log(f"Received signal {signum}")
        _cleanup_once()
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGINT, _handle_signal)
    signal.signal(signal.SIGTERM, _handle_signal)

    try:
        device, session, script, pid = spawn_with_frida(
            binary, port, args.mode, replacements, menu_map
        )
        version = wait_for_cdp_pid(port, pid)
        log(f"CDP browser: {version.get('Browser')}")
        log(f"CDP websocket: {version.get('webSocketDebuggerUrl')}")

        if script is not None and menu_map:
            ok = install_native_menu_hooks(script, pid, attempts=24, interval=0.3)
            if ok:
                try:
                    late = _call_menu_install(script)
                    log(
                        "Late menu rewrite: "
                        f"rewritten={late.get('rewritten')} "
                        f"menuPatches={late.get('menuPatches')}"
                    )
                except Exception as exc:
                    log(f"Late menu rewrite failed: {exc}")

        if args.no_inject:
            log("Launch complete (--no-inject). CDP is up; press Ctrl+C to stop.")
            proc = PidProc(pid)
            if args.watch_seconds > 0:
                deadline = time.monotonic() + args.watch_seconds
                while time.monotonic() < deadline and proc.poll() is None:
                    time.sleep(0.5)
            else:
                while proc.poll() is None:
                    time.sleep(1.0)
        else:
            log("Starting CDP inject watchdog")
            proc = PidProc(pid)

            async def _watch() -> None:
                if args.watch_seconds and args.watch_seconds > 0:
                    seen: dict[str, tuple[float, str]] = {}
                    deadline = time.monotonic() + args.watch_seconds
                    while time.monotonic() < deadline and proc.poll() is None:
                        await cdp.inject_all_pages(port, script_src, seen)
                        await asyncio.sleep(1.0)
                else:
                    await cdp.run_watchdog(port, script_src, proc)  # type: ignore[arg-type]

            asyncio.run(_watch())
            if proc.poll() is not None:
                log(f"Claude exited (pid={pid})")
    except SystemExit:
        _cleanup_once()
        raise
    except Exception as exc:
        log(f"Fatal error: {type(exc).__name__}: {exc}")
        exit_code = 1
    finally:
        _cleanup_once()

    return int(exit_code or 0)


if __name__ == "__main__":
    raise SystemExit(main())
