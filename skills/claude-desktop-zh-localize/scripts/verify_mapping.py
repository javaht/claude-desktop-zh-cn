#!/usr/bin/env python3
"""验证新增英文短语在三种中文词表里是否会被翻译。

用法:
  python3 skills/claude-desktop-zh-localize/scripts/verify_mapping.py "Phrase one" "Phrase two"
  cat phrases.txt | python3 skills/claude-desktop-zh-localize/scripts/verify_mapping.py

检查内容（zh-CN / zh-TW / zh-HK 各跑一遍）:
  1. 每个短语能命中翻译，命中来源分两类：
     - hardcoded：短语是 frontend-hardcoded-zh-*.json 的源文，安装时静态替换 bundle；
     - i18n：短语是应用 en-US 词表里某个 key 的值，且对应中文词表有不同译文。
  2. 三地 frontend-zh-*.json 与 frontend-hardcoded-zh-*.json 中的 `**粗体**`
     都满足 CommonMark 左右界规则（设置页长文由 react-markdown 渲染，
     `**未设置：**Chat` 这类写法不会加粗）。
  3. 词表里保留的旧版本 key 只报告数量，不算失败（供旧版 Claude 使用）。

应用路径按 CLAUDE_APP 覆盖；否则依次尝试 Linux 的 ~/.local/lib/claude-desktop、
/usr/lib/claude-desktop 和 macOS 的 /Applications/Claude.app。应用不存在时只跑
hardcoded 与粗体检查，退出码 2 表示“未完整验证”。

退出码：0 全部通过；1 有未命中/粗体失效；2 无法完整验证（缺应用或无短语）。
"""
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(os.environ.get("CLAUDE_ZH_REPO", Path(__file__).resolve().parents[3]))
sys.path.insert(0, str(ROOT / "scripts"))

import patch_claude_zh_cn as patcher  # noqa: E402

FRONTEND_EN_REL = "i18n/en-US.json"
LANGS = ("zh-CN", "zh-TW", "zh-HK")


def collect_phrases() -> list[str]:
    args = sys.argv[1:]
    if args:
        return [a for a in args if a.strip()]
    if not sys.stdin.isatty():
        return [line.strip() for line in sys.stdin if line.strip()]
    print(__doc__)
    raise SystemExit(2)


def find_app() -> Path | None:
    override = os.environ.get("CLAUDE_APP")
    if override:
        path = Path(override)
        return path if path.exists() else None
    for candidate in (
        Path.home() / ".local/lib/claude-desktop",
        Path("/usr/lib/claude-desktop"),
        Path("/Applications/Claude.app"),
    ):
        if candidate.exists():
            return candidate
    return None


def load_frontend_en(app: Path) -> dict[str, str] | None:
    """Read the installed app's en-US frontend catalog (loose dir or asar)."""
    roots = (app / "resources", app / "Contents/Resources", app)
    for root in roots:
        for sub in ("ion-dist", ""):
            candidate = root / sub / FRONTEND_EN_REL if sub else root / FRONTEND_EN_REL
            if candidate.is_file():
                return patcher.load_json(candidate)
    for root in roots:
        asar = root / "ion-dist.asar"
        if not asar.is_file():
            continue
        data = asar.read_bytes()
        header_size, _, header = patcher.read_asar_header(data, asar)
        payload = patcher.read_asar_entry(data, header_size, header, FRONTEND_EN_REL)
        if payload:
            return json.loads(payload)
    return None


def _js_source_to_text(text: str) -> str:
    """Turn a JS source-form string (\\n, \\", \\u2026) into its runtime value."""

    def replace(match: re.Match[str]) -> str:
        esc = match.group(1)
        if esc == "n":
            return "\n"
        if esc == "t":
            return "\t"
        if esc == "r":
            return "\r"
        if esc in ('"', "'", "`", "\\"):
            return esc
        if esc.startswith("u") and len(esc) == 5:
            try:
                return chr(int(esc[1:], 16))
            except ValueError:
                return esc
        if esc.startswith("x") and len(esc) == 3:
            try:
                return chr(int(esc[1:], 16))
            except ValueError:
                return esc
        return esc

    return re.sub(r"\\(u[0-9a-fA-F]{4}|x[0-9a-fA-F]{2}|.)", replace, text)


def load_catalogs(lang: str) -> tuple[dict[str, str], dict[str, str], set[str]]:
    code = {"zh-CN": "CN", "zh-TW": "TW", "zh-HK": "HK"}[lang]
    catalog_dir = ROOT / "resources"
    frontend = patcher.load_json(catalog_dir / f"frontend-zh-{code}.json")
    hardcoded_pairs = patcher.load_json(catalog_dir / f"frontend-hardcoded-zh-{code}.json")
    hardcoded = {
        _js_source_to_text(source): target
        for source, target in hardcoded_pairs
        if isinstance(source, str) and isinstance(target, str)
    }
    return frontend, hardcoded, set(hardcoded)


_CJK_PUNCT = "：:。，、；！？…）】》」』”’"


def _is_punct(ch: str) -> bool:
    return bool(re.match(r"[!-/:-@\[-`{-~　-〿＀-￯]", ch)) or ch in _CJK_PUNCT


def _bad_bold_pairs(text: str) -> list[str]:
    """Return fragments whose ** pair fails CommonMark flanking rules."""
    bad = []
    for line in re.split(r"\\n|\n", text):
        pos = [m.start() for m in re.finditer(r"\*\*", line)]
        for k in range(0, len(pos) - 1, 2):
            op, cl = pos[k], pos[k + 1]
            ob = line[op - 1] if op > 0 else " "
            oa = line[op + 2] if op + 2 < len(line) else " "
            cb, ca = line[cl - 1], line[cl + 2] if cl + 2 < len(line) else " "

            def left(b: str, a: str) -> bool:
                if a in " \t":
                    return False
                return (b in " \t" or _is_punct(b)) if _is_punct(a) else True

            def right(b: str, a: str) -> bool:
                if b in " \t":
                    return False
                return (a in " \t" or _is_punct(a)) if _is_punct(b) else True

            if not (left(ob, oa) and right(cb, ca)):
                bad.append(line[max(0, op - 10) : cl + 12])
    return bad


def check_bold_flanking() -> bool:
    """Audit ** bold markers in all three frontend/hardcoded catalogs."""
    ok = True
    for name in ("frontend-zh", "frontend-hardcoded-zh"):
        for lang in ("CN", "TW", "HK"):
            path = ROOT / "resources" / f"{name}-{lang}.json"
            data = json.loads(path.read_text(encoding="utf-8"))
            values = (
                [(k, v) for k, v in data.items() if isinstance(v, str)]
                if isinstance(data, dict)
                else [(f"#{i}", t) for i, pair in enumerate(data) for t in pair if isinstance(t, str)]
            )
            bad = [(k, frags) for k, v in values if "**" in v and (frags := _bad_bold_pairs(v))]
            if bad:
                ok = False
                print(f"[bold] {path.name}: {len(bad)} value(s) with broken **bold**")
                for k, frags in bad[:5]:
                    print(f"  - {k}: {frags[0]!r}")
    if ok:
        print("[bold] all **bold** markers flank correctly")
    return ok


def main() -> int:
    failed = not check_bold_flanking()
    phrases = collect_phrases()

    app = find_app()
    en = load_frontend_en(app) if app else None
    if app is not None and en is None:
        print(f"[app] 未能从 {app} 读取 {FRONTEND_EN_REL}（asar 或目录布局）")
    elif app is None:
        print("[app] 未找到 Claude 安装目录，i18n key 反查跳过（仅查 hardcoded）")

    en_index: dict[str, list[str]] = {}
    for key, value in (en or {}).items():
        if isinstance(value, str):
            en_index.setdefault(value, []).append(key)

    complete = en is not None
    for lang in LANGS:
        frontend, hardcoded, hardcoded_sources = load_catalogs(lang)
        missing = []
        for phrase in phrases:
            if phrase in hardcoded_sources:
                print(f"[{lang}] hardcoded: {phrase!r}")
                continue
            keys = en_index.get(phrase, [])
            translated = [k for k in keys if frontend.get(k) and frontend[k] != phrase]
            if translated:
                print(f"[{lang}] i18n: {phrase!r} -> {', '.join(translated[:3])}")
                continue
            missing.append(phrase)
        if missing:
            if complete:
                failed = True
                print(f"[{lang}] MISSING ({len(missing)}):")
                for phrase in missing:
                    print(f"  - {phrase!r}")
            else:
                print(f"[{lang}] UNCHECKED ({len(missing)}): {', '.join(repr(p) for p in missing[:5])}")
        elif complete:
            print(f"[{lang}] ALL {len(phrases)} PHRASES MAPPED")

        if en is not None:
            extra = len(set(frontend) - set(en))
            print(f"[{lang}] catalog keys not in this app version: {extra}（保留给旧版本，忽略即可）")

    if not complete:
        return 1 if failed else 2
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
