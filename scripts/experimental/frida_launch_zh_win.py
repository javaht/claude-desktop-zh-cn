#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Experimental: Frida Chinese for official Claude Desktop on Windows (no disk writes).

- Spawns Claude.exe with --remote-debugging-port under Frida
- Equal-length in-memory patches for CDP gate inside app.asar
- Syncs asar file/block/header hashes and the SHA256 embedded in Claude.exe
- Injects online DOM Chinese via CDP (reuses cdp_launch_zh helpers)

Does NOT modify app.asar or Claude.exe on disk.
"""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import importlib.util
import json
import os
import re
import signal
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

EXPERIMENTAL_DIR = Path(__file__).resolve().parent
SCRIPTS_DIR = EXPERIMENTAL_DIR.parent
ROOT = SCRIPTS_DIR.parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))
if str(EXPERIMENTAL_DIR) not in sys.path:
    sys.path.insert(0, str(EXPERIMENTAL_DIR))

# patch_claude_zh_cn is mac-oriented for paths; we only reuse asar/DOM helpers.
import patch_claude_zh_cn as patch  # noqa: E402

try:
    import frida
except ImportError as exc:  # pragma: no cover
    raise SystemExit(
        "Missing dependency 'frida'. Run bootstrap_frida_runtime_win.ps1 first, "
        "or: python -m pip install frida frida-tools websockets"
    ) from exc

try:
    import websockets  # noqa: F401
except ImportError as exc:  # pragma: no cover
    raise SystemExit(
        "Missing dependency 'websockets'. Install with: python -m pip install websockets"
    ) from exc

_cdp_spec = importlib.util.spec_from_file_location(
    "cdp_launch_zh",
    EXPERIMENTAL_DIR / "cdp_launch_zh.py",
)
if _cdp_spec is None or _cdp_spec.loader is None:
    raise SystemExit("Cannot load cdp_launch_zh.py for inject helpers")
cdp = importlib.util.module_from_spec(_cdp_spec)
_cdp_spec.loader.exec_module(cdp)

DEFAULT_PORT = 19351
CDP_WAIT_SECONDS = 45.0
FRIDA_AGENT = EXPERIMENTAL_DIR / "frida_cdp_gate_win.js"
EXE_INTEGRITY_MARKER = 'app.asar","alg":"SHA256","value":"'
PATCHED_ASAR_CACHE_VERSION = 2

GATE_SUFFIX = b"(process.argv)&&!yR()&&process.exit(1)"
GATE_SUFFIX_PATCHED = b"(process.argv)&&false&&process.exit(1)"


def log(message: str) -> None:
    print(message, flush=True)


def file_fingerprint(path: Path) -> dict[str, Any]:
    data = path.read_bytes()
    st = path.stat()
    return {
        "path": str(path.resolve()),
        "sha256": hashlib.sha256(data).hexdigest(),
        "size": st.st_size,
        "mtime_ns": getattr(st, "st_mtime_ns", int(st.st_mtime * 1_000_000_000)),
    }


def format_fp(fp: dict[str, Any]) -> str:
    return f"sha256={fp['sha256'][:16]}… size={fp['size']} mtime_ns={fp['mtime_ns']}"


def find_gate_bytes(content: bytes) -> tuple[bytes, bytes] | None:
    idx = content.find(GATE_SUFFIX)
    if idx < 0:
        if content.find(GATE_SUFFIX_PATCHED) >= 0:
            return None
        return None
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
    if start == idx:
        return None
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
        raise SystemExit(
            f"Expected exactly one CDP gate occurrence, found {content.count(gate_old)}"
        )
    return gate_old, gate_new


def read_asar(asar_path: Path) -> tuple[bytes, int, str, dict[str, Any]]:
    data = asar_path.read_bytes()
    header_size, header_string, header = patch.read_asar_header(data, asar_path)
    return data, header_size, header_string, header


def replace_asar_file_content_in_file(asar_path: Path, file_path: str, patched_content: bytes) -> bool:
    data = bytearray(asar_path.read_bytes())
    header_size, _header_string, header = patch.read_asar_header(data, asar_path)
    entry = patch.get_asar_file_entry(header, file_path)
    content_offset = 8 + header_size + int(entry["offset"])
    content_size = int(entry["size"])
    content_end = content_offset + content_size
    if content_offset < 0 or content_end > len(data):
        raise SystemExit(f"Unsupported app.asar file bounds for {file_path}.")

    old_content = bytes(data[content_offset:content_end])
    if old_content == patched_content:
        return False

    target_offset = int(entry["offset"])
    delta = len(patched_content) - content_size
    data[content_offset:content_end] = patched_content
    entry["size"] = len(patched_content)
    entry["integrity"] = patch.calculate_file_integrity(patched_content)
    if delta:
        for other in patch.iter_asar_file_entries(header):
            if other is not entry and int(other["offset"]) > target_offset:
                patch.set_asar_offset(other, int(other["offset"]) + delta)

    updated_header_string = json.dumps(header, ensure_ascii=False, separators=(",", ":"))
    updated_header = patch.encode_asar_header_dynamic(updated_header_string)
    body = bytes(data[8 + header_size :])
    asar_path.write_bytes(updated_header + body)
    return True


def patch_main_process_menu_in_asar_file(asar_path: Path, lang: str) -> tuple[int, int, int, int]:
    data, header_size, _header_string, header = read_asar(asar_path)
    asar_target = patch.find_main_process_asar_target(data, header_size, header)
    entry = patch.get_asar_file_entry(header, asar_target)
    content_offset = 8 + header_size + int(entry["offset"])
    content_size = int(entry["size"])
    content_end = content_offset + content_size
    if content_offset < 0 or content_end > len(data):
        raise SystemExit(f"Unsupported app.asar file bounds for {asar_target}.")

    text = bytes(data[content_offset:content_end]).decode("utf-8")
    patched = text
    count = 0
    intl_count = 0
    runtime_count = 0
    repair_count = 0

    patched, removed_runtime_patch = patch.strip_menu_runtime_patch(patched)
    unsafe_repairs = {
        "文件": "File",
        "檔案": "File",
        "编辑": "Edit",
        "編輯": "Edit",
        "查看": "View",
        "檢視": "View",
        "帮助": "Help",
        "說明": "Help",
        "开发者": "Developer",
        "開發者": "Developer",
        "扩展": "Extensions",
        "擴充功能": "Extensions",
    }
    for source, target in unsafe_repairs.items():
        pattern = re.compile(r'(?P<quote>["\'`])' + re.escape(source) + r"(?P=quote)")
        patched, occurrences = pattern.subn(
            lambda match, replacement=target: f"{match.group('quote')}{replacement}{match.group('quote')}",
            patched,
        )
        repair_count += occurrences

    for message_id, target in patch.get_main_process_menu_intl_replacements(lang).items():
        patched, occurrences = patch.replace_menu_intl_message_by_id(patched, message_id, target)
        intl_count += occurrences

    replacements = patch.get_main_process_menu_replacements(lang)
    for source, target in sorted(replacements.items(), key=lambda item: len(item[0]), reverse=True):
        if source not in patched:
            continue
        pattern = re.compile(
            r"(?P<prefix>(?<![A-Za-z0-9_$])(?:label|defaultMessage)\s*:\s*)"
            r'(?P<quote>["\'`])'
            + re.escape(source)
            + r"(?P=quote)"
        )

        def replace_match(match: re.Match[str], replacement: str = target) -> str:
            quote = match.group("quote")
            return f"{match.group('prefix')}{quote}{replacement}{quote}"

        patched, occurrences = pattern.subn(replace_match, patched)
        count += occurrences

    if patch.MENU_RUNTIME_MARKER not in patched:
        patched = patch.build_menu_runtime_patch(lang) + patched
        runtime_count = 1
    elif removed_runtime_patch:
        runtime_count = 1

    if count == 0 and intl_count == 0 and runtime_count == 0 and repair_count == 0:
        return count, intl_count, runtime_count, repair_count
    if intl_count == 0 and count == 0 and runtime_count == 0:
        raise SystemExit("Could not patch main-process menu labels in runtime asar copy.")

    replace_asar_file_content_in_file(asar_path, asar_target, patched.encode("utf-8"))
    return count, intl_count, runtime_count, repair_count


def prepare_patched_asar_cache(source_asar: Path, lang: str, source_fp: dict[str, Any]) -> Path:
    local_app = os.environ.get("LOCALAPPDATA")
    if local_app:
        cache_root = Path(local_app) / "claude-zh" / "runtime" / "patched-asar"
    else:
        cache_root = ROOT / "runtime" / "patched-asar"
    cache_asar = cache_root / "app.asar"
    meta_path = cache_root / "patched-asar-meta.json"
    expected_meta = {
        "version": PATCHED_ASAR_CACHE_VERSION,
        "source": str(source_asar.resolve()),
        "source_sha256": source_fp["sha256"],
        "source_size": source_fp["size"],
        "lang": lang,
    }

    try:
        if cache_asar.is_file() and meta_path.is_file():
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
            if all(meta.get(k) == v for k, v in expected_meta.items()):
                log(f"Runtime patched app.asar cache hit: {cache_asar}")
                return cache_asar
    except Exception:
        pass

    log("Building runtime patched app.asar cache for main-process menu localization")
    if cache_root.exists():
        shutil.rmtree(cache_root)
    cache_root.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source_asar, cache_asar)
    count, intl_count, runtime_count, repair_count = patch_main_process_menu_in_asar_file(cache_asar, lang)
    patched_fp = file_fingerprint(cache_asar)
    meta = {
        **expected_meta,
        "patched_sha256": patched_fp["sha256"],
        "patched_size": patched_fp["size"],
        "menu_literal_replacements": count,
        "menu_intl_replacements": intl_count,
        "menu_runtime_patch": runtime_count,
        "menu_repairs": repair_count,
        "created_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    }
    meta_path.write_text(json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8")
    log(
        "Runtime patched app.asar ready: "
        f"literal={count} intl={intl_count} runtime={runtime_count} repairs={repair_count}"
    )
    return cache_asar


def build_runtime_replacements(asar_path: Path, exe_path: Path) -> list[dict[str, str]]:
    """
    Equal-length search/replace pairs so Frida can patch app.asar + Claude.exe
    *in memory* while Electron loads them. Disk files stay stock.
    """
    patch.require_file(asar_path)
    patch.require_file(exe_path)
    data, header_size, header_string, header = read_asar(asar_path)

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
    if len(old_header_hash) != len(new_header_hash):
        raise SystemExit("Header hash length mismatch")

    # Confirm Claude.exe embeds the current header hash (or at least a 64-hex slot).
    exe_bytes = exe_path.read_bytes()
    marker = EXE_INTEGRITY_MARKER.encode("ascii")
    midx = exe_bytes.find(marker)
    if midx < 0:
        raise SystemExit(
            "Could not find Claude.exe app.asar integrity marker "
            f"({EXE_INTEGRITY_MARKER!r}). Bundle format may have changed."
        )
    if exe_bytes.find(marker, midx + 1) >= 0:
        raise SystemExit("Claude.exe integrity marker is not unique")
    hash_off = midx + len(marker)
    embedded = exe_bytes[hash_off : hash_off + 64]
    try:
        embedded_s = embedded.decode("ascii")
    except UnicodeDecodeError as exc:
        raise SystemExit("Claude.exe integrity value is not ASCII hex") from exc
    if not re.fullmatch(r"[0-9a-fA-F]{64}", embedded_s):
        raise SystemExit(f"Claude.exe integrity value is not SHA256 hex: {embedded_s!r}")
    if embedded_s.lower() != old_header_hash.lower():
        log(
            "WARNING: Claude.exe embedded hash does not match current asar header hash.\n"
            f"  exe:  {embedded_s}\n"
            f"  asar: {old_header_hash}\n"
            "  Will still patch exe slot old->new using the asar-derived hashes."
        )

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

    # Prefer patching the exact embedded exe value if it matches old header hash;
    # always include asar-derived header hash pair for exe memory views.
    replacements.append(
        {
            "old": old_header_hash,
            "new": new_header_hash,
            "label": "header-hash-exe",
        }
    )
    if embedded_s != old_header_hash and embedded_s != new_header_hash:
        if len(embedded_s) == len(new_header_hash):
            replacements.append(
                {
                    "old": embedded_s,
                    "new": new_header_hash
                    if embedded_s.islower()
                    else (
                        new_header_hash.upper()
                        if embedded_s.isupper()
                        else new_header_hash
                    ),
                    "label": "header-hash-exe-embedded",
                }
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


def resolve_claude_install(
    app_dir: Path | None = None,
) -> tuple[Path, Path, Path, str]:
    """
    Return (app_dir, exe_path, asar_path, install_kind).
    Mirrors install_windows.ps1 discovery: unpackaged first, then AppX.
    """
    if app_dir is not None:
        app_dir = app_dir.expanduser().resolve()
        exe = _find_exe(app_dir)
        asar = _find_asar(app_dir)
        return app_dir, exe, asar, "manual"

    local = os.environ.get("LOCALAPPDATA") or str(
        Path.home() / "AppData" / "Local"
    )
    unpackaged_base = Path(local) / "AnthropicClaude"
    if unpackaged_base.is_dir():
        apps = []
        for child in unpackaged_base.iterdir():
            if not child.is_dir() or not child.name.startswith("app-"):
                continue
            exe = child / "Claude.exe"
            if not exe.is_file():
                exe = child / "claude.exe"
            resources = child / "resources"
            if exe.is_file() and resources.is_dir():
                apps.append(child)
        apps.sort(key=lambda p: p.stat().st_mtime, reverse=True)
        if apps:
            app = apps[0]
            return app, _find_exe(app), _find_asar(app), "Unpackaged"

    # AppX via Get-AppxPackage
    try:
        proc = subprocess.run(
            [
                "powershell.exe",
                "-NoProfile",
                "-Command",
                "(Get-AppxPackage -Name Claude | Select-Object -First 1).InstallLocation",
            ],
            check=False,
            capture_output=True,
            text=True,
            timeout=30,
        )
        loc = (proc.stdout or "").strip().strip('"')
        if loc and Path(loc).is_dir():
            app = Path(loc)
            # AppX layout: <pkg>/app/claude.exe + <pkg>/app/resources/app.asar
            if (app / "app").is_dir():
                app = app / "app"
            return app, _find_exe(app), _find_asar(app), "AppX"
    except Exception as exc:
        log(f"AppX discovery note: {exc}")

    raise SystemExit(
        "未找到 Claude Desktop。请安装官方客户端，或用 --app 指定含 Claude.exe 的目录。"
    )


def _find_exe(app_dir: Path) -> Path:
    for name in ("Claude.exe", "claude.exe"):
        p = app_dir / name
        if p.is_file():
            return p
        p2 = app_dir / "app" / name
        if p2.is_file():
            return p2
    raise SystemExit(f"未找到 Claude.exe: {app_dir}")


def _find_asar(app_dir: Path) -> Path:
    candidates = [
        app_dir / "resources" / "app.asar",
        app_dir / "app" / "resources" / "app.asar",
        app_dir / "Contents" / "Resources" / "app.asar",  # unlikely on win
    ]
    for p in candidates:
        if p.is_file():
            return p
    raise SystemExit(f"未找到 app.asar under {app_dir}")


def build_win_inject_script(asar_path: Path, lang: str) -> str:
    """
    Like cdp.build_inject_script, but Windows resources live next to app.asar
    (resources/ion-dist/i18n) instead of Contents/Resources.
    """
    resources_dir = asar_path.parent
    # Temporarily point patch helpers at Windows layout via a fake app root:
    # patch expects app/Contents/Resources/... — build map manually.
    en_path = resources_dir / "ion-dist" / "i18n" / "en-US.json"
    if not en_path.is_file():
        raise SystemExit(f"缺少 en-US.json: {en_path}")

    lang_cfg = patch.get_language_config(lang)
    patch.require_file(lang_cfg["frontend_translation"])
    patch.require_file(lang_cfg["frontend_hardcoded"])

    en = patch.load_json(en_path)
    zh = patch.load_json(lang_cfg["frontend_translation"])
    if not isinstance(en, dict) or not isinstance(zh, dict):
        raise SystemExit("Unsupported frontend i18n JSON shape for online DOM translation.")

    mapping: dict[str, str] = {}
    for key, source in en.items():
        target = zh.get(key)
        if (
            isinstance(source, str)
            and isinstance(target, str)
            and patch.is_online_dom_translation_entry(source, target)
        ):
            mapping[source] = target
    for source, target in patch.load_frontend_hardcoded_replacements(lang):
        if patch.is_online_dom_translation_entry(source, target):
            mapping[source] = target
    # The Windows app/menu flyouts are rendered outside the regular online
    # message catalog in some builds. Reuse the main-process menu table for DOM
    # overlays too, so File/Edit/Developer and their submenus are covered.
    for source, target in patch.get_main_process_menu_replacements(lang).items():
        if isinstance(source, str) and isinstance(target, str) and source and target:
            mapping[source] = target
    mapping = dict(sorted(mapping.items()))
    if not mapping:
        raise SystemExit("Online translation map is empty; check en-US.json and resources/")
    log(f"Built online translation map: {len(mapping)} entries")
    dom_iife = patch.build_online_dom_translation_script(lang, mapping)
    menu_mapping = patch.get_main_process_menu_replacements(lang)
    menu_json = json.dumps(menu_mapping, ensure_ascii=False, separators=(",", ":"))
    menu_iife = (
        r"""(()=>{try{
const M=__MENU_JSON__;
const X=new Set(["SCRIPT","STYLE","NOSCRIPT"]);
const C="pre,code,kbd,samp,var,[data-language],[data-testid*=code],.cm-editor,.monaco-editor,.hljs";
const N=s=>String(s||"").replace(/\u2026/g,"...").replace(/\s+/g," ").trim();
const Q=s=>String(s||"").replace(/\.\.\.$/,"…");
const R=s=>M[s]||M[N(s)]||M[Q(s)]||M[Q(N(s))];
function text(n){
  const raw=n.nodeValue||"",core=raw.trim(),t=R(core);
  if(!t||N(raw)===N(t))return;
  const a=(raw.match(/^\s*/)||[""])[0],b=(raw.match(/\s*$/)||[""])[0];
  n.nodeValue=a+t+b;
}
function attrs(e){
  if(!e||e.nodeType!==1)return;
  try{if(X.has(e.tagName)||e.closest(C))return}catch{}
  for(const a of ["aria-label","title","placeholder","value"]){
    try{
      if(a==="value"&&!(e.matches&&e.matches("input[type=button],input[type=submit],button")))continue;
      let v=e.getAttribute?e.getAttribute(a):void 0;
      if(v==null&&a in e)v=e[a];
      const t=R(v);
      if(t){if(e.setAttribute)e.setAttribute(a,t);try{if(a in e)e[a]=t}catch{}}
    }catch{}
  }
}
function walk(root){
  if(!root)return;
  try{
    const w=document.createTreeWalker(root,NodeFilter.SHOW_TEXT|NodeFilter.SHOW_ELEMENT);
    let n;while(n=w.nextNode()){
      if(n.nodeType===3)text(n);
      else{attrs(n);if(n.shadowRoot)walk(n.shadowRoot)}
    }
  }catch{}
}
function run(){walk(document.documentElement||document.body||document)}
run();
new MutationObserver(()=>{clearTimeout(window.__claudeZhMenuTimer);window.__claudeZhMenuTimer=setTimeout(run,20)})
  .observe(document.documentElement||document,{subtree:true,childList:true,characterData:true,attributes:true});
let i=0,id=setInterval(()=>{run();if(++i>120)clearInterval(id)},250);
}catch(e){}})();"""
    ).replace("__MENU_JSON__", menu_json)
    marker = f'{getattr(cdp, "INJECT_MARKER", "v1")}-win-menu-v4'
    return (
        "(()=>{"
        f'if(window.__claudeZhCdpInjected==="{marker}")'
        "return{ok:true,skipped:true,href:String(location.href||''),title:String(document.title||'')};"
        f'window.__claudeZhCdpInjected="{marker}";'
        f"try{{{dom_iife};{menu_iife}}}"
        "catch(e){return{ok:false,error:String(e),href:String(location.href||'')}};"
        "return{ok:true,skipped:false,href:String(location.href||''),title:String(document.title||'')}"
        "})()"
    )


def process_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        # Windows: use tasklist / OpenProcess via subprocess fallback
        if os.name == "nt":
            proc = subprocess.run(
                ["tasklist", "/FI", f"PID eq {pid}", "/NH"],
                check=False,
                capture_output=True,
                text=True,
                timeout=5,
            )
            out = (proc.stdout or "").strip()
            return str(pid) in out and "No tasks" not in out and "没有" not in out
        os.kill(pid, 0)
        return True
    except Exception:
        return False


def kill_pid(pid: int) -> None:
    if pid <= 0:
        return
    log(f"Stopping pid={pid}")
    if os.name == "nt":
        subprocess.run(
            ["taskkill", "/PID", str(pid), "/T", "/F"],
            check=False,
            capture_output=True,
            text=True,
        )
        return
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        return


def stop_claude_processes() -> None:
    if os.name != "nt":
        return
    for image in ("Claude.exe", "claude.exe"):
        subprocess.run(
            ["taskkill", "/IM", image, "/T", "/F"],
            check=False,
            capture_output=True,
            text=True,
        )


def port_listening(port: int) -> bool:
    return cdp.port_listening(port)


def ensure_cdp_port_free(port: int, wait_seconds: float = 5.0) -> None:
    if not port_listening(port):
        return
    log(f"CDP port {port} busy; stopping Claude and waiting")
    stop_claude_processes()
    deadline = time.monotonic() + wait_seconds
    while time.monotonic() < deadline:
        if not port_listening(port):
            log(f"CDP port {port} is free")
            return
        time.sleep(0.2)
    raise SystemExit(
        f"Port {port} is still serving CDP. Stop the other process or pass --port."
    )


def wait_for_cdp_pid(port: int, pid: int, timeout: float = CDP_WAIT_SECONDS) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    attempt = 0
    while time.monotonic() < deadline:
        attempt += 1
        if not process_alive(pid):
            raise SystemExit(
                f"Claude pid={pid} exited before CDP became ready "
                f"(after {attempt} attempts). Frida gate may have failed "
                f"or AppX/policy blocked injection."
            )
        try:
            version = cdp.http_json(f"http://127.0.0.1:{port}/json/version", timeout=0.5)
            log(f"CDP ready after {attempt} attempts")
            return version
        except Exception:
            time.sleep(0.5)
    raise SystemExit(f"Timed out waiting for CDP on 127.0.0.1:{port}")


class PidProc:
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


def make_frida_message_handler() -> Any:
    def on_frida_message(message: dict[str, Any], data: Any) -> None:
        if message.get("type") == "send":
            payload = message.get("payload")
            if isinstance(payload, dict) and payload.get("type") == "log":
                log(str(payload.get("message") or payload))
            else:
                log(f"[frida] {payload!r}")
        elif message.get("type") == "error":
            log(f"[frida-error] {message}")

    return on_frida_message


def spawn_with_frida(
    exe: Path,
    port: int,
    mode: str,
    replacements: list[dict[str, str]],
    redirect_asar: Path | None = None,
) -> tuple[Any, frida.core.Session, frida.core.Script, int]:
    if not FRIDA_AGENT.exists():
        raise SystemExit(f"Missing Frida agent: {FRIDA_AGENT}")
    if port_listening(port):
        ensure_cdp_port_free(port, wait_seconds=3.0)

    argv = [str(exe), f"--remote-debugging-port={port}"]
    log(f"Frida spawn: {' '.join(argv)}")
    log(f"gate mode={mode}")

    device = frida.get_local_device()
    try:
        pid = device.spawn(
            argv,
            cwd=str(exe.parent),
            stdio="pipe",
        )
    except frida.ExecutableNotFoundError as exc:
        raise SystemExit(f"Frida could not spawn binary: {exe}: {exc}") from exc
    except frida.PermissionDeniedError as exc:
        raise SystemExit(
            "Frida spawn permission denied (AppX / antivirus / policy). "
            f"Details: {exc}"
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
            f"Frida attach failed on pid={pid}: {type(exc).__name__}: {exc}"
        ) from exc

    source = FRIDA_AGENT.read_text(encoding="utf-8")
    script = session.create_script(source)
    script.on("message", make_frida_message_handler())
    script.load()
    try:
        # configure() also does a pre-resume mem-patch so Claude.exe's embedded
        # asar header hash is rewritten while the process is still suspended.
        status = script.exports_sync.configure(
            {
                "mode": mode,
                "replacements": replacements,
                "redirectAsarPath": str(redirect_asar) if redirect_asar else "",
            }
        )
        log(f"Frida agent status (pre-resume): {json.dumps(status, ensure_ascii=False)}")
        mem_hits = int(status.get("memPatchHits") or 0)
        if mem_hits <= 0:
            log(
                "WARNING: pre-resume mem-patch hit 0 replacements. "
                "Claude.exe integrity slot may be unwritable; continuing anyway."
            )
        else:
            log(f"Pre-resume mem-patch OK (hits={mem_hits})")
    except Exception as exc:
        try:
            device.kill(pid)
        except Exception:
            pass
        raise SystemExit(f"Frida configure failed: {exc}") from exc

    device.resume(pid)
    log(f"Resumed pid={pid}")

    # Keep scanning after resume: gate JS sits ~17MB into app.asar and is not
    # present in the first ReadFile of the asar header. Auto-rescan runs in
    # the agent; we also poll from the host so logs show progress.
    try:
        script.exports_sync.start_watch()
        log("Agent auto-rescan started")
    except Exception as exc:
        log(f"start_watch failed (non-fatal): {exc}")

    last_io = 0
    last_mem = 0
    for i in range(40):
        if not process_alive(int(pid)):
            log(f"Process died during early patch window (after {i} polls)")
            break
        try:
            st = script.exports_sync.get_status()
            io_n = int(st.get("ioPatches") or 0)
            mem_n = int(st.get("memPatchHits") or 0)
            reps = st.get("replacements") or []
            if io_n != last_io or mem_n != last_mem or i == 0 or i % 4 == 0:
                log(
                    "Gate patch progress: "
                    f"io={io_n} mem={mem_n} handles={st.get('trackedHandles')} "
                    f"reps={reps}"
                )
                last_io, last_mem = io_n, mem_n
            # Gate label appears as "gate:N" once hit
            if any(str(r).startswith("gate:") and not str(r).endswith(":0") for r in reps):
                log("Gate needle patched in process memory")
                break
        except Exception as exc:
            log(f"Status poll failed: {exc}")
            break
        time.sleep(0.25)

    # One more explicit rescan for late maps.
    try:
        if process_alive(int(pid)):
            result = script.exports_sync.rescan()
            log("Mem rescan: " + json.dumps(result, ensure_ascii=False)[:700])
    except Exception as exc:
        log(f"Mem rescan failed: {exc}")

    return device, session, script, int(pid)


def detach_only(
    session: frida.core.Session | None, script: frida.core.Script | None
) -> None:
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


def kill_frida_tree(device: Any | None, pid: int) -> None:
    if device is not None and pid:
        try:
            device.kill(pid)
        except Exception:
            pass
    kill_pid(pid)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Experimental Windows Frida launcher: in-memory CDP gate patch + "
            "DOM Chinese inject. Does not modify app.asar/Claude.exe on disk."
        )
    )
    parser.add_argument(
        "--app",
        type=Path,
        default=None,
        help="Claude app directory containing Claude.exe (optional auto-detect)",
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
        help="If >0, run inject watchdog for this many seconds then exit",
    )
    parser.add_argument(
        "--keep-running",
        action="store_true",
        help="On Ctrl+C, detach Frida but leave Claude running",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    if sys.platform != "win32":
        log("Warning: frida_launch_zh_win.py is intended for Windows.")

    args = parse_args(argv)
    app_dir, exe, asar, kind = resolve_claude_install(args.app)
    port = int(args.port)

    log(f"Claude install kind: {kind}")
    log(f"  app:  {app_dir}")
    log(f"  exe:  {exe}")
    log(f"  asar: {asar}")

    lang_cfg = patch.get_language_config(args.lang)
    patch.require_file(lang_cfg["frontend_translation"])
    patch.require_file(lang_cfg["frontend_hardcoded"])

    before_asar = file_fingerprint(asar)
    before_exe = file_fingerprint(exe)
    log(f"ASAR before: {format_fp(before_asar)}")
    log(f"EXE  before: {format_fp(before_exe)}")

    runtime_asar = prepare_patched_asar_cache(asar, args.lang, before_asar)
    runtime_asar_fp = file_fingerprint(runtime_asar)
    log(f"Runtime ASAR: {runtime_asar}")
    log(f"Runtime ASAR fp: {format_fp(runtime_asar_fp)}")

    replacements = build_runtime_replacements(runtime_asar, exe)

    script_src = ""
    if not args.no_inject:
        script_src = build_win_inject_script(asar, args.lang)

    if not args.no_quit:
        log("Stopping existing Claude instances (if any)")
        stop_claude_processes()
        time.sleep(0.5)
    ensure_cdp_port_free(port, wait_seconds=5.0)

    device = session = script = None
    pid = 0
    try:
        device, session, script, pid = spawn_with_frida(
            exe, port, args.mode, replacements, runtime_asar
        )
    except SystemExit:
        raise
    except Exception as exc:
        raise SystemExit(f"Spawn path failed: {exc}") from exc

    def _cleanup(kill: bool) -> None:
        if kill:
            kill_frida_tree(device, pid)
        else:
            detach_only(session, script)
            log(f"Detached from pid={pid} (Claude left running)")
        after_asar = file_fingerprint(asar)
        after_exe = file_fingerprint(exe)
        log(f"ASAR after:  {format_fp(after_asar)}")
        log(f"EXE  after:  {format_fp(after_exe)}")
        asar_ok = (
            after_asar["sha256"] == before_asar["sha256"]
            and after_asar["size"] == before_asar["size"]
        )
        exe_ok = (
            after_exe["sha256"] == before_exe["sha256"]
            and after_exe["size"] == before_exe["size"]
        )
        log(f"ASAR_UNCHANGED={'yes' if asar_ok else 'NO'}")
        log(f"EXE_UNCHANGED={'yes' if exe_ok else 'NO'}")

    cleaned = False

    def cleanup_once(kill: bool) -> None:
        nonlocal cleaned
        if cleaned:
            return
        cleaned = True
        _cleanup(kill)

    stop = {"flag": False}

    def _on_signal(signum: int, _frame: Any) -> None:
        log(f"Received signal {signum}")
        stop["flag"] = True

    try:
        signal.signal(signal.SIGINT, _on_signal)
        if hasattr(signal, "SIGTERM"):
            signal.signal(signal.SIGTERM, _on_signal)
    except Exception:
        pass

    try:
        if args.no_inject or not script_src:
            version = wait_for_cdp_pid(port, pid)
            log(f"CDP browser: {version.get('Browser')}")
            log("Watching process (no DOM inject). Ctrl+C to stop.")
            proc = PidProc(pid)
            deadline = (
                time.monotonic() + args.watch_seconds
                if args.watch_seconds and args.watch_seconds > 0
                else None
            )
            while proc.poll() is None and not stop["flag"]:
                if deadline is not None and time.monotonic() >= deadline:
                    break
                time.sleep(0.5)
        else:
            version = wait_for_cdp_pid(port, pid)
            log(f"CDP browser: {version.get('Browser')}")
            log(f"CDP websocket: {version.get('webSocketDebuggerUrl')}")
            log("Starting CDP inject watchdog (Ctrl+C to stop)")
            proc = PidProc(pid)

            async def _watch() -> None:
                seen: dict[str, tuple[float, str]] = {}
                deadline = (
                    time.monotonic() + args.watch_seconds
                    if args.watch_seconds and args.watch_seconds > 0
                    else None
                )
                while proc.poll() is None and not stop["flag"]:
                    if deadline is not None and time.monotonic() >= deadline:
                        break
                    await cdp.inject_all_pages(port, script_src, seen)
                    await asyncio.sleep(1.0)

            asyncio.run(_watch())
            if proc.poll() is not None:
                log(f"Claude exited (pid={pid})")
    finally:
        cleanup_once(kill=not args.keep_running)

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        log("Interrupted")
        raise SystemExit(130)
