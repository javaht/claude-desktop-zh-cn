#!/usr/bin/env python3
"""验证新增英文短语在三种中文词表的 DOM 翻译映射中全部命中。

用法:
  python3 skills/claude-desktop-zh-localize/scripts/verify_mapping.py "Phrase one" "Phrase two"
  cat phrases.txt | python3 skills/claude-desktop-zh-localize/scripts/verify_mapping.py

检查内容（zh-CN / zh-TW / zh-HK 各跑一遍）:
  1. 每个短语都能在 build_online_translation_map() 中命中（即会被在线 DOM 翻译）。
  2. frontend-zh-*.json 中不存在 en-US.json 里没有的历史废弃键（应为 0）。

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


def main() -> int:
    app = Path(os.environ.get("CLAUDE_APP", "/Applications/Claude.app"))
    if not app.exists():
        print(f"Claude.app not found: {app}")
        return 2

    phrases = collect_phrases()
    failed = False
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
