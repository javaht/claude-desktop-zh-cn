#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
One-click zh-CN patcher for Claude Desktop on macOS.

What it does:
1. Copies /Applications/Claude.app to a temporary working app.
2. Adds zh-CN to Claude Desktop's language whitelist.
3. Installs Chinese desktop-shell and frontend i18n resources.
4. Sets the current user's Claude config locale to zh-CN.
5. Moves the original app to a timestamped backup and installs the patched app.

Run from this folder:
    sudo /usr/bin/python3 scripts/patch_claude_zh_cn.py --user-home "$HOME"
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import struct
import sys
import tempfile
import time
import uuid
from pathlib import Path
from typing import Any, NamedTuple


APP_DEFAULT = Path("/Applications/Claude.app")
ROOT = Path(__file__).resolve().parent.parent
RESOURCES = ROOT / "resources"
BACKUP_GLOB = "Claude.backup-before-zh-CN-*.app"

APP_ASAR_REL = Path("Contents/Resources/app.asar")
FRONTEND_I18N_REL = Path("Contents/Resources/ion-dist/i18n")
FRONTEND_ASSETS_REL = Path("Contents/Resources/ion-dist/assets/v1")
DESKTOP_RESOURCES_REL = Path("Contents/Resources")
ASAR_PATCH_TARGET = ".vite/build/index.js"
ASAR_INTEGRITY_BLOCK_SIZE = 4 * 1024 * 1024
ONLINE_LOCALE_PRELOAD_TARGETS = [
    ".vite/build/mainView.js",
    ".vite/build/mainWindow.js",
]
ONLINE_LOCALE_MARKER = "__claudeZhOnlineLocale"
ONLINE_LOCALE_MAIN_MARKER = "__claudeZhOnlineLocaleMain"
ONLINE_TRANSLATION_MAX_SOURCE_LEN = 240
STRUCTURAL_JS_STRING_REPLACEMENTS = {
    "hour",
    "hours",
    "minute",
    "minutes",
    "second",
    "seconds",
    "day",
    "days",
    "week",
    "weeks",
    "month",
    "months",
    "year",
    "years",
}
STRUCTURAL_JS_LITERAL_REPLACEMENTS = {
    '"Search"',
}


def log(message: str) -> None:
    print(message, flush=True)


def elapsed_since(start: float) -> str:
    return f"{time.perf_counter() - start:.1f}s"

LANG_LIST_RE = re.compile(
    r'\["en-US","de-DE","fr-FR","ko-KR","ja-JP","es-419","es-ES","it-IT","hi-IN","pt-BR","id-ID"(?:(?:,"zh-CN")|(?:,"zh-TW")|(?:,"zh-HK"))*\]'
)
BASE_LANGUAGE_LIST = '["en-US","de-DE","fr-FR","ko-KR","ja-JP","es-419","es-ES","it-IT","hi-IN","pt-BR","id-ID"'


def get_language_config(lang_code: str) -> dict[str, Any]:
    """Return file paths and settings for the given language code."""
    return {
        "lang_code": lang_code,
        "frontend_translation": RESOURCES / f"frontend-{lang_code}.json",
        "frontend_hardcoded": RESOURCES / f"frontend-hardcoded-{lang_code}.json",
        "desktop_translation": RESOURCES / f"desktop-{lang_code}.json",
        "localizable_strings": RESOURCES / f"Localizable-{lang_code}.strings" if (RESOURCES / f"Localizable-{lang_code}.strings").exists() else RESOURCES / "Localizable.strings",
        "statsig_translation": RESOURCES / f"statsig-{lang_code}.json",
        "label": {
            "zh-CN": "简体中文",
            "zh-TW": "繁体中文（中国台湾）",
            "zh-HK": "繁体中文（中国香港）",
        }.get(lang_code, lang_code),
    }


def run(cmd: list[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=check)


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def save_json(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp, path)


def require_file(path: Path) -> None:
    if not path.exists():
        raise SystemExit(f"Missing required file: {path}")


def read_entitlements(path: Path) -> str:
    return run(["codesign", "-d", "--entitlements", "-", str(path)], check=False).stdout


def load_entitlements(path: Path) -> dict[str, Any]:
    result = subprocess.run(
        ["codesign", "-d", "--entitlements", ":-", str(path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0 or not result.stdout.strip():
        return {}
    try:
        data = plistlib.loads(result.stdout)
    except Exception:
        return {}
    return data if isinstance(data, dict) else {}


def require_virtualization_entitlement(app: Path) -> None:
    entitlements = read_entitlements(app)
    if "com.apple.security.virtualization" not in entitlements:
        raise SystemExit(
            "Claude.app does not have the required virtualization entitlement. "
            "Restore or reinstall the official Claude.app first, then run this patcher again."
        )


def quit_claude() -> None:
    run(["osascript", "-e", 'tell application "Claude" to quit'], check=False)


def copy_app(src: Path, dst: Path) -> None:
    if dst.exists():
        shutil.rmtree(dst)
    start = time.perf_counter()
    log(f"Copying app to temporary workspace: {dst}")
    run(["ditto", str(src), str(dst)])
    log(f"Copied app to temporary workspace in {elapsed_since(start)}")


def patch_language_whitelist(app: Path, lang_code: str) -> Path:
    assets_dir = app / FRONTEND_ASSETS_REL
    candidates = sorted(assets_dir.glob("*.js"))
    if not candidates:
        raise SystemExit(f"Cannot find frontend JS bundle in {assets_dir}")

    replacement = f'{BASE_LANGUAGE_LIST},"{lang_code}"]'

    for path in candidates:
        text = path.read_text(encoding="utf-8")
        if replacement in text:
            print(f"Language whitelist already contains {lang_code}: {path.name}")
            return path
        if LANG_LIST_RE.search(text):
            patched = LANG_LIST_RE.sub(
                replacement,
                text,
                count=1,
            )
            path.write_text(patched, encoding="utf-8")
            print(f"Patched language whitelist: {path.name}")
            return path

    raise SystemExit("Could not patch language whitelist. Claude's bundle format may have changed.")


def patch_language_display_names(app: Path) -> None:
    assets_dir = app / FRONTEND_ASSETS_REL
    candidates = sorted(assets_dir.glob("index-*.js"))
    if not candidates:
        raise SystemExit(f"Cannot find frontend index bundle in {assets_dir}")

    marker = "__claudeZhLabelPatch"
    patch = ';(()=>{const e=Intl.DisplayNames&&Intl.DisplayNames.prototype;if(!e||e.__claudeZhLabelPatch)return;const n=e.of;e.of=function(e){const t=String(e);return t==="zh-CN"?"简体中文":t==="zh-HK"?"繁体中文（中国香港）":t==="zh-TW"?"繁体中文（中国台湾）":n.call(this,e)},Object.defineProperty(e,"__claudeZhLabelPatch",{value:!0})})();'
    for path in candidates:
        text = path.read_text(encoding="utf-8")
        if marker in text:
            print(f"Language display names already patched: {path.name}")
            continue
        path.write_text(text + patch, encoding="utf-8")
        print(f"Patched language display names: {path.name}")


def load_frontend_hardcoded_replacements(lang_code: str) -> list[tuple[str, str]]:
    path = get_language_config(lang_code)["frontend_hardcoded"]
    require_file(path)
    data = load_json(path)
    if not isinstance(data, list):
        raise SystemExit(f"Unsupported hardcoded frontend replacement JSON shape: {path}")

    replacements: list[tuple[str, str]] = []
    for item in data:
        if not (
            isinstance(item, list)
            and len(item) == 2
            and isinstance(item[0], str)
            and isinstance(item[1], str)
        ):
            raise SystemExit(f"Invalid hardcoded frontend replacement entry in {path}: {item!r}")
        replacements.append((item[0], item[1]))
    return replacements


def is_plain_ui_text_replacement(source: str) -> bool:
    code_markers = ['"', "\\", "=", ";", "=>"]
    return "\n" not in source and not any(marker in source for marker in code_markers)


def replace_frontend_hardcoded_text(text: str, source: str, target: str) -> tuple[str, int]:
    if source in STRUCTURAL_JS_STRING_REPLACEMENTS or source in STRUCTURAL_JS_LITERAL_REPLACEMENTS:
        return text, 0

    if not is_plain_ui_text_replacement(source):
        count = text.count(source)
        if count:
            text = text.replace(source, target)
        return text, count

    pattern = re.compile(r'(?P<quote>["\'`])' + re.escape(source) + r"(?P=quote)")

    def replace_match(match: re.Match[str]) -> str:
        quote = match.group("quote")
        return f"{quote}{target}{quote}"

    return pattern.subn(replace_match, text)


def patch_hardcoded_frontend_strings(app: Path, lang_code: str) -> None:
    start = time.perf_counter()
    assets_dir = app / FRONTEND_ASSETS_REL
    replacement_items = sorted(
        load_frontend_hardcoded_replacements(lang_code),
        key=lambda item: len(item[0]),
        reverse=True,
    )
    js_files = sorted(assets_dir.glob("*.js"))
    patched_files = 0
    patched_strings = 0

    log(
        "Scanning frontend JS for hardcoded strings: "
        f"{len(js_files)} files, {len(replacement_items)} replacement rules"
    )
    for index, path in enumerate(js_files, start=1):
        text = path.read_text(encoding="utf-8")
        patched = text
        count = 0
        for source, target in replacement_items:
            patched, occurrences = replace_frontend_hardcoded_text(patched, source, target)
            if occurrences:
                count += occurrences
        if patched != text:
            path.write_text(patched, encoding="utf-8")
            patched_files += 1
            patched_strings += count
        if index % 50 == 0 or index == len(js_files):
            log(
                "  scanned "
                f"{index}/{len(js_files)} JS files, "
                f"{patched_strings} replacements so far ({elapsed_since(start)})"
            )

    log(
        "Patched hardcoded frontend strings: "
        f"{patched_strings} replacements in {patched_files} files ({elapsed_since(start)})"
    )


def align4(value: int) -> int:
    return value + ((4 - (value % 4)) % 4)


def read_asar_header(data: bytes, path: Path) -> tuple[int, str, dict[str, Any]]:
    if len(data) < 16:
        raise SystemExit(f"Unsupported app.asar header in {path}")

    size_pickle_payload = struct.unpack_from("<I", data, 0)[0]
    header_size = struct.unpack_from("<I", data, 4)[0]
    if size_pickle_payload != 4 or header_size <= 0 or len(data) < 8 + header_size:
        raise SystemExit(f"Unsupported app.asar size pickle in {path}")

    header_pickle = data[8 : 8 + header_size]
    header_payload_size = struct.unpack_from("<I", header_pickle, 0)[0]
    header_string_size = struct.unpack_from("<i", header_pickle, 4)[0]
    expected_payload_size = align4(4 + header_string_size)
    if header_payload_size != expected_payload_size or header_size != 4 + header_payload_size:
        raise SystemExit(f"Unsupported app.asar header pickle in {path}")

    header_start = 8
    header_end = header_start + header_string_size
    header_string = header_pickle[header_start:header_end].decode("utf-8")
    header = json.loads(header_string)
    if not isinstance(header, dict):
        raise SystemExit(f"Unsupported app.asar header JSON in {path}")
    return header_size, header_string, header


def encode_asar_header_dynamic(header_string: str) -> bytes:
    header_bytes = header_string.encode("utf-8")
    header_payload_size = align4(4 + len(header_bytes))
    header_pickle = (
        struct.pack("<I", header_payload_size)
        + struct.pack("<i", len(header_bytes))
        + header_bytes
        + b"\0" * (header_payload_size - 4 - len(header_bytes))
    )
    return struct.pack("<I", 4) + struct.pack("<I", len(header_pickle)) + header_pickle


def encode_asar_header(header_string: str, expected_header_size: int) -> bytes:
    encoded = encode_asar_header_dynamic(header_string)
    actual_size = struct.unpack_from("<I", encoded, 4)[0]
    if actual_size != expected_header_size:
        raise SystemExit("Internal patch error: app.asar header length changed.")
    return encoded


def get_asar_file_entry(header: dict[str, Any], file_path: str) -> dict[str, Any]:
    node: dict[str, Any] = header
    for part in file_path.split("/"):
        files = node.get("files")
        if not isinstance(files, dict) or part not in files:
            raise SystemExit(f"Could not find {file_path} in app.asar header.")
        child = files[part]
        if not isinstance(child, dict):
            raise SystemExit(f"Unsupported app.asar header entry for {file_path}.")
        node = child
    for key in ["size", "offset", "integrity"]:
        if key not in node:
            raise SystemExit(f"Missing {key} for {file_path} in app.asar header.")
    return node


def iter_asar_file_entries(header: dict[str, Any]) -> list[dict[str, Any]]:
    entries: list[dict[str, Any]] = []

    def walk(node: dict[str, Any]) -> None:
        files = node.get("files")
        if not isinstance(files, dict):
            return
        for child in files.values():
            if not isinstance(child, dict):
                continue
            if "files" in child:
                walk(child)
            elif "offset" in child and "size" in child:
                entries.append(child)

    walk(header)
    return entries


def set_asar_offset(entry: dict[str, Any], offset: int) -> None:
    entry["offset"] = str(offset) if isinstance(entry.get("offset"), str) else offset


def calculate_file_integrity(data: bytes) -> dict[str, Any]:
    blocks = [
        hashlib.sha256(data[offset : offset + ASAR_INTEGRITY_BLOCK_SIZE]).hexdigest()
        for offset in range(0, len(data), ASAR_INTEGRITY_BLOCK_SIZE)
    ]
    if not blocks:
        blocks.append(hashlib.sha256(data).hexdigest())
    return {
        "algorithm": "SHA256",
        "hash": hashlib.sha256(data).hexdigest(),
        "blockSize": ASAR_INTEGRITY_BLOCK_SIZE,
        "blocks": blocks,
    }


class AsarFileContent(NamedTuple):
    """Asar 文件解析后的结构化内容。"""
    data: bytearray
    header_size: int
    header: dict[str, Any]
    entry: dict[str, Any]
    content: bytes


def write_asar_content_in_place(
    app: Path,
    data: bytearray,
    header_size: int,
    header: dict[str, Any],
    entry: dict[str, Any],
    content_offset: int,
    content_end: int,
    patched_content: bytes,
) -> None:
    path = app / APP_ASAR_REL
    data[content_offset:content_end] = patched_content
    entry["integrity"] = calculate_file_integrity(patched_content)
    updated_header_string = json.dumps(header, ensure_ascii=False, separators=(",", ":"))
    updated_header = encode_asar_header(updated_header_string, header_size)
    data[: len(updated_header)] = updated_header
    path.write_bytes(data)
    update_electron_asar_integrity(app, updated_header_string)


def read_asar_file_content(app: Path, file_path: str) -> AsarFileContent:
    path = app / APP_ASAR_REL
    require_file(path)
    data = bytearray(path.read_bytes())
    header_size, _header_string, header = read_asar_header(data, path)
    entry = get_asar_file_entry(header, file_path)
    content_offset = 8 + header_size + int(entry["offset"])
    content_size = int(entry["size"])
    content_end = content_offset + content_size
    if content_offset < 0 or content_end > len(data):
        raise SystemExit(f"Unsupported app.asar file bounds for {file_path}.")
    content = bytes(data[content_offset:content_end])
    return AsarFileContent(data, header_size, header, entry, content)


def replace_asar_file_content(app: Path, file_path: str, patched_content: bytes) -> bool:
    path = app / APP_ASAR_REL

    asar = read_asar_file_content(app, file_path)
    data = asar.data
    header_size = asar.header_size
    header = asar.header
    entry = asar.entry
    content_offset = 8 + header_size + int(entry["offset"])
    content_end = content_offset + int(entry["size"])

    old_content = asar.content
    if old_content == patched_content:
        return False

    target_offset = int(entry["offset"])
    delta = len(patched_content) - content_size
    data[content_offset:content_end] = patched_content

    entry["size"] = len(patched_content)
    entry["integrity"] = calculate_file_integrity(patched_content)
    if delta:
        for other in iter_asar_file_entries(header):
            if other is not entry and int(other["offset"]) > target_offset:
                set_asar_offset(other, int(other["offset"]) + delta)

    updated_header_string = json.dumps(header, ensure_ascii=False, separators=(",", ":"))
    updated_header = encode_asar_header_dynamic(updated_header_string)
    body = bytes(data[8 + header_size :])

    path.write_bytes(updated_header + body)
    update_electron_asar_integrity(app, updated_header_string)
    return True


def build_online_locale_injection(lang_code: str) -> str:
    return (
        f';(()=>{{const l="{lang_code}",s=()=>{{try{{localStorage.setItem("spa:locale",l);'
        'document.documentElement&&document.documentElement.setAttribute("lang",l)}}catch{{}}}};'
        f's();addEventListener("DOMContentLoaded",s)}})();/*{ONLINE_LOCALE_MARKER}*/'
    )


def strip_online_locale_injection(text: str) -> tuple[str, bool]:
    pattern = re.compile(
        rf';\(\(\)=>\{{const l="[^"]+".*?/\*{ONLINE_LOCALE_MARKER}\*/',
        re.DOTALL,
    )
    patched, count = pattern.subn("", text)
    return patched, count > 0


def remove_online_locale_preload(content: bytes) -> tuple[bytes, bool]:
    text = content.decode("utf-8")
    text, had_existing = strip_online_locale_injection(text)
    return text.encode("utf-8"), had_existing


def patch_online_locale_preload(app: Path, lang_code: str) -> None:
    path = app / APP_ASAR_REL
    require_file(path)
    data = path.read_bytes()
    header_size, _header_string, header = read_asar_header(data, path)

    removed_count = 0
    for file_path in ONLINE_LOCALE_PRELOAD_TARGETS:
        entry = get_asar_file_entry(header, file_path)
        content_offset = 8 + header_size + int(entry["offset"])
        content_size = int(entry["size"])
        content_end = content_offset + content_size
        if content_offset < 0 or content_end > len(data):
            raise SystemExit(f"Unsupported app.asar file bounds for {file_path}.")

        content = data[content_offset:content_end]
        patched_content, changed = remove_online_locale_preload(content)
        if changed:
            if replace_asar_file_content(app, file_path, patched_content):
                removed_count += 1
            data = path.read_bytes()
            header_size, _header_string, header = read_asar_header(data, path)

    if removed_count:
        print(f"Removed stale online claude.ai locale preload: {removed_count} files")
    else:
        print("Online claude.ai locale preload not present")


def is_online_dom_translation_entry(source: str, target: str) -> bool:
    if not source or not target or source == target:
        return False
    if len(source) > ONLINE_TRANSLATION_MAX_SOURCE_LEN:
        return False
    blocked_fragments = ["<", "{", "\n", "http://", "https://"]
    return not any(fragment in source or fragment in target for fragment in blocked_fragments)


def build_online_translation_map(app: Path, lang_code: str) -> dict[str, str]:
    config = get_language_config(lang_code)
    en_path = app / FRONTEND_I18N_REL / "en-US.json"
    require_file(en_path)
    require_file(config["frontend_translation"])

    en = load_json(en_path)
    zh = load_json(config["frontend_translation"])
    if not isinstance(en, dict) or not isinstance(zh, dict):
        raise SystemExit("Unsupported frontend i18n JSON shape for online DOM translation.")

    mapping: dict[str, str] = {}
    for key, source in en.items():
        target = zh.get(key)
        if isinstance(source, str) and isinstance(target, str) and is_online_dom_translation_entry(source, target):
            mapping[source] = target

    for source, target in load_frontend_hardcoded_replacements(lang_code):
        if is_online_dom_translation_entry(source, target):
            mapping[source] = target

    return dict(sorted(mapping.items()))


def build_online_dom_translation_script(lang_code: str, mapping: dict[str, str]) -> str:
    mapping_json = json.dumps(mapping, ensure_ascii=False, separators=(",", ":"))
    if lang_code == "zh-CN":
        selected_text = "已选择 $1 项"
        delete_selected_text = "删除 $1 个所选项目"
    else:
        selected_text = "已選擇 $1 項"
        delete_selected_text = "刪除 $1 個所選項目"
    dynamic_rules = "".join((
        f'[/^(\\d+) selected$/,"{selected_text}"],'
        f'[/^Delete (\\d+) selected item$/,"{delete_selected_text}"],'
        f'[/^Delete (\\d+) selected items$/,"{delete_selected_text}"],'
        '[/^Mon$/,"周一"],[/^Tue$/,"周二"],[/^Wed$/,"周三"],[/^Thu$/,"周四"],'
        '[/^Fri$/,"周五"],[/^Sat$/,"周六"],[/^Sun$/,"周日"]'
    ))
    return (
        "(()=>{try{"
        f'const L="{lang_code}",M={mapping_json};'
        'localStorage.setItem("spa:locale",L);'
        'document.documentElement&&document.documentElement.setAttribute("lang",L);'
        'const N=s=>(s||"").replace(/\\s+/g," ").trim();'
        'const G=[[/^Morning, (.+)$/,"早上好，$1"],[/^Good morning, (.+)$/,"早上好，$1"],'
        '[/^Afternoon, (.+)$/,"下午好，$1"],[/^Good afternoon, (.+)$/,"下午好，$1"],'
        '[/^Evening, (.+)$/,"晚上好，$1"],[/^Good evening, (.+)$/,"晚上好，$1"],'
        '[/^It\\\'s late-night (.+)$/,"夜深了，$1"],[/^Good night, (.+)$/,"晚安，$1"],'
        '[/^Delete (\\d+) chat$/,"删除 $1 个聊天"],[/^Delete (\\d+) chats$/,"删除 $1 个聊天"],'
        '[/^Move (\\d+) chat to a project$/,"将 $1 个聊天移至项目"],[/^Move (\\d+) chats to a project$/,"将 $1 个聊天移至项目"],'
        '[/^Connection needs (\\d+) field$/,"连接还需要填写 $1 个字段"],[/^Connection needs (\\d+) fields$/,"连接还需要填写 $1 个字段"],'
        '[/^needs (\\d+) field$/,"还需要填写 $1 个字段"],[/^needs (\\d+) fields$/,"还需要填写 $1 个字段"],'
        '[/^Are you sure you want to delete (\\d+) chat\\? This cannot be undone\\.$/,"你确定要删除 $1 个聊天吗？此操作无法撤消。"],'
        '[/^Are you sure you want to delete (\\d+) chats\\? This cannot be undone\\.$/,"你确定要删除 $1 个聊天吗？此操作无法撤消。"],'
        '[/^Are you sure you want to permanently delete this chat\\? This cannot be undone\\.$/,"你确定要永久删除此聊天吗？此操作无法撤消。"],'
        '[/^Are you sure you want to permanently delete these chats\\? This cannot be undone\\.$/,"你确定要永久删除这些聊天吗？此操作无法撤消。"],'
        '[/^Archive (\\d+) task\\? You can find it in the Archived tab\\.$/,"要归档 $1 个任务吗？你可以在“已归档”标签页中找到它。"],'
        '[/^Archive (\\d+) tasks\\? You can find them in the Archived tab\\.$/,"要归档 $1 个任务吗？你可以在“已归档”标签页中找到它们。"],'
        f'{dynamic_rules}];'
        'const R=s=>{const n=N(s);if(M[n])return M[n];for(const [r,t] of G){const m=n.match(r);'
        'if(m)return t.replace("$1",m[1])}};'
        'const X=new Set(["SCRIPT","STYLE","NOSCRIPT"]);'
        "function T(){"
        "try{"
        "const b=document.body||document.documentElement;if(!b)return;"
        "const w=document.createTreeWalker(b,NodeFilter.SHOW_TEXT,{acceptNode(n){"
        "const p=n.parentElement;if(!p||X.has(p.tagName)||p.closest('[contenteditable]')||!R(n.nodeValue))return NodeFilter.FILTER_REJECT;"
        "return NodeFilter.FILTER_ACCEPT}});"
        "let n;while(n=w.nextNode()){const v=R(n.nodeValue);if(v)n.nodeValue=v}"
        'document.querySelectorAll("[role=dialog] p,[role=dialog] div,[role=dialog] span").forEach(e=>{try{'
        'if(e.closest("button,[contenteditable]"))return;'
        'const t=R(e.textContent);'
        'if(t&&N(e.textContent)!==N(t))e.textContent=t'
        '}catch{}});'
        'document.querySelectorAll("[aria-label],[title],[placeholder],input,textarea").forEach(e=>{'
        '["aria-label","title","placeholder","value"].forEach(a=>{'
        'try{if(a==="value"&&!(e.matches("input[type=button],input[type=submit]")))return;'
        "let v=e.getAttribute?e.getAttribute(a):void 0;if(v==null&&a in e)v=e[a];const t=R(v);"
        "if(t){if(e.setAttribute)e.setAttribute(a,t);try{if(a in e)e[a]=t}catch{}}}catch{}})});"
        'document.querySelectorAll("a").forEach(e=>{try{'
        'const r=e.getBoundingClientRect(),txt=N(e.textContent);'
        'if(txt==="Claude"&&r.left<100&&r.top<100)e.style.visibility="hidden"}catch{}});'
        "}catch{}}"
        "T();"
        "new MutationObserver(()=>{clearTimeout(window.__claudeZhDomTimer);window.__claudeZhDomTimer=setTimeout(T,30)})"
        ".observe(document.documentElement,{subtree:true,childList:true,characterData:true,attributes:true});"
        "}catch(e){}})()"
    )


def build_online_locale_main_process_script(
    lang_code: str,
    mapping: dict[str, str],
    web_contents_expr: str,
    existing_dom_ready_body: str,
) -> str:
    script = (
        f'(()=>{{try{{const l="{lang_code}";'
        'if(localStorage.getItem("spa:locale")!==l){localStorage.setItem("spa:locale",l)}}catch(e){}})();'
        + build_online_dom_translation_script(lang_code, mapping)
    )
    return (
        f'{web_contents_expr}.on("dom-ready",()=>{{{existing_dom_ready_body};'
        f"{web_contents_expr}.executeJavaScript({json.dumps(script)}).catch(()=>{{}})"
        f"}});/*{ONLINE_LOCALE_MAIN_MARKER}*/"
    )


def strip_online_locale_main_process_patch(text: str) -> tuple[str, bool]:
    pattern = re.compile(
        r'(?P<web_contents>[A-Za-z_$][A-Za-z0-9_$]*\.webContents)'
        r'\.on\("dom-ready",\(\)=>\{'
        r'(?P<body>.*?);'
        r'(?P=web_contents)\.executeJavaScript\("(?:\\.|[^"])*"\)\.catch\(\(\)=>\{\}\)'
        rf'\}}\);/\*{ONLINE_LOCALE_MAIN_MARKER}\*/'
    )

    def restore(match: re.Match[str]) -> str:
        web_contents = match.group("web_contents")
        body = match.group("body")
        return f'{web_contents}.on("dom-ready",()=>{{{body}}});'

    patched, count = pattern.subn(restore, text)
    return patched, count > 0


def find_main_view_dom_ready_handler(text: str) -> re.Match[str] | None:
    pattern = re.compile(
        r'(?P<web_contents>[A-Za-z_$][A-Za-z0-9_$]*\.webContents)'
        r'\.on\("dom-ready",\(\)=>\{(?P<body>[^{}]*)\}\);'
    )
    matches = [
        match
        for match in pattern.finditer(text)
        if "main_view_dom_ready" in match.group("body")
    ]
    if len(matches) > 1:
        raise SystemExit("Could not patch online locale main-process hook: multiple main_view_dom_ready handlers found.")
    if matches:
        return matches[0]

    matches = [
        match
        for match in pattern.finditer(text)
        if ".vite/build/mainView.js" in text[max(0, match.start() - 2500) : match.start()]
    ]
    if len(matches) > 1:
        raise SystemExit("Could not patch online locale main-process hook: multiple main view dom-ready handlers found.")
    if matches:
        return matches[0]
    return pattern.search(text)


def patch_online_locale_main_process(app: Path, lang_code: str) -> None:
    path = app / APP_ASAR_REL
    require_file(path)

    data = path.read_bytes()
    header_size, _header_string, header = read_asar_header(data, path)
    entry = get_asar_file_entry(header, ASAR_PATCH_TARGET)
    content_offset = 8 + header_size + int(entry["offset"])
    content_size = int(entry["size"])
    content_end = content_offset + content_size
    if content_offset < 0 or content_end > len(data):
        raise SystemExit(f"Unsupported app.asar file bounds for {ASAR_PATCH_TARGET}.")

    text = data[content_offset:content_end].decode("utf-8")
    text, had_existing = strip_online_locale_main_process_patch(text)
    mapping = build_online_translation_map(app, lang_code)
    handler = find_main_view_dom_ready_handler(text)
    if handler is None:
        print(
            "Warning: could not find main view dom-ready anchor for online locale patch; "
            "skipping online claude.ai DOM translation."
        )
        return

    injection = build_online_locale_main_process_script(
        lang_code,
        mapping,
        handler.group("web_contents"),
        handler.group("body"),
    )
    if injection in text:
        print("Online claude.ai locale main-process patch already applied")
        return

    patched = (text[: handler.start()] + injection + text[handler.end() :]).encode("utf-8")
    replace_asar_file_content(app, ASAR_PATCH_TARGET, patched)
    action = "Refreshed" if had_existing else "Patched"
    print(f"{action} online claude.ai locale main-process hook: {len(mapping)} DOM strings")


def _custom3p_validation_removed(content: bytes) -> bool:
    return (
        b"expected a gateway model route referencing an Anthropic model" not in content
        and b"Bedrock model" not in content
    )


def find_custom3p_validation_toggle(content: bytes, expr: bytes) -> re.Match[bytes] | None:
    pattern = re.compile(
        rb"const ([A-Za-z_$][A-Za-z0-9_$]*)="
        + re.escape(expr)
        + rb"\|\|!1,([A-Za-z_$][A-Za-z0-9_$]*)="
    )
    matches: list[re.Match[bytes]] = []
    for match in pattern.finditer(content):
        flag_name = match.group(1)
        validation_window = content[match.start() : match.start() + 2500]
        if (
            b"if(!" + flag_name + b")return{ok:!0}" in validation_window
            and b"expected a gateway model route referencing an Anthropic model" in validation_window
            and b"Bedrock model" in validation_window
        ):
            matches.append(match)

    if len(matches) > 1:
        raise SystemExit("Could not patch custom 3P model validation: multiple matching toggles found.")
    return matches[0] if matches else None


def find_custom3p_name_validator(content: bytes, *, patched: bool) -> re.Match[bytes] | None:
    pattern = re.compile(
        rb"function ([A-Za-z_$][A-Za-z0-9_$]*)\(([A-Za-z_$][A-Za-z0-9_$]*)\)"
        rb"\{const ([A-Za-z_$][A-Za-z0-9_$]*)=\2\.toLowerCase\(\);return ([^{};]+)\}"
    )
    matches: list[re.Match[bytes]] = []
    for match in pattern.finditer(content):
        expr = match.group(4).strip()
        validation_window = content[max(0, match.start() - 1500) : match.start() + 3000]
        if (
            b"deepseek" in validation_window
            and b"expected a gateway model route referencing an Anthropic model" in validation_window
        ):
            if patched and expr == b"!0":
                matches.append(match)
            elif (
                not patched
                and b".test(" in match.group(4)
                and b".some(" in match.group(4)
                and b".includes(" in match.group(4)
            ):
                matches.append(match)

    if len(matches) > 1:
        raise SystemExit("Could not patch custom 3P model validation: multiple matching validators found.")
    return matches[0] if matches else None


def patch_custom3p_name_validator(content: bytes) -> bytes | None:
    match = find_custom3p_name_validator(content, patched=False)
    if match is None:
        return None

    expr = match.group(4)
    replacement = b"!0" + b" " * (len(expr) - len(b"!0"))
    if len(expr) != len(replacement):
        raise SystemExit("Internal patch error: custom 3P validator replacement changed length.")
    return content[: match.start(4)] + replacement + content[match.end(4) :]


def update_electron_asar_integrity(app: Path, header_string: str) -> None:
    info_plist = app / "Contents/Info.plist"
    require_file(info_plist)
    with info_plist.open("rb") as f:
        info = plistlib.load(f)

    integrity = info.get("ElectronAsarIntegrity")
    if not isinstance(integrity, dict):
        raise SystemExit("Info.plist is missing ElectronAsarIntegrity.")
    app_asar = integrity.get("Resources/app.asar")
    if not isinstance(app_asar, dict) or app_asar.get("algorithm") != "SHA256":
        raise SystemExit("Info.plist has unsupported ElectronAsarIntegrity format.")

    app_asar["hash"] = hashlib.sha256(header_string.encode("utf-8")).hexdigest()
    tmp = info_plist.with_suffix(info_plist.suffix + ".tmp")
    with tmp.open("wb") as f:
        plistlib.dump(info, f, fmt=plistlib.FMT_XML)
    os.replace(tmp, info_plist)


def patch_custom3p_model_validation(app: Path) -> None:
    path = app / APP_ASAR_REL

    old_expr = b'process.env.NODE_ENV!=="production"'
    new_expr = b"false"
    replacement = new_expr + b" " * (len(old_expr) - len(new_expr))

    asar = read_asar_file_content(app, ASAR_PATCH_TARGET)
    data = asar.data
    header_size = asar.header_size
    header = asar.header
    entry = asar.entry
    content_offset = 8 + header_size + int(entry["offset"])
    content_end = content_offset + int(entry["size"])

    content = asar.content
    match = find_custom3p_validation_toggle(content, old_expr)
    if match is None:
        patched_match = find_custom3p_validation_toggle(content, replacement)
        if patched_match is not None:
            print("Custom 3P model-name validation already patched in app.asar")
            return
        if find_custom3p_name_validator(content, patched=True) is not None:
            print("Custom 3P model-name validation already patched in app.asar")
            return
        patched_content = patch_custom3p_name_validator(content)
        if patched_content is None:
            if _custom3p_validation_removed(content):
                print("Custom 3P model-name validation not present (removed in this Claude version)")
                return
            raise SystemExit(
                "Could not patch custom 3P model validation. Claude bundle format may have changed."
            )
    else:
        anchor = match.group(0)
        patched = (
            b"const "
            + match.group(1)
            + b"="
            + replacement
            + b"||!1,"
            + match.group(2)
            + b"="
        )
        if len(anchor) != len(patched):
            raise SystemExit("Internal patch error: custom 3P validation replacement changed length.")
        patched_content = content[: match.start()] + patched + content[match.end() :]

    if len(patched_content) != len(content):
        raise SystemExit("Internal patch error: app.asar length changed during custom 3P patch.")
    write_asar_content_in_place(app, data, header_size, header, entry, content_offset, content_end, patched_content)
    print("Patched custom 3P model-name validation in app.asar")


def get_main_process_menu_replacements(lang_code: str) -> dict[str, str]:
    replacements_by_lang = {
        "zh-CN": {
            "File": "文件",
            "Edit": "编辑",
            "View": "查看",
            "Developer": "开发者",
            "Help": "帮助",
            "Extensions": "扩展",
            "Open Developer Config File…": "打开开发者配置文件…",
            "Open Developer Config File...": "打开开发者配置文件...",
            "Configure Third-Party Inference…": "配置第三方推理…",
            "Configure Third-Party Inference...": "配置第三方推理...",
            "Open App Config File…": "打开应用配置文件…",
            "Open App Config File...": "打开应用配置文件...",
            "Reload MCP Configuration": "重新加载 MCP 配置",
            "Open MCP Log File": "打开 MCP 日志文件",
            "Open MCP Log File…": "打开 MCP 日志文件…",
            "Open MCP Log File...": "打开 MCP 日志文件...",
            "Open Hardware Buddy…": "打开硬件伙伴…",
            "Open Hardware Buddy...": "打开硬件伙伴...",
            "Show All Dev Tools": "显示所有开发者工具",
            "Show Dev Tools": "显示开发者工具",
            "Enable Main Process Debugger": "启用主进程调试器",
            "Record Performance Trace": "记录性能跟踪",
            "Write Main Process Heap Snapshot": "写入主进程堆快照",
            "Record Memory Trace (auto-stop)": "记录内存跟踪 (自动)",
        },
        "zh-TW": {
            "File": "檔案",
            "Edit": "編輯",
            "View": "檢視",
            "Developer": "開發者",
            "Help": "說明",
            "Extensions": "擴充功能",
            "Open Developer Config File…": "開啟開發者設定檔…",
            "Open Developer Config File...": "開啟開發者設定檔...",
            "Configure Third-Party Inference…": "設定第三方推理…",
            "Configure Third-Party Inference...": "設定第三方推理...",
            "Open App Config File…": "開啟應用程式設定檔…",
            "Open App Config File...": "開啟應用程式設定檔...",
            "Reload MCP Configuration": "重新載入 MCP 設定",
            "Open MCP Log File": "開啟 MCP 記錄檔",
            "Open MCP Log File…": "開啟 MCP 記錄檔…",
            "Open MCP Log File...": "開啟 MCP 記錄檔...",
            "Open Hardware Buddy…": "開啟硬體夥伴…",
            "Open Hardware Buddy...": "開啟硬體夥伴...",
            "Show All Dev Tools": "顯示所有開發者工具",
            "Show Dev Tools": "顯示開發者工具",
            "Enable Main Process Debugger": "啟用主行程偵錯器",
            "Record Performance Trace": "記錄效能追蹤",
            "Write Main Process Heap Snapshot": "寫入主行程堆積快照",
            "Record Memory Trace (auto-stop)": "記錄記憶體追蹤 (自動)",
        },
        "zh-HK": {
            "File": "檔案",
            "Edit": "編輯",
            "View": "檢視",
            "Developer": "開發者",
            "Help": "說明",
            "Extensions": "擴充功能",
            "Open Developer Config File…": "開啟開發者設定檔…",
            "Open Developer Config File...": "開啟開發者設定檔...",
            "Configure Third-Party Inference…": "設定第三方推理…",
            "Configure Third-Party Inference...": "設定第三方推理...",
            "Open App Config File…": "開啟應用程式設定檔…",
            "Open App Config File...": "開啟應用程式設定檔...",
            "Reload MCP Configuration": "重新載入 MCP 設定",
            "Open MCP Log File": "開啟 MCP 記錄檔",
            "Open MCP Log File…": "開啟 MCP 記錄檔…",
            "Open MCP Log File...": "開啟 MCP 記錄檔...",
            "Open Hardware Buddy…": "開啟硬件夥伴…",
            "Open Hardware Buddy...": "開啟硬件夥伴...",
            "Show All Dev Tools": "顯示所有開發者工具",
            "Show Dev Tools": "顯示開發者工具",
            "Enable Main Process Debugger": "啟用主行程偵錯器",
            "Record Performance Trace": "記錄效能追蹤",
            "Write Main Process Heap Snapshot": "寫入主行程堆積快照",
            "Record Memory Trace (auto-stop)": "記錄記憶體追蹤 (自動)",
        },
    }
    return replacements_by_lang[lang_code]


def get_main_process_menu_intl_replacements(lang_code: str) -> dict[str, str]:
    replacements_by_lang = {
        "zh-CN": {
            "0tZLEYF8mJ": "开发者",
            "/PgA81GVOD": "编辑",
            "LCWUQ/4Fu6": "查看",
            "uc3dnSo+eo": "文件",
            "EfdnINFnIz": "文件",
            "pWXxZASpOB": "帮助",
            "JOf7G+dCf1": "打开应用配置文件...",
            "K5GtyaPaw/": "打开开发者配置文件...",
            "RTg057HE1D": "显示开发者工具",
            "STqYpFr7p4": "显示所有开发者工具",
            "rNAd+HxSK4": "打开 MCP 日志文件",
            "PW5U8NgTto": "打开 MCP 日志文件...",
            "uKCcuVd1Yt": "重新加载 MCP 配置",
            "9GRz7bC+rr": "配置第三方推理…",
        },
        "zh-TW": {
            "0tZLEYF8mJ": "開發者",
            "/PgA81GVOD": "編輯",
            "LCWUQ/4Fu6": "檢視",
            "uc3dnSo+eo": "檔案",
            "EfdnINFnIz": "檔案",
            "pWXxZASpOB": "說明",
            "JOf7G+dCf1": "開啟應用程式設定檔...",
            "K5GtyaPaw/": "開啟開發者設定檔...",
            "RTg057HE1D": "顯示開發者工具",
            "STqYpFr7p4": "顯示所有開發者工具",
            "rNAd+HxSK4": "開啟 MCP 記錄檔",
            "PW5U8NgTto": "開啟 MCP 記錄檔...",
            "uKCcuVd1Yt": "重新載入 MCP 設定",
            "9GRz7bC+rr": "設定第三方推理…",
        },
        "zh-HK": {
            "0tZLEYF8mJ": "開發者",
            "/PgA81GVOD": "編輯",
            "LCWUQ/4Fu6": "檢視",
            "uc3dnSo+eo": "檔案",
            "EfdnINFnIz": "檔案",
            "pWXxZASpOB": "說明",
            "JOf7G+dCf1": "開啟應用程式設定檔...",
            "K5GtyaPaw/": "開啟開發者設定檔...",
            "RTg057HE1D": "顯示開發者工具",
            "STqYpFr7p4": "顯示所有開發者工具",
            "rNAd+HxSK4": "開啟 MCP 記錄檔",
            "PW5U8NgTto": "開啟 MCP 記錄檔...",
            "uKCcuVd1Yt": "重新載入 MCP 設定",
            "9GRz7bC+rr": "設定第三方推理…",
        },
    }
    return replacements_by_lang[lang_code]


def replace_menu_intl_message_by_id(text: str, message_id: str, target: str) -> tuple[str, int]:
    updated = text
    count = 0
    needle = f'id:"{message_id}"'
    pattern = re.compile(
        r'[A-Za-z_$][A-Za-z0-9_$]*\(\)\.formatMessage\(\{defaultMessage:"(?:\\.|[^"\\])*",id:"'
        + re.escape(message_id)
        + r'"(?:,description:"(?:\\.|[^"\\])*")?\}\)'
    )
    search_start = 0
    while True:
        id_index = updated.find(needle, search_start)
        if id_index < 0:
            break

        window_start = max(0, id_index - 600)
        window_end = min(len(updated), id_index + 600)
        match = pattern.search(updated[window_start:window_end])
        if not match:
            search_start = id_index + len(needle)
            continue

        absolute_start = window_start + match.start()
        absolute_end = window_start + match.end()
        literal = json.dumps(target, ensure_ascii=False)
        updated = updated[:absolute_start] + literal + updated[absolute_end:]
        count += 1
        search_start = absolute_start + len(literal)

    return updated, count


def replace_menu_literal_length_preserving(text: str, source: str, target: str) -> tuple[str, int]:
    pattern = re.compile(
        r"(?P<prefix>(?<![A-Za-z0-9_$])(?:label|defaultMessage)\s*:\s*)"
        r'(?P<quote>["\'`])'
        + re.escape(source)
        + r"(?P=quote)"
    )

    def replace_match(match: re.Match[str]) -> str:
        original = match.group(0)
        quote = match.group("quote")
        replacement = f"{match.group('prefix')}{quote}{target}{quote}"
        byte_delta = len(original.encode("utf-8")) - len(replacement.encode("utf-8"))
        if byte_delta < 0:
            return original
        return replacement + (" " * byte_delta)

    return pattern.subn(replace_match, text)


def patch_length_preserving_main_process_menu_labels(app: Path, lang_code: str) -> None:
    path = app / APP_ASAR_REL
    replacements = get_main_process_menu_replacements(lang_code)

    asar = read_asar_file_content(app, ASAR_PATCH_TARGET)
    data = asar.data
    header_size = asar.header_size
    header = asar.header
    entry = asar.entry
    content_offset = 8 + header_size + int(entry["offset"])
    content_end = content_offset + int(entry["size"])

    content = asar.content
    text = content.decode("utf-8")
    patched = text
    count = 0
    for source, target in sorted(replacements.items(), key=lambda item: len(item[0]), reverse=True):
        patched, occurrences = replace_menu_literal_length_preserving(patched, source, target)
        count += occurrences

    patched_content = patched.encode("utf-8")
    if patched_content == content:
        print("Length-preserving main-process menu labels already patched")
        return
    if len(patched_content) != len(content):
        raise SystemExit("Internal patch error: length-preserving menu patch changed app.asar content length.")

    write_asar_content_in_place(app, data, header_size, header, entry, content_offset, content_end, patched_content)
    print(f"Patched length-preserving main-process menu labels: {count} replacements")


def patch_hardcoded_main_process_menu_labels(app: Path, lang_code: str) -> None:
    replacements = get_main_process_menu_replacements(lang_code)

    asar = read_asar_file_content(app, ASAR_PATCH_TARGET)
    content = asar.content
    text = content.decode("utf-8")
    patched = text
    count = 0
    intl_count = 0
    repair_count = 0
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

        def repair_match(match: re.Match[str]) -> str:
            quote = match.group("quote")
            return f"{quote}{target}{quote}"

        patched, occurrences = pattern.subn(repair_match, patched)
        repair_count += occurrences

    for message_id, target in get_main_process_menu_intl_replacements(lang_code).items():
        patched, occurrences = replace_menu_intl_message_by_id(patched, message_id, target)
        intl_count += occurrences

    for source, target in sorted(replacements.items(), key=lambda item: len(item[0]), reverse=True):
        if source not in patched:
            continue
        pattern = re.compile(
            r"(?P<prefix>(?<![A-Za-z0-9_$])(?:label|defaultMessage)\s*:\s*)"
            r'(?P<quote>["\'`])'
            + re.escape(source)
            + r"(?P=quote)"
        )

        def replace_match(match: re.Match[str]) -> str:
            quote = match.group("quote")
            return f"{match.group('prefix')}{quote}{target}{quote}"

        patched, occurrences = pattern.subn(replace_match, patched)
        count += occurrences

    if count == 0 and intl_count == 0 and repair_count == 0:
        print("Hardcoded main-process menu labels already patched")
        return

    patched_content = patched.encode("utf-8")
    replace_asar_file_content(app, ASAR_PATCH_TARGET, patched_content)
    if repair_count:
        print(f"Repaired unsafe short main-process menu replacements: {repair_count} occurrences")
    print(f"Patched hardcoded main-process menu labels: {count + intl_count} replacements")


def merge_frontend_locale(app: Path, lang_code: str) -> tuple[int, int, int]:
    config = get_language_config(lang_code)
    source = app / FRONTEND_I18N_REL / "en-US.json"
    target = app / FRONTEND_I18N_REL / f"{lang_code}.json"
    require_file(source)
    require_file(config["frontend_translation"])

    en = load_json(source)
    zh_pack = load_json(config["frontend_translation"])
    if not isinstance(en, dict) or not isinstance(zh_pack, dict):
        raise SystemExit("Unsupported frontend i18n JSON shape.")

    merged: dict[str, Any] = {}
    translated = 0
    fallback = 0
    for key, value in en.items():
        if key in zh_pack:
            merged[key] = zh_pack[key]
            if zh_pack[key] != value:
                translated += 1
        else:
            merged[key] = value
            fallback += 1

    save_json(target, merged)
    extra = len(set(zh_pack) - set(en))
    print(f"Installed frontend {lang_code}: {translated} translated, {fallback} fallback, {extra} extra old keys ignored")
    return translated, fallback, extra


def install_desktop_locale(app: Path, lang_code: str) -> None:
    config = get_language_config(lang_code)
    resources_dir = app / DESKTOP_RESOURCES_REL
    require_file(config["desktop_translation"])
    require_file(config["localizable_strings"])

    shutil.copy2(config["desktop_translation"], resources_dir / f"{lang_code}.json")
    for folder in [f"{lang_code}.lproj", f"{lang_code.replace('-', '_')}.lproj"]:
        out_dir = resources_dir / folder
        out_dir.mkdir(parents=True, exist_ok=True)
        shutil.copy2(config["localizable_strings"], out_dir / "Localizable.strings")
    print(f"Installed desktop shell {lang_code} resources")


def install_statsig_locale(app: Path, lang_code: str) -> None:
    config = get_language_config(lang_code)
    statsig_dir = app / FRONTEND_I18N_REL / "statsig"
    if not statsig_dir.exists():
        return
    target = statsig_dir / f"{lang_code}.json"
    bundled = config["statsig_translation"]
    if bundled.exists():
        shutil.copy2(bundled, target)
    elif (statsig_dir / "en-US.json").exists():
        shutil.copy2(statsig_dir / "en-US.json", target)
    print(f"Installed statsig {lang_code} resource")


def sign_path(path: Path, entitlements_dir: Path) -> None:
    entitlements = load_entitlements(path)
    if entitlements:
        entitlements.pop("com.apple.application-identifier", None)
        entitlements.pop("com.apple.developer.team-identifier", None)
        entitlements.pop("keychain-access-groups", None)
        # Ad-hoc signatures do not have a real Team ID. Under hardened runtime,
        # Electron's main process otherwise fails library validation when it loads
        # bundled frameworks, even when the whole bundle is signed consistently.
        entitlements["com.apple.security.cs.disable-library-validation"] = True

    cmd = [
        "codesign",
        "--force",
        "--sign",
        "-",
        "--options",
        "runtime",
        "--preserve-metadata=identifier,flags",
    ]
    if entitlements:
        entitlement_path = entitlements_dir / f"{abs(hash(path.as_posix()))}.plist"
        entitlement_path.write_bytes(plistlib.dumps(entitlements, fmt=plistlib.FMT_XML))
        cmd.extend(["--entitlements", str(entitlement_path)])
    cmd.append(str(path))

    result = run(cmd, check=False)
    if result.returncode != 0:
        print(result.stdout, end="")
        raise SystemExit(f"Failed to re-sign: {path}")


def is_signable_file(path: Path) -> bool:
    if path.is_symlink() or not path.is_file():
        return False
    if path.suffix in {".dylib", ".node", ".so"}:
        return True
    return os.access(path, os.X_OK)


def resign_app(app: Path) -> None:
    start = time.perf_counter()
    log("Re-signing patched app with local ad-hoc signature, preserving entitlements")
    contents = app / "Contents"
    entitlements_dir = Path(tempfile.mkdtemp(prefix="claude-zh-cn-entitlements."))
    bundle_targets: list[Path] = []
    file_targets: list[Path] = []

    for root, dirs, files in os.walk(contents):
        root_path = Path(root)
        for dirname in dirs:
            path = root_path / dirname
            if path.suffix in {".app", ".framework"}:
                bundle_targets.append(path)
        for filename in files:
            path = root_path / filename
            if is_signable_file(path):
                file_targets.append(path)

    # Sign nested Mach-O files first, then their containing bundles, then the outer app.
    log(f"  signing {len(file_targets)} executable files and {len(bundle_targets) + 1} bundles")
    sorted_file_targets = sorted(file_targets, key=lambda p: len(p.parts), reverse=True)
    for index, path in enumerate(sorted_file_targets, start=1):
        sign_path(path, entitlements_dir)
        if index % 25 == 0 or index == len(sorted_file_targets):
            log(f"  signed {index}/{len(sorted_file_targets)} executable files ({elapsed_since(start)})")
    sorted_bundle_targets = sorted(bundle_targets, key=lambda p: len(p.parts), reverse=True)
    for index, path in enumerate(sorted_bundle_targets, start=1):
        sign_path(path, entitlements_dir)
        if index % 10 == 0 or index == len(sorted_bundle_targets):
            log(f"  signed {index}/{len(sorted_bundle_targets)} nested bundles ({elapsed_since(start)})")
    sign_path(app, entitlements_dir)
    log(f"Re-signed patched app in {elapsed_since(start)}")


def clear_quarantine(app: Path) -> None:
    result = run(["xattr", "-dr", "com.apple.quarantine", str(app)], check=False)
    if result.returncode == 0:
        print("Cleared Gatekeeper quarantine attribute")


def set_user_locale(user_home: Path, lang_code: str) -> None:
    config = user_home / "Library/Application Support/Claude/config.json"
    config.parent.mkdir(parents=True, exist_ok=True)
    data: dict[str, Any] = {}
    if config.exists():
        try:
            data = load_json(config)
        except Exception:
            backup = config.with_suffix(".json.bak-invalid")
            shutil.copy2(config, backup)
            print(f"Existing config was not valid JSON; backed up to {backup}")
    data["locale"] = lang_code
    save_json(config, data)

    sudo_uid = os.environ.get("SUDO_UID")
    sudo_gid = os.environ.get("SUDO_GID")
    if sudo_uid and sudo_gid:
        os.chown(config, int(sudo_uid), int(sudo_gid))
    print(f"Set Claude config locale: {config}")


def chown_to_sudo_user(path: Path) -> None:
    sudo_uid = os.environ.get("SUDO_UID")
    sudo_gid = os.environ.get("SUDO_GID")
    if sudo_uid and sudo_gid and path.exists():
        os.chown(path, int(sudo_uid), int(sudo_gid))


def load_json_object_or_backup(path: Path, dry_run: bool = False) -> dict[str, Any]:
    if not path.exists():
        return {}
    try:
        data = load_json(path)
        if isinstance(data, dict):
            return data
        raise ValueError("JSON root is not an object")
    except Exception:
        backup = path.with_suffix(path.suffix + ".bak-invalid")
        if dry_run:
            print(f"[dry-run] Existing config is not valid JSON; would back up to {backup}")
        else:
            shutil.copy2(path, backup)
        return {}


def ensure_config_library_entry(meta: dict[str, Any], config_id: str) -> None:
    meta["appliedId"] = config_id
    entries = meta.get("entries")
    if not isinstance(entries, list):
        entries = []
        meta["entries"] = entries
    for entry in entries:
        if isinstance(entry, dict) and entry.get("id") == config_id:
            return
    entries.append({"id": config_id, "name": "Default"})


def set_third_party_auto_updates(user_home: Path, enabled: bool, dry_run: bool = False) -> bool:
    config_library = user_home / "Library/Application Support/Claude-3p/configLibrary"
    meta_path = config_library / "_meta.json"
    creating_library = not meta_path.exists()
    meta = load_json_object_or_backup(meta_path, dry_run=dry_run)
    applied_id = meta.get("appliedId")
    config_id = str(applied_id) if isinstance(applied_id, str) and applied_id.strip() else ""

    if not config_id:
        existing_configs = sorted(
            path for path in config_library.glob("*.json") if path.name != "_meta.json"
        )
        config_id = existing_configs[0].stem if existing_configs else str(uuid.uuid4())

    config_path = config_library / f"{config_id}.json"
    config = load_json_object_or_backup(config_path, dry_run=dry_run)
    config["disableAutoUpdates"] = not enabled
    ensure_config_library_entry(meta, config_id)

    state = "允许" if enabled else "禁止"
    if dry_run:
        action = "create and update" if creating_library else "update"
        print(f"[dry-run] Would {action} Claude-3p config and {state}自动更新: {config_path}")
        return True

    save_json(config_path, config)
    save_json(meta_path, meta)
    chown_to_sudo_user(config_path)
    chown_to_sudo_user(meta_path)

    print("允许更新成功" if enabled else "禁止更新成功")
    return True


def read_skill_frontmatter(skill_md: Path) -> dict[str, str]:
    text = skill_md.read_text(encoding="utf-8")
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return {}

    end = None
    for index, line in enumerate(lines[1:], start=1):
        if line.strip() == "---":
            end = index
            break
    if end is None:
        return {}

    data: dict[str, str] = {}
    key = ""
    value_lines: list[str] = []

    def flush() -> None:
        nonlocal key, value_lines
        if key:
            data[key] = "\n".join(line.strip() for line in value_lines).strip()
        key = ""
        value_lines = []

    for raw_line in lines[1:end]:
        if not raw_line.strip():
            if key and value_lines:
                value_lines.append("")
            continue
        if raw_line[:1].isspace():
            if key:
                value_lines.append(raw_line.strip())
            continue
        match = re.match(r"^([A-Za-z0-9_-]+):(?:\s*(.*))?$", raw_line)
        if not match:
            continue
        flush()
        key = match.group(1)
        value = (match.group(2) or "").strip()
        value_lines = [value] if value else []
    flush()
    return data


def discover_cc_switch_skills(skills_dir: Path) -> list[dict[str, Any]]:
    if not skills_dir.exists():
        raise SystemExit(f"CC Switch skills directory not found: {skills_dir}")
    if not skills_dir.is_dir():
        raise SystemExit(f"CC Switch skills path is not a directory: {skills_dir}")

    skills: list[dict[str, Any]] = []
    for path in sorted(skills_dir.iterdir(), key=lambda item: item.name):
        if not path.is_dir():
            continue
        skill_md = path / "SKILL.md"
        if not skill_md.is_file():
            continue
        frontmatter = read_skill_frontmatter(skill_md)
        name = frontmatter.get("name", "").strip() or path.name
        if not name:
            continue
        if "/" in name or "\\" in name or name in {".", ".."}:
            print(f"Invalid skill name, skipped: {name}")
            continue
        description = frontmatter.get("description", "").strip()
        skills.append({"name": name, "description": description, "path": path})
    return skills


def find_claude_desktop_skills_plugin_root(user_home: Path) -> Path:
    base = user_home / "Library/Application Support/Claude-3p/local-agent-mode-sessions/skills-plugin"
    if not base.exists():
        raise SystemExit(f"Claude Desktop skills-plugin directory not found: {base}")

    candidates: list[Path] = []
    for org_dir in sorted(base.iterdir(), key=lambda item: item.name):
        if not org_dir.is_dir():
            continue
        for plugin_dir in sorted(org_dir.iterdir(), key=lambda item: item.name):
            if (
                plugin_dir.is_dir()
                and (plugin_dir / "manifest.json").is_file()
                and (plugin_dir / "skills").is_dir()
            ):
                candidates.append(plugin_dir)

    if not candidates:
        raise SystemExit(f"No Claude Desktop skills plugin root found under: {base}")
    return max(candidates, key=lambda path: (path / "manifest.json").stat().st_mtime)


def load_skills_manifest(manifest_path: Path, dry_run: bool = False) -> dict[str, Any]:
    data = load_json_object_or_backup(manifest_path, dry_run=dry_run)
    skills = data.get("skills")
    if not isinstance(skills, list):
        data["skills"] = []
    return data


def sync_cc_switch_skills(user_home: Path, skills_dir: Path, dry_run: bool = False) -> bool:
    plugin_root = find_claude_desktop_skills_plugin_root(user_home)
    desktop_skills_dir = plugin_root / "skills"
    manifest_path = plugin_root / "manifest.json"
    manifest = load_skills_manifest(manifest_path, dry_run=dry_run)
    manifest_skills = manifest["skills"]
    existing_manifest_names = {
        str(item.get("name"))
        for item in manifest_skills
        if isinstance(item, dict) and isinstance(item.get("name"), str)
    }

    cc_skills = discover_cc_switch_skills(skills_dir)
    now = dt.datetime.now(dt.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
    added = 0
    skipped = 0

    print(f"Claude Desktop skills plugin: {plugin_root}")
    print(f"CC Switch skills source: {skills_dir}")

    for skill in cc_skills:
        name = str(skill["name"])
        source = Path(skill["path"])
        target = desktop_skills_dir / name

        if target.exists() or target.is_symlink() or name in existing_manifest_names:
            print(f"已存在，跳过: {name}")
            skipped += 1
            continue

        print(f"{'[dry-run] Would sync' if dry_run else '同步'}: {name} -> {source}")
        if not dry_run:
            os.symlink(source, target, target_is_directory=True)
        manifest_skills.append(
            {
                "skillId": name,
                "name": name,
                "description": str(skill["description"]),
                "creatorType": "user",
                "syncManaged": False,
                "updatedAt": now,
                "enabled": True,
            }
        )
        existing_manifest_names.add(name)
        added += 1

    if added:
        manifest["lastUpdated"] = int(time.time() * 1000)
        backup = manifest_path.with_name("manifest.json.bak-before-cc-switch-sync")
        if dry_run:
            print(f"[dry-run] Would back up manifest to: {backup}")
            print(f"[dry-run] Would update manifest: {manifest_path}")
        else:
            shutil.copy2(manifest_path, backup)
            chown_to_sudo_user(backup)
            save_json(manifest_path, manifest)
            chown_to_sudo_user(manifest_path)

    print(f"同步完成：新增 {added} 个，跳过 {skipped} 个。")
    if dry_run:
        print("[dry-run] 未写入任何文件。")
    return True


def path_is_within(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


def unsync_cc_switch_skills(user_home: Path, skills_dir: Path, dry_run: bool = False) -> bool:
    plugin_root = find_claude_desktop_skills_plugin_root(user_home)
    desktop_skills_dir = plugin_root / "skills"
    manifest_path = plugin_root / "manifest.json"
    manifest = load_skills_manifest(manifest_path, dry_run=dry_run)
    manifest_skills = manifest["skills"]
    cc_skills = discover_cc_switch_skills(skills_dir)
    cc_root = skills_dir.resolve()
    removed_names: set[str] = set()
    skipped = 0

    print(f"Claude Desktop skills plugin: {plugin_root}")
    print(f"CC Switch skills source: {skills_dir}")

    for skill in cc_skills:
        name = str(skill["name"])
        target = desktop_skills_dir / name
        if not target.is_symlink():
            print(f"不是 CC Switch 同步软链接，跳过: {name}")
            skipped += 1
            continue

        try:
            resolved_target = target.resolve(strict=False)
        except OSError:
            print(f"无法解析软链接，跳过: {target}")
            skipped += 1
            continue

        if not path_is_within(resolved_target, cc_root):
            print(f"软链接目标不在 CC Switch skills 目录内，跳过: {name}")
            skipped += 1
            continue

        print(f"{'[dry-run] Would remove sync' if dry_run else '删除同步'}: {name} -> {resolved_target}")
        if not dry_run:
            target.unlink()
        removed_names.add(name)

    if removed_names:
        kept_skills = [
            item
            for item in manifest_skills
            if not (
                isinstance(item, dict)
                and isinstance(item.get("name"), str)
                and item.get("name") in removed_names
            )
        ]
        removed_manifest_count = len(manifest_skills) - len(kept_skills)
        manifest["skills"] = kept_skills
        manifest["lastUpdated"] = int(time.time() * 1000)
        backup = manifest_path.with_name("manifest.json.bak-before-cc-switch-sync")
        if dry_run:
            print(f"[dry-run] Would remove {removed_manifest_count} manifest entries")
            print(f"[dry-run] Would back up manifest to: {backup}")
            print(f"[dry-run] Would update manifest: {manifest_path}")
        else:
            shutil.copy2(manifest_path, backup)
            chown_to_sudo_user(backup)
            save_json(manifest_path, manifest)
            chown_to_sudo_user(manifest_path)
        print(f"取消同步完成：删除 {len(removed_names)} 个软链接，删除 {removed_manifest_count} 条 manifest 记录，跳过 {skipped} 个。")
    else:
        print(f"取消同步完成：删除 0 个，跳过 {skipped} 个。")

    if dry_run:
        print("[dry-run] 未写入任何文件。")
    return True


def backup_and_replace(original: Path, patched: Path, dry_run: bool) -> Path:
    start = time.perf_counter()
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    backup = original.with_name(f"Claude.backup-before-zh-CN-{stamp}.app")
    if dry_run:
        print(f"[dry-run] Would move {original} -> {backup}")
        print(f"[dry-run] Would move {patched} -> {original}")
        return backup

    log(f"Backing up current app: {backup}")
    shutil.move(str(original), str(backup))
    log(f"Installing patched app: {original}")
    shutil.move(str(patched), str(original))
    log(f"Replaced app in {elapsed_since(start)}")
    return backup


def remove_path(path: Path) -> None:
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
    else:
        path.unlink()


def find_app_backups(app: Path) -> list[Path]:
    return sorted(path for path in app.parent.glob(BACKUP_GLOB) if path.is_dir())


def restore_oldest_backup(app: Path, dry_run: bool) -> Path:
    backups = find_app_backups(app)
    if not backups:
        raise SystemExit(f"No Claude backup found in {app.parent}: {BACKUP_GLOB}")

    backup = backups[0]
    extra_backups = backups[1:]
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    current_tmp = app.with_name(f"Claude.restore-current-{stamp}.app")

    if dry_run:
        if app.exists():
            print(f"[dry-run] Would move current app {app} -> {current_tmp}")
        print(f"[dry-run] Would restore oldest backup {backup} -> {app}")
        for extra_backup in extra_backups:
            print(f"[dry-run] Would delete extra backup: {extra_backup}")
        return backup

    if app.exists():
        print(f"Moving current app aside: {current_tmp}")
        shutil.move(str(app), str(current_tmp))

    try:
        print(f"Restoring oldest backup: {backup}")
        shutil.move(str(backup), str(app))
    except Exception:
        if current_tmp.exists() and not app.exists():
            shutil.move(str(current_tmp), str(app))
        raise

    if current_tmp.exists():
        print(f"Removing replaced app: {current_tmp}")
        remove_path(current_tmp)
    for extra_backup in extra_backups:
        print(f"Deleting extra backup: {extra_backup}")
        remove_path(extra_backup)
    return backup


def verify(app: Path, lang_code: str) -> None:
    start = time.perf_counter()
    frontend = app / FRONTEND_I18N_REL / f"{lang_code}.json"
    data = load_json(frontend)
    values = [v for v in data.values() if isinstance(v, str)]
    chinese = sum(1 for v in values if re.search(r"[\u4e00-\u9fff]", v))
    print(f"Verified frontend {lang_code} JSON: {chinese}/{len(values)} strings contain Chinese")

    verify_result = run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)], check=False)
    if verify_result.returncode == 0:
        print("Verified app signature")
    else:
        print("App signature verification failed:")
        print(verify_result.stdout, end="")

    entitlements = read_entitlements(app)
    if "com.apple.security.virtualization" in entitlements:
        print("Verified virtualization entitlement")
    else:
        print("Warning: virtualization entitlement is missing")

    result = run(["codesign", "-dv", str(app)], check=False).stdout
    for line in result.splitlines():
        if line.startswith("TeamIdentifier="):
            print(line)
    log(f"Verification finished in {elapsed_since(start)}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Patch Claude Desktop with Chinese language resources.")
    parser.add_argument("--app", type=Path, default=APP_DEFAULT, help="Path to Claude.app")
    parser.add_argument("--user-home", type=Path, default=Path.home(), help="Home directory whose Claude config should be updated")
    parser.add_argument("--lang", choices=["zh-CN", "zh-TW", "zh-HK"], default="zh-CN", help="Language code to install (default: zh-CN)")
    parser.add_argument("--dry-run", action="store_true", help="Prepare and verify a patched temp app, but do not replace /Applications/Claude.app")
    parser.add_argument("--launch", action="store_true", help="Launch Claude after installation")
    parser.add_argument("--restore", action="store_true", help="Restore the oldest macOS app backup and delete other backups")
    parser.add_argument("--skip-asar-patch", action="store_true", help="Skip app.asar and binary integrity patches (safe mode)")
    parser.add_argument(
        "--set-auto-updates",
        choices=["enabled", "disabled"],
        help="Only update Claude-3p auto-update setting, then exit",
    )
    parser.add_argument(
        "--sync-cc-switch-skills",
        action="store_true",
        help="Link missing CC Switch skills into Claude Desktop and update the skills manifest, then exit",
    )
    parser.add_argument(
        "--unsync-cc-switch-skills",
        action="store_true",
        help="Remove CC Switch skill symlinks from Claude Desktop and update the skills manifest, then exit",
    )
    parser.add_argument(
        "--cc-switch-skills-dir",
        type=Path,
        help="CC Switch skills directory (default: USER_HOME/.cc-switch/skills)",
    )
    args = parser.parse_args()

    if args.set_auto_updates:
        set_third_party_auto_updates(
            args.user_home,
            enabled=args.set_auto_updates == "enabled",
            dry_run=args.dry_run,
        )
        return 0

    if args.sync_cc_switch_skills:
        sync_cc_switch_skills(
            args.user_home,
            args.cc_switch_skills_dir or args.user_home / ".cc-switch/skills",
            dry_run=args.dry_run,
        )
        return 0

    if args.unsync_cc_switch_skills:
        unsync_cc_switch_skills(
            args.user_home,
            args.cc_switch_skills_dir or args.user_home / ".cc-switch/skills",
            dry_run=args.dry_run,
        )
        return 0

    try:
        in_applications = args.app.resolve().as_posix().startswith("/Applications/")
    except Exception:
        in_applications = str(args.app).startswith("/Applications/")
    if os.geteuid() != 0 and in_applications and not args.dry_run:
        print("This usually needs sudo because /Applications is protected.", file=sys.stderr)

    if args.restore:
        if args.dry_run:
            print("[dry-run] Claude will not be quit.")
        else:
            quit_claude()
        restored = restore_oldest_backup(args.app, args.dry_run)
        if args.dry_run:
            print(f"[dry-run] Would set Claude config locale under: {args.user_home} to en-US")
        else:
            set_user_locale(args.user_home, "en-US")
            print(f"Restored from backup: {restored}")
            if args.launch:
                run(["open", "-a", str(args.app)], check=False)
        print("Done. Claude Desktop has been restored to the oldest backup.")
        return 0

    lang_code = args.lang
    config = get_language_config(lang_code)
    label = config["label"]

    require_file(config["frontend_translation"])
    require_file(config["frontend_hardcoded"])
    require_file(config["desktop_translation"])
    require_file(config["localizable_strings"])
    if not args.app.exists():
        raise SystemExit(f"Claude.app not found: {args.app}")
    require_virtualization_entitlement(args.app)

    if args.dry_run:
        print("[dry-run] Claude will not be quit.")
    else:
        quit_claude()
    tmp_root = Path(tempfile.mkdtemp(prefix=f"claude-{lang_code}-patch."))
    patched_app = tmp_root / "Claude.app"

    copy_app(args.app, patched_app)
    patch_language_whitelist(patched_app, lang_code)
    patch_hardcoded_frontend_strings(patched_app, lang_code)
    patch_language_display_names(patched_app)
    if args.skip_asar_patch:
        print("Skipping online claude.ai locale preload patch (--skip-asar-patch)")
    else:
        patch_online_locale_preload(patched_app, lang_code)
        patch_online_locale_main_process(patched_app, lang_code)
    if args.skip_asar_patch:
        print("Applying length-preserving main-process menu label patch (--skip-asar-patch)")
        patch_length_preserving_main_process_menu_labels(patched_app, lang_code)
    else:
        patch_hardcoded_main_process_menu_labels(patched_app, lang_code)
    if args.skip_asar_patch:
        print("Skipping 3P model validation patch (--skip-asar-patch)")
    else:
        patch_custom3p_model_validation(patched_app)
    merge_frontend_locale(patched_app, lang_code)
    install_desktop_locale(patched_app, lang_code)
    install_statsig_locale(patched_app, lang_code)
    resign_app(patched_app)
    clear_quarantine(patched_app)
    if args.dry_run:
        print(f"[dry-run] Would set Claude config locale under: {args.user_home}")
    else:
        set_user_locale(args.user_home, lang_code)
    verify(patched_app, lang_code)

    backup = backup_and_replace(args.app, patched_app, args.dry_run)
    if not args.dry_run:
        print(f"Backup kept at: {backup}")
        if args.launch:
            run(["open", "-a", str(args.app)], check=False)

    print(f"Done. Select Language -> {label} in Claude if it is not already selected.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
