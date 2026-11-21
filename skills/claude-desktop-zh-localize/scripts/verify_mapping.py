#!/usr/bin/env python3
"""验证新增英文短语在三种中文词表的 DOM 翻译映射中全部命中。

用法:
  python3 skills/claude-desktop-zh-localize/scripts/verify_mapping.py "Phrase one" "Phrase two"
  cat phrases.txt | python3 skills/claude-desktop-zh-localize/scripts/verify_mapping.py

检查内容（zh-CN / zh-TW / zh-HK 各跑一遍）:
  1. 每个短语都能在 build_online_translation_map() 中命中（即会被在线 DOM 翻译）。
  2. frontend-zh-*.json 中不存在 en-US.json 里没有的历史废弃键（应为 0）。
  3. 三地 frontend-zh-*.json 与 frontend-hardcoded-zh-*.json 中的 `**粗体**`
     都满足 CommonMark 左右界规则（设置页长文由 react-markdown 渲染，
     `**未设置：**Chat` 这类写法不会加粗）。

环境变量 CLAUDE_APP 可覆盖应用路径（默认 /Applications/Claude.app）。
有未命中的短语时退出码为 1。
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts"))

import patch_claude_zh_cn as patcher  # noqa: E402


def collect_phrases() -> list[str]:
    args = sys.argv[1:]
    if args:
        return [a for a in args if a.strip()]
    if not sys.stdin.isatty():
        return [line.strip() for line in sys.stdin if line.strip()]
    print(__doc__)
    raise SystemExit(2)


_CJK_PUNCT = "：:。，、；！？…）】》」』”’"


def _is_punct(ch: str) -> bool:
    import re

    return bool(re.match(r"[!-/:-@\[-`{-~　-〿＀-￯]", ch)) or ch in _CJK_PUNCT


def _bad_bold_pairs(text: str) -> list[str]:
    """Return fragments whose ** pair fails CommonMark flanking rules."""
    import re

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
    import json

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

    app = Path(os.environ.get("CLAUDE_APP", "/Applications/Claude.app"))
    if not app.exists():
        print(f"Claude.app not found: {app}")
        return 1 if failed else 2

    phrases = collect_phrases()
    for lang in ["zh-CN", "zh-TW", "zh-HK"]:
        mapping = patcher.build_online_translation_map(app, lang)
        missing = [p for p in phrases if not mapping.get(p)]
        if missing:
            failed = True
            print(f"[{lang}] MISSING ({len(missing)}):")
            for p in missing:
                print(f"  - {p!r}")
        else:
            print(f"[{lang}] ALL {len(phrases)} PHRASES MAPPED (total {len(mapping)})")

        en = patcher.load_json(app / patcher.FRONTEND_I18N_REL / "en-US.json")
        zh = patcher.load_json(patcher.get_language_config(lang)["frontend_translation"])
        extra = len(set(zh.keys()) - set(en.keys()))
        print(f"[{lang}] legacy keys ignored = {extra}")
        if extra:
            failed = True

    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
