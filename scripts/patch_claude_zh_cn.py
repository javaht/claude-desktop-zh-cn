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
from pathlib import Path
from typing import Any


APP_DEFAULT = Path("/Applications/Claude.app")
ROOT = Path(__file__).resolve().parent.parent
RESOURCES = ROOT / "resources"
BACKUP_GLOB = "Claude.backup-before-zh-CN-*.app"

APP_ASAR_REL = Path("Contents/Resources/app.asar")
FRONTEND_I18N_REL = Path("Contents/Resources/ion-dist/i18n")
FRONTEND_ASSETS_REL = Path("Contents/Resources/ion-dist/assets/v1")
FRONTEND_PROBE_NEEDLE = '"en-US","de-DE","fr-FR","ko-KR","ja-JP"'
DESKTOP_RESOURCES_REL = Path("Contents/Resources")
ASAR_INTEGRITY_BLOCK_SIZE = 4 * 1024 * 1024
# 纯小写单词（hours、tokens、matches……）在打包后的 JS 里几乎都是对象键、枚举值或
# 状态值，而不是可见文案；静态替换会改坏程序逻辑（例如用量图表按 "tokens" 取指标，
# 被改成 "令牌" 后读 undefined.daily 使会话页整页崩溃）。这类词条只走在线 DOM 翻译。
STRUCTURAL_JS_IDENTIFIER_RE = re.compile(r"[a-z][A-Za-z0-9_]*")
# 结构性字面量跳过列表：兼作图标名、按键映射、事件后缀、枚举值或核心标识符的高危单词（#193, #204, #205, #206）。
# 这些短词在前端 bundle 中几乎都承担程序逻辑（图标字形查询、按键事件处理、动画状态、无障碍节点判断等），
# 真正的可见文案全部由官方 i18n（React Intl defaultMessage）映射翻译，静态替换只会破坏运行时。
STRUCTURAL_JS_LITERAL_REPLACEMENTS = {
    '"Search"',
    "Search",
    '"Add"',
    "Add",
    '"Copy"',
    "Copy",
    '"Check"',
    "Check",
    '"Tasks"',
    "Tasks",
    '"Settings"',
    "Settings",
    '"Command"',
    "Command",
    '"Cancel"',
    "Cancel",
    '"Sort"',
    "Sort",
    '"Voice"',
    "Voice",
    '"Default"',
    "Default",
    '"Arguments"',
    "Arguments",
    '"Normal"',
    "Normal",
    '"All"',
    "All",
    '"Application"',
    "Application",
    '"Medium"',
    "Medium",
    '"Motion"',
    "Motion",
    '"Thinking"',
    "Thinking",
    '"Verbose"',
    "Verbose",
}
# 结构上下文保护：除 KEY:"X" 直接形式外，还需覆盖压缩代码里同样把值当图标名/枚举名
# 使用的写法（缺一不可，否则字符串被译成中文后按名查图标表失败，按钮渲染成空白方块）：
#   icon:i="Add"            解构默认值
#   icon:f?"Add":void 0     三元第一分支（条件可含 ===、void 0 等，如 icon:t===void 0?）
#   icon:d?"Check":"Copy"   三元第二分支（允许嵌套链 icon:a?"B":c?"Check":"Copy"）
#   icon:e.length===0?"A":"B"  复杂条件
#   icon:c}=e;h=c===void 0?"Add":c  解构别名默认值与空值合并（#204）
# 键名用 [\w$-]*[Ii]con(?:Name)? 覆盖 Icon、primaryActionCompactIcon、openIcon、
# triggerIcon 等大小写与复合形态。条件原子排除 ? : , ; { } 与引号（引号仅允许成对的
# 短字符串），避免吞掉后续属性导致紧跟其后的 title:"X" 等正常文案被误保护。
_STRUCTURAL_COND = (
    r"(?:(?:[^?:\"'`,;{}]|\"[^\"]{0,60}\"|'[^']{0,60}'|`[^`]{0,60}`){1,120}?)"
)
_STRUCTURAL_QUOTED = r"(?:\"[^\"]{0,80}\"|'[^']{0,80}'|`[^`]{0,80}`)"
STRUCTURAL_JS_LITERAL_CONTEXT_RE = re.compile(
    r"(?<![A-Za-z0-9_$-])"
    r"(?:as|component|displayName|glyph|[\w$-]*[Ii]con(?:Name)?|name|role|type)"
    r"\s*[:=]\s*"
    r"(?:(?:"
    + _STRUCTURAL_COND
    + r"\?\??\s*"
    + _STRUCTURAL_QUOTED
    + r"\s*:\s*)*)"
    r"(?:"
    + _STRUCTURAL_COND
    + r"(?:\?\??)?\s*)?(?:=\s*)?$"
)
STRUCTURAL_JS_ALIAS_CONTEXT_RE = re.compile(
    r"(?<![A-Za-z0-9_$-])[\w$-]*[Ii]con(?:Name)?\s*:\s*(?P<alias>[A-Za-z0-9_$]+)\b"
    r".*?"
    r"(?:=\s*(?P=alias)\s*===\s*void 0\s*\?\s*"
    r"|=\s*(?P=alias)\s*!==\s*void 0\s*\?\s*(?P=alias)\s*:\s*"
    r"|(?<![A-Za-z0-9_$-])(?P=alias)\s*\?\?\s*)$"
)


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
            "zh-TW": "繁體中文（台灣）",
            "zh-HK": "繁體中文（香港）",
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
    stdout = result.stdout.rstrip(b"\x00")
    if result.returncode != 0 or not stdout.strip():
        return {}
    try:
        data = plistlib.loads(stdout)
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


def find_frontend_assets_dir(app: Path) -> Path | None:
    """Locate the frontend JS bundle directory under the app.

    已知布局（Claude 2.x 至 2.31226.1）是 Contents/Resources/ion-dist/assets/v1；
    新版本若改名或换层级，则在 ion-dist 下递归查找：优先返回命中语言白名单锚点
    的目录（前端主 bundle），其次含 index-*.js 的目录，避免误选 worker 等辅助
    JS 目录（issue #196 同类风险的 Mac 侧防线）。
    """
    known = app / FRONTEND_ASSETS_REL
    if any(known.glob("*.js")):
        return known

    ion_dist = app / "Contents/Resources/ion-dist"
    if not ion_dist.is_dir():
        return None

    needle_hits: list[Path] = []
    index_dirs: list[Path] = []
    for js_path in sorted(ion_dist.rglob("*.js")):
        if not js_path.is_file():
            continue
        if js_path.name.startswith("index-") and js_path.parent not in index_dirs:
            index_dirs.append(js_path.parent)
        if js_path.parent not in needle_hits:
            try:
                if FRONTEND_PROBE_NEEDLE in js_path.read_text(encoding="utf-8"):
                    needle_hits.append(js_path.parent)
            except (OSError, UnicodeDecodeError):
                continue

    if needle_hits:
        return needle_hits[0]
    if index_dirs:
        return index_dirs[0]
    return None


def patch_language_whitelist(app: Path, lang_code: str) -> Path:
    assets_dir = find_frontend_assets_dir(app)
    if assets_dir is None:
        raise SystemExit(
            f"Cannot find frontend JS bundle under {app / 'Contents/Resources/ion-dist'} "
            f"(looked for {FRONTEND_ASSETS_REL} and any index bundle with the language whitelist)"
        )
    candidates = sorted(assets_dir.glob("*.js"))

    replacement = f'{BASE_LANGUAGE_LIST},"{lang_code}"]'

    for path in candidates:
        text = path.read_text(encoding="utf-8")
        if LANG_LIST_RE.search(text):
            # Claude 2.9939.2 起同一 bundle 内有多份语言白名单（导航语言解析与
            # 语言可用性校验各一份），必须全部补上，漏一份该路径就会把 zh 回退
            # 成 en-US。正则会吞掉已存在的 zh 项，重复运行是幂等的。
            patched, occurrences = LANG_LIST_RE.subn(replacement, text)
            path.write_text(patched, encoding="utf-8")
            print(f"Patched language whitelist: {path.name} ({occurrences} occurrence(s))")
            return path

    raise SystemExit("Could not patch language whitelist. Claude's bundle format may have changed.")


def patch_language_display_names(app: Path) -> None:
    assets_dir = find_frontend_assets_dir(app)
    if assets_dir is None:
        raise SystemExit(
            f"Cannot find frontend JS bundle under {app / 'Contents/Resources/ion-dist'}"
        )
    candidates = sorted(assets_dir.glob("index-*.js"))
    if not candidates:
        raise SystemExit(f"Cannot find frontend index bundle in {assets_dir}")

    marker = "__claudeZhLabelPatch"
    patch = ';(()=>{const e=Intl.DisplayNames&&Intl.DisplayNames.prototype;if(!e||e.__claudeZhLabelPatch)return;const n=e.of;e.of=function(e){const t=String(e);return t==="zh-CN"?"简体中文":t==="zh-HK"?"繁體中文（香港）":t==="zh-TW"?"繁體中文（台灣）":n.call(this,e)},Object.defineProperty(e,"__claudeZhLabelPatch",{value:!0})})();'
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


def is_structural_js_literal_context(text: str, literal_start: int) -> bool:
    prefix = text[max(0, literal_start - 160) : literal_start]
    if STRUCTURAL_JS_ALIAS_CONTEXT_RE.search(prefix) is not None:
        return True
    short_prefix = prefix[-96:] if len(prefix) > 96 else prefix
    return STRUCTURAL_JS_LITERAL_CONTEXT_RE.search(short_prefix) is not None


def replace_frontend_hardcoded_text(
    text: str,
    source: str,
    target: str,
    pattern: re.Pattern[str] | None = None,
) -> tuple[str, int]:
    if STRUCTURAL_JS_IDENTIFIER_RE.fullmatch(source) or source in STRUCTURAL_JS_LITERAL_REPLACEMENTS:
        return text, 0

    if not is_plain_ui_text_replacement(source):
        count = text.count(source)
        if count:
            text = text.replace(source, target)
        return text, count

    if pattern is None:
        pattern = re.compile(r'(?P<quote>["\'`])' + re.escape(source) + r"(?P=quote)")
    replacement_count = 0

    def replace_match(match: re.Match[str]) -> str:
        nonlocal replacement_count
        if is_structural_js_literal_context(text, match.start()):
            return match.group(0)
        replacement_count += 1
        quote = match.group("quote")
        return f"{quote}{target}{quote}"

    return pattern.sub(replace_match, text), replacement_count


_WORKER_RULES: list[tuple[str, str, "re.Pattern[str] | None"]] = []


def _prepare_hardcoded_rules(
    replacement_items: list[tuple[str, str]],
) -> list[tuple[str, str, "re.Pattern[str] | None"]]:
    return [
        (
            source,
            target,
            re.compile(r'(?P<quote>["\'`])' + re.escape(source) + r"(?P=quote)")
            if is_plain_ui_text_replacement(source)
            else None,
        )
        for source, target in replacement_items
        if not (
            STRUCTURAL_JS_IDENTIFIER_RE.fullmatch(source)
            or source in STRUCTURAL_JS_LITERAL_REPLACEMENTS
        )
    ]


def _init_patch_worker(replacement_items: list[tuple[str, str]]) -> None:
    global _WORKER_RULES
    _WORKER_RULES = _prepare_hardcoded_rules(replacement_items)


def _patch_frontend_file(path_str: str) -> tuple[bool, int]:
    path = Path(path_str)
    text = path.read_text(encoding="utf-8")
    # 任何替换（引号包裹或直接替换）都要求原文至少出现一次，粗筛可跳过绝大多数无命中文件。
    if not any(source in text for source, _, _ in _WORKER_RULES):
        return False, 0
    patched = text
    count = 0
    for source, target, pattern in _WORKER_RULES:
        patched, occurrences = replace_frontend_hardcoded_text(patched, source, target, pattern)
        if occurrences:
            count += occurrences
    if patched != text:
        path.write_text(patched, encoding="utf-8")
        return True, count
    return False, 0


def patch_hardcoded_frontend_strings(app: Path, lang_code: str) -> None:
    start = time.perf_counter()
    assets_dir = find_frontend_assets_dir(app)
    if assets_dir is None:
        raise SystemExit(
            f"Cannot find frontend JS bundle under {app / 'Contents/Resources/ion-dist'}"
        )
    replacement_items = sorted(
        load_frontend_hardcoded_replacements(lang_code),
        key=lambda item: len(item[0]),
        reverse=True,
    )
    js_files = sorted(assets_dir.glob("*.js"))
    total_files = len(js_files)

    log(
        "Scanning frontend JS for hardcoded strings: "
        f"{total_files} files, {len(replacement_items)} replacement rules"
    )

    patched_files = 0
    patched_strings = 0

    def report(index: int) -> None:
        if index % 50 == 0 or index == total_files:
            log(
                "  scanned "
                f"{index}/{total_files} JS files, "
                f"{patched_strings} replacements so far ({elapsed_since(start)})"
            )

    pool = None
    results = None
    workers = min(os.cpu_count() or 1, 12)
    if workers > 1 and total_files > 64:
        try:
            from concurrent.futures import ProcessPoolExecutor

            # 文件互相独立，可并行；大文件先派发以均衡各 worker 负载。
            # 子进程启动/任务提交可能因受限环境失败，整体回退单进程；
            # 而迭代结果阶段的工作异常仍会照常抛出终止安装。
            by_size = sorted(js_files, key=lambda p: p.stat().st_size, reverse=True)
            pool = ProcessPoolExecutor(
                max_workers=workers,
                initializer=_init_patch_worker,
                initargs=(replacement_items,),
            )
            results = pool.map(_patch_frontend_file, (str(p) for p in by_size), chunksize=1)
        except Exception as exc:
            log(f"Parallel scan unavailable ({type(exc).__name__}: {exc}); falling back to single process")
            if pool is not None:
                pool.shutdown(wait=False, cancel_futures=True)
            pool = None
            results = None

    if pool is not None and results is not None:
        try:
            for index, (file_patched, count) in enumerate(results, start=1):
                patched_files += int(file_patched)
                patched_strings += count
                report(index)
        finally:
            pool.shutdown()
    else:
        _init_patch_worker(replacement_items)
        for index, path in enumerate(js_files, start=1):
            file_patched, count = _patch_frontend_file(str(path))
            patched_files += int(file_patched)
            patched_strings += count
            report(index)

    log(
        "Patched hardcoded frontend strings: "
        f"{patched_strings} replacements in {patched_files} files ({elapsed_since(start)})"
    )


def load_slash_command_gloss_config(lang_code: str) -> tuple[dict[str, Any], dict[str, str]]:
    profile = load_json(RESOURCES / "slash-command-menu-patch.json")
    labels = load_json(RESOURCES / "slash-command-glosses.json")[lang_code]
    if not isinstance(labels, dict) or not labels or any(
        not re.fullmatch(r"[a-z][a-z0-9-]*", key)
        or not isinstance(value, str) or not value.strip()
        for key, value in labels.items()
    ):
        raise ValueError("Invalid slash command gloss catalog")
    return profile, labels


def _slash_gloss_replacement(match: re.Match[str], profile: dict[str, Any], patched: bool = False) -> str:
    original = match.group(0).split(":", 1)[1].lstrip()
    if patched:
        original = original[1:]
    values = {"__ORIGINAL__": original, "__ITEM__": match.group(3), "__JSX__": match.group(1)}
    return re.sub(r"__ORIGINAL__|__ITEM__|__JSX__", lambda token: values[token.group(0)], profile["replacement"])


def replace_slash_command_menu_text(
    text: str, profile: dict[str, Any], labels: dict[str, str]
) -> tuple[str, str]:
    """只修改真实菜单行的显示层，不修改 label、命令 ID、搜索和点击回调。"""
    if not re.search(profile["module_pattern"], text):
        raise ValueError("SlashCommandMenuPopupBody export not found")
    marker = profile["marker"]
    encoded = json.dumps(labels, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    encoded = encoded.replace("\u2028", "\\u2028").replace("\u2029", "\\u2029")
    suffix = "\n" + marker + profile["suffix"].replace("__LABELS__", encoded)
    if marker in text:
        if text.count(marker) != 1 or "\n" + marker not in text:
            raise ValueError("Ambiguous slash command gloss marker")
        body, tail = text.split("\n" + marker, 1)
        left, right = profile["suffix"].split("__LABELS__", 1)
        if not tail.startswith(left) or not tail.endswith(right):
            raise ValueError("Unrecognized existing slash command helper")
        try:
            previous_labels = json.loads(tail[len(left):len(tail) - len(right)])
        except json.JSONDecodeError as exc:
            raise ValueError("Invalid existing slash command catalog") from exc
        pattern = profile["anchor_pattern"].replace("children:", r"children:\[", 1)
        matches = list(re.finditer(pattern, body))
        if len(matches) != 1:
            raise ValueError("Existing slash menu row is missing or ambiguous")
        replacement = _slash_gloss_replacement(matches[0], profile, patched=True)
        start = matches[0].start()
        if body[start:start + len(replacement)] != replacement:
            raise ValueError("Existing slash menu row does not match the patch")
        if previous_labels == labels:
            return text, "already"
        return body + suffix, "updated"

    if "__claudeZhSlashGloss" in text or "__claudeZhSlashLabels" in text:
        raise ValueError("Slash command helper name already exists")
    matches = list(re.finditer(profile["anchor_pattern"], text))
    if len(matches) != 1:
        raise ValueError("Expected exactly one slash menu label anchor")
    match = matches[0]
    if not re.search(re.escape(match.group(3)) + r'\.type\s*===\s*"skill"', text):
        raise ValueError("Slash menu skill row not found")
    updated = text[:match.start()] + _slash_gloss_replacement(match, profile) + text[match.end():]
    return updated + suffix, "updated"


def patch_slash_command_menu(app: Path, lang_code: str) -> int:
    assets_dir = find_frontend_assets_dir(app)
    if assets_dir is None:
        log("WARNING: Slash command gloss skipped: frontend assets not found")
        return 0
    profile, labels = load_slash_command_gloss_config(lang_code)
    candidates = []
    for path in sorted(assets_dir.glob("*.js")):
        text = path.read_text(encoding="utf-8")
        if re.search(profile["module_pattern"], text):
            candidates.append((path, text))
    if len(candidates) != 1:
        log("WARNING: Slash command gloss skipped: expected one menu component")
        return 0
    path, text = candidates[0]
    try:
        updated, status = replace_slash_command_menu_text(text, profile, labels)
    except ValueError as exc:
        log(f"WARNING: Slash command gloss skipped: {exc}")
        return 0
    if status == "already":
        log(f"Slash command gloss already installed: {path.name}")
        return 0
    path.write_text(updated, encoding="utf-8")
    log(f"Patched bilingual slash command menu ({lang_code}): {path.name}")
    return 1


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


def install_dynamic_locale(app: Path, lang_code: str) -> None:
    dynamic_dir = app / FRONTEND_I18N_REL / "dynamic"
    source = dynamic_dir / "en-US.json"
    if not source.exists():
        # Claude < 2.9939.2 没有 dynamic 目录，无需处理。
        return
    # 2.9939.2 起 dynamic catalog 与主语言包一起强制加载（fetch 非 2xx 直接抛错），
    # 缺失会让整个 zh 语言包加载失败并回退英文。其 key 是内容哈希，随包词表暂无
    # 对应翻译，先按官方 en-US 原文兜底，保证加载不失败。
    shutil.copy2(source, dynamic_dir / f"{lang_code}.json")
    print(f"Installed frontend dynamic {lang_code} resource")


def app_bundle_identifier(app: Path) -> str | None:
    """Return CFBundleIdentifier of *app*, or None when it cannot be read."""
    info_plist = app / "Contents/Info.plist"
    try:
        with info_plist.open("rb") as f:
            plist = plistlib.load(f)
        value = plist.get("CFBundleIdentifier")
        return value if isinstance(value, str) and value else None
    except Exception:
        return None


def sign_path(
    path: Path,
    entitlements_dir: Path,
    *,
    hardened_runtime: bool = True,
    force_get_task_allow: bool = False,
    designated_requirement: str | None = None,
) -> None:
    entitlements = load_entitlements(path)
    if entitlements is None:
        entitlements = {}
    if entitlements or force_get_task_allow:
        entitlements.pop("com.apple.application-identifier", None)
        entitlements.pop("com.apple.developer.team-identifier", None)
        entitlements.pop("keychain-access-groups", None)
        # Ad-hoc signatures do not have a real Team ID. Under hardened runtime,
        # Electron's main process otherwise fails library validation when it loads
        # bundled frameworks, even when the whole bundle is signed consistently.
        entitlements["com.apple.security.cs.disable-library-validation"] = True
        if force_get_task_allow:
            # Required for Frida/task_for_pid against this process under SIP.
            entitlements["com.apple.security.get-task-allow"] = True
            entitlements.setdefault("com.apple.security.cs.allow-jit", True)

    cmd = [
        "codesign",
        "--force",
        "--sign",
        "-",
        "--timestamp=none",
    ]
    if hardened_runtime:
        cmd.extend(["--options", "runtime", "--preserve-metadata=identifier,flags"])
    if entitlements:
        entitlement_path = entitlements_dir / f"{abs(hash(path.as_posix()))}.plist"
        entitlement_path.write_bytes(plistlib.dumps(entitlements, fmt=plistlib.FMT_XML))
        cmd.extend(["--entitlements", str(entitlement_path)])
    if designated_requirement:
        cmd.extend(["-r", f"=designated => {designated_requirement}"])
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


def _collect_sign_targets(app: Path) -> tuple[list[Path], list[Path]]:
    contents = app / "Contents"
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
    return file_targets, bundle_targets


def resign_app(app: Path) -> None:
    start = time.perf_counter()
    log("Re-signing patched app with local ad-hoc signature, preserving entitlements")
    entitlements_dir = Path(tempfile.mkdtemp(prefix="claude-zh-cn-entitlements."))
    file_targets, bundle_targets = _collect_sign_targets(app)

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
    # ShipIt validates downloaded updates against the installed app's designated
    # requirement. The ad-hoc default DR is a cdhash pin that no official update
    # can satisfy, which is why patched apps silently never install updates.
    # An identifier-only DR is satisfied by any official Claude release, so
    # auto-update keeps working (the update replaces the patch with the
    # official app; re-run the patch afterwards).
    bundle_id = app_bundle_identifier(app)
    if bundle_id:
        sign_path(app, entitlements_dir, designated_requirement=f'identifier "{bundle_id}"')
    else:
        log("  warning: CFBundleIdentifier not found; keeping default ad-hoc DR (auto-update will not install)")
        sign_path(app, entitlements_dir)
    log(f"Re-signed patched app in {elapsed_since(start)}")


def codesign_info(app: Path) -> dict[str, Any]:
    """Return a small codesign summary for *app* (best-effort)."""
    result = run(["codesign", "-dv", "--verbose=4", str(app)], check=False)
    text = (result.stdout or "") + (result.stderr or "")
    flags = ""
    for line in text.splitlines():
        if "flags=" in line:
            flags = line.split("flags=", 1)[-1].strip()
            break
    entitlements = load_entitlements(app) or {}
    return {
        "flags": flags,
        "adhoc": "adhoc" in flags or "Signature=adhoc" in text or "Signature=adhoc" in (result.stderr or ""),
        "hardened_runtime": "runtime" in flags,
        "get_task_allow": bool(entitlements.get("com.apple.security.get-task-allow")),
        "entitlements": entitlements,
        "raw": text,
    }










def clear_quarantine(app: Path) -> None:
    result = run(["xattr", "-dr", "com.apple.quarantine", str(app)], check=False)
    if result.returncode == 0:
        print("Cleared Gatekeeper quarantine attribute")


def set_user_locale(user_home: Path, lang_code: str) -> None:
    """Write locale into Claude (+ Claude-3p if present) user config."""
    targets = [
        user_home / "Library/Application Support/Claude/config.json",
        user_home / "Library/Application Support/Claude-3p/config.json",
    ]
    sudo_uid = os.environ.get("SUDO_UID")
    sudo_gid = os.environ.get("SUDO_GID")
    if not (sudo_uid and sudo_gid) and os.geteuid() == 0:
        # macOS `do shell script ... with administrator privileges` does not
        # provide SUDO_UID/GID; preserve the owner of the requested home.
        owner = user_home.stat()
        sudo_uid, sudo_gid = str(owner.st_uid), str(owner.st_gid)

    for config in targets:
        if config.name.startswith("Claude-3p") and not config.parent.exists():
            continue
        config.parent.mkdir(parents=True, exist_ok=True)
        data: dict[str, Any] = {}
        if config.exists():
            try:
                data = load_json(config)
                if not isinstance(data, dict):
                    data = {}
            except Exception:
                backup = config.with_suffix(".json.bak-invalid")
                shutil.copy2(config, backup)
                print(f"Existing config was not valid JSON; backed up to {backup}")
                data = {}
        if data.get("locale") == lang_code:
            print(f"Claude config locale already {lang_code}: {config}")
            continue
        data["locale"] = lang_code
        save_json(config, data)
        os.chmod(config, 0o600)
        if sudo_uid and sudo_gid:
            os.chown(config, int(sudo_uid), int(sudo_gid))
        print(f"Set Claude config locale: {config} -> {lang_code}")




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


def get_existing_third_party_config(user_home: Path, dry_run: bool = False) -> tuple[Path, Path, dict[str, Any]] | None:
    config_library = user_home / "Library/Application Support/Claude-3p/configLibrary"
    meta_path = config_library / "_meta.json"
    if not meta_path.exists():
        return None

    meta = load_json_object_or_backup(meta_path, dry_run=dry_run)
    applied_id = meta.get("appliedId")
    config_id = str(applied_id) if isinstance(applied_id, str) and applied_id.strip() else ""
    if not config_id:
        return None

    config_path = config_library / f"{config_id}.json"
    if not config_path.exists():
        return None

    return meta_path, config_path, meta


def set_third_party_config_auto_updates(user_home: Path, enabled: bool, dry_run: bool = False) -> bool:
    existing = get_existing_third_party_config(user_home, dry_run=dry_run)
    if existing is None:
        return False

    meta_path, config_path, meta = existing
    config = load_json_object_or_backup(config_path, dry_run=dry_run)
    config["disableAutoUpdates"] = not enabled
    ensure_config_library_entry(meta, config_path.stem)

    state = "允许" if enabled else "禁止"
    if dry_run:
        print(f"[dry-run] Would update Claude-3p config and {state}自动更新: {config_path}")
        return True

    save_json(config_path, config)
    save_json(meta_path, meta)
    chown_to_sudo_user(config_path)
    chown_to_sudo_user(meta_path)

    print("允许更新成功" if enabled else "禁止更新成功")
    return True


def managed_preferences_user_name(user_home: Path) -> str:
    sudo_user = os.environ.get("SUDO_USER")
    if sudo_user and sudo_user != "root":
        return sudo_user
    return user_home.name


def set_macos_managed_auto_updates(user_home: Path, enabled: bool, dry_run: bool = False) -> bool:
    user_name = managed_preferences_user_name(user_home)
    plist_path = Path("/Library/Managed Preferences") / user_name / "com.anthropic.claudefordesktop.plist"
    data: dict[str, Any] = {}
    if plist_path.exists():
        try:
            with plist_path.open("rb") as f:
                loaded = plistlib.load(f)
            if isinstance(loaded, dict):
                data = loaded
            else:
                raise ValueError("plist root is not a dictionary")
        except Exception:
            backup = plist_path.with_suffix(plist_path.suffix + ".bak-invalid")
            if dry_run:
                print(f"[dry-run] Existing managed plist is invalid; would back up to {backup}")
            else:
                shutil.copy2(plist_path, backup)

    state = "允许" if enabled else "禁止"
    plist_existed = plist_path.exists()
    if enabled:
        data.pop("disableAutoUpdates", None)
    else:
        data["disableAutoUpdates"] = True

    if dry_run:
        action = "remove disableAutoUpdates from" if enabled else "write disableAutoUpdates=true to"
        print(f"[dry-run] Would {action} Claude Desktop managed policy and {state}自动更新: {plist_path}")
        return True

    if enabled and not plist_existed:
        print("允许更新成功")
        print(f"Claude Desktop managed policy was already absent: {plist_path}")
        return True

    plist_path.parent.mkdir(parents=True, exist_ok=True)
    with plist_path.open("wb") as f:
        plistlib.dump(data, f, sort_keys=True)
    os.chmod(plist_path, 0o644)
    print("允许更新成功" if enabled else "禁止更新成功")
    print(f"Updated Claude Desktop managed policy: {plist_path}")
    return True


def set_auto_updates(user_home: Path, enabled: bool, dry_run: bool = False) -> bool:
    if set_third_party_config_auto_updates(user_home, enabled=enabled, dry_run=dry_run):
        return True
    return set_macos_managed_auto_updates(user_home, enabled=enabled, dry_run=dry_run)


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


def bundle_version(app: Path) -> str:
    """Return the app bundle version, or "0" when it cannot be read."""
    info_plist = app / "Contents/Info.plist"
    try:
        with info_plist.open("rb") as f:
            info = plistlib.load(f)
    except Exception:
        return "0"
    for key in ("CFBundleShortVersionString", "CFBundleVersion"):
        value = info.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return "0"


def version_key(value: str) -> tuple[int, ...]:
    """Numeric sort key for versions like "1.2" or "1.46388.3"."""
    parts = [int(part) for part in re.findall(r"\d+", value)]
    return tuple(parts + [0] * (3 - len(parts)))


def _official_signature(info: dict[str, Any]) -> bool:
    """Classify a codesign_info() result as an unpatched official build."""
    if info.get("adhoc"):
        return False
    return "Authority=Developer ID Application" in info.get("raw", "")


def is_officially_signed(app: Path) -> bool:
    """True when *app* still carries its official Developer ID signature.

    The patcher always re-signs with an ad-hoc signature, so a non-official
    signature means the on-disk app was patched (or Frida-prepared) by this
    toolchain and only a backup restore brings back clean official resources.
    Anything unreadable counts as non-official to stay conservative.
    """
    try:
        return _official_signature(codesign_info(app))
    except Exception:
        return False


def preinstall_should_restore(app: Path) -> bool:
    """True when the installed app needs a backup restore before re-patching.

    Auto-update replaces the patched app with an official build, so an
    officially signed install is never restored: restoring would downgrade
    Claude to a stale backup and delete the fresh version (issue #156).
    """
    return not (app.exists() and is_officially_signed(app))


def select_backup(backups: list[Path]) -> Path:
    """Pick the backup with the highest bundled version (name as tie-breaker).

    Restoring the oldest backup could downgrade Claude below the currently
    installed version; the highest-version backup is the safest official
    snapshot to fall back to.
    """
    return max(backups, key=lambda path: (version_key(bundle_version(path)), path.name))


def prune_stale_backups(app: Path, keep: Path, dry_run: bool) -> None:
    """Delete all zh-CN app backups except *keep*."""
    for path in find_app_backups(app):
        if path == keep:
            continue
        if dry_run:
            print(f"[dry-run] Would delete stale backup: {path}")
            continue
        print(f"Deleting stale backup: {path}")
        remove_path(path)


def restore_backup(app: Path, dry_run: bool) -> Path:
    backups = find_app_backups(app)
    if not backups:
        raise SystemExit(f"No Claude backup found in {app.parent}: {BACKUP_GLOB}")

    backup = select_backup(backups)
    extra_backups = [path for path in backups if path != backup]
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    current_tmp = app.with_name(f"Claude.restore-current-{stamp}.app")

    if dry_run:
        if app.exists():
            print(f"[dry-run] Would move current app {app} -> {current_tmp}")
        print(f"[dry-run] Would restore backup {backup} -> {app}")
        for extra_backup in extra_backups:
            print(f"[dry-run] Would delete extra backup: {extra_backup}")
        return backup

    if app.exists():
        print(f"Moving current app aside: {current_tmp}")
        shutil.move(str(app), str(current_tmp))

    try:
        print(f"Restoring backup: {backup}")
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


def verify_electron_asar_integrity(app: Path) -> None:
    asar_path = app / APP_ASAR_REL
    data = asar_path.read_bytes()
    _header_size, header_string, _header = read_asar_header(data, asar_path)
    expected = hashlib.sha256(header_string.encode("utf-8")).hexdigest()

    info_plist = app / "Contents/Info.plist"
    with info_plist.open("rb") as f:
        info = plistlib.load(f)
    actual = (
        info.get("ElectronAsarIntegrity", {})
        .get("Resources/app.asar", {})
        .get("hash")
    )
    if actual != expected:
        raise SystemExit(
            "Electron app.asar integrity mismatch: "
            f"Info.plist has {actual!r}, expected {expected}."
        )
    print("Verified Electron app.asar integrity")




def verify(app: Path, lang_code: str) -> None:
    start = time.perf_counter()
    frontend = app / FRONTEND_I18N_REL / f"{lang_code}.json"
    data = load_json(frontend)
    values = [v for v in data.values() if isinstance(v, str)]
    chinese = sum(1 for v in values if re.search(r"[\u4e00-\u9fff]", v))
    print(f"Verified frontend {lang_code} JSON: {chinese}/{len(values)} strings contain Chinese")

    dynamic_dir = app / FRONTEND_I18N_REL / "dynamic"
    if (dynamic_dir / "en-US.json").exists():
        if not (dynamic_dir / f"{lang_code}.json").exists():
            raise SystemExit(
                f"Missing required dynamic i18n catalog: {dynamic_dir / f'{lang_code}.json'}; "
                "Claude >= 2.9939.2 fails to load the language without it."
            )
        print(f"Verified frontend dynamic {lang_code} catalog exists")

    verify_electron_asar_integrity(app)

    verify_result = run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)], check=False)
    if verify_result.returncode == 0:
        print("Verified app signature")
    else:
        print("App signature verification failed:")
        print(verify_result.stdout, end="")
        raise SystemExit("Refusing to install an app with an invalid signature.")

    entitlements = read_entitlements(app)
    if "com.apple.security.virtualization" in entitlements:
        print("Verified virtualization entitlement")
    else:
        raise SystemExit("Virtualization entitlement is missing after re-signing.")

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
    parser.add_argument("--restore", action="store_true", help="Restore the latest macOS app backup and delete other backups")
    parser.add_argument(
        "--restore-if-backup-exists",
        action="store_true",
        help="Before install, restore the latest app backup when the installed app is patched; skip when it is an official build",
    )
    parser.add_argument(
        "--skip-asar-patch",
        action="store_true",
        help="Deprecated and ignored: this localization no longer modifies app.asar",
    )
    parser.add_argument(
        "--set-auto-updates",
        choices=["enabled", "disabled"],
        help="Only update Claude Desktop auto-update setting, then exit",
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
        set_auto_updates(
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
        restored = restore_backup(args.app, args.dry_run)
        if args.dry_run:
            print(f"[dry-run] Would set Claude config locale under: {args.user_home} to en-US")
        else:
            set_user_locale(args.user_home, "en-US")
            print(f"Restored from backup: {restored}")
            if args.launch:
                run(["open", "-a", str(args.app)], check=False)
        print("Done. Claude Desktop has been restored from the latest backup.")
        return 0

    if args.restore_if_backup_exists:
        if not find_app_backups(args.app):
            print(f"No Claude backup found in {args.app.parent}: {BACKUP_GLOB}; skipping pre-install restore.")
            return 0
        if not preinstall_should_restore(args.app):
            # Auto-update replaces the patched app with an official build, so a
            # lingering backup is stale here. Restoring it would downgrade Claude
            # and delete the fresh version (issue #156); patch this app directly.
            print(
                f"Officially signed app detected: {args.app} "
                f"(version {bundle_version(args.app)}); skipping pre-install restore."
            )
            return 0
        if args.dry_run:
            print("[dry-run] Claude will not be quit.")
        else:
            quit_claude()
        restored = restore_backup(args.app, args.dry_run)
        if not args.dry_run:
            print(f"Restored from backup before install: {restored}")
        print("Done. Existing Chinese patch has been cleared before install.")
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
    patch_slash_command_menu(patched_app, lang_code)
    patch_language_display_names(patched_app)
    merge_frontend_locale(patched_app, lang_code)
    install_desktop_locale(patched_app, lang_code)
    install_statsig_locale(patched_app, lang_code)
    install_dynamic_locale(patched_app, lang_code)
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
        prune_stale_backups(args.app, keep=backup, dry_run=False)
        if args.launch:
            run(["open", "-a", str(args.app)], check=False)

    print(f"Done. Select Language -> {label} in Claude if it is not already selected.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
