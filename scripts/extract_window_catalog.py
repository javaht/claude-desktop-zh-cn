#!/usr/bin/env python3
"""生成桌面独立窗口词表 ``resources/desktop-extra-zh-*.json``。

第三方推理配置窗口（``/setup-desktop-3p``）由前端 chunk 渲染，但窗口里的
``IntlProvider`` 消息来自 preload 暴露的壳层词表；这些前端消息 id 不在壳层
en-US 词表里，只能回退英文。本脚本从原版前端资源中定位该路由的 chunk，
沿静态 import 求模块闭包，收集其中所有 ``defaultMessage``/``id``，再套用
仓库前端词表译文，生成三地补充词表。

用法:
    python3 scripts/extract_window_catalog.py --resources <resources 目录> [--write]

``--resources`` 指向 Claude Desktop 的 ``resources`` 目录（含 ``ion-dist.asar``
或 ``ion-dist`` 目录）。不带 ``--write`` 时只打印统计。
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import patch_claude_zh_cn as patcher  # noqa: E402

ROUTE = "setup-desktop-3p"
LANGS = ("CN", "TW", "HK")
STATIC_IMPORT_RE = re.compile(r'from"\./([^"]+)"')
MESSAGE_RE = re.compile(r'defaultMessage:"((?:[^"\\]|\\.)*)",id:"([^"]+)"')
ROUTE_IMPORT_RE = re.compile(
    r'path:"' + re.escape(ROUTE) + r'",component:[^}]*?import\("\./([^"]+)"\)'
)
HAN_RE = re.compile(r"[一-鿿]")


class Source:
    """Read JS files from an asar archive or an unpacked directory."""

    def __init__(self, resources: Path):
        asar = resources / "ion-dist.asar"
        if asar.is_file():
            data = asar.read_bytes()
            header_size, _string, header = patcher.read_asar_header(data, asar)
            self._names = {
                path.rsplit("/", 1)[-1]: path for path, _entry in patcher.walk_asar_entries(header)
            }
            self._data = data
            self._header_size = header_size
            self._header = header
            self._root = None
        else:
            directory = resources / "ion-dist"
            if not directory.is_dir():
                raise SystemExit(f"未找到前端资源：{asar} 或 {directory}")
            self._names = {path.name: path for path in directory.rglob("*.js")}
            self._root = directory
            self._data = None

    def names(self) -> list[str]:
        return sorted(self._names)

    def read(self, name: str) -> str | None:
        path = self._names.get(name)
        if path is None:
            return None
        if self._root is not None:
            return path.read_text(encoding="utf-8", errors="replace")
        payload = patcher.read_asar_entry(self._data, self._header_size, self._header, path)
        return payload.decode("utf-8", "replace") if payload is not None else None


def find_route_chunk(source: Source) -> str:
    for name in source.names():
        text = source.read(name)
        if text and "path:\"" + ROUTE + "\"" in text:
            match = ROUTE_IMPORT_RE.search(text)
            if match:
                return match.group(1)
    raise SystemExit(f"未在页面入口中找到 {ROUTE} 的 chunk")


def collect_messages(source: Source, entry: str) -> dict[str, str]:
    """按静态 import 闭包收集消息 id；先出现的 defaultMessage 为准。"""
    seen: set[str] = set()
    pending = [entry]
    messages: dict[str, str] = {}
    while pending:
        name = pending.pop()
        if name in seen:
            continue
        seen.add(name)
        text = source.read(name)
        if text is None:
            continue
        for value, key in MESSAGE_RE.findall(text):
            messages.setdefault(key, json.loads('"' + value + '"'))
        pending.extend(m for m in STATIC_IMPORT_RE.findall(text) if m not in seen)
    return messages


def build_extra(lang: str, messages: dict[str, str]) -> dict[str, str]:
    frontend = patcher.load_json(patcher.RESOURCES / f"frontend-zh-{lang}.json")
    desktop = patcher.load_json(patcher.RESOURCES / f"desktop-zh-{lang}.json")
    extra = {}
    for key, source in messages.items():
        value = frontend.get(key)
        if not isinstance(value, str) or not value.strip():
            continue
        # 未翻译条目与原文相同；硬编码替换可能已把原文改成中文，不能再用它覆盖。
        if value == source:
            continue
        if not HAN_RE.search(value):
            continue
        if key in desktop:
            continue
        extra[key] = value
    return dict(sorted(extra.items()))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--resources", type=Path, required=True, help="Claude Desktop 的 resources 目录")
    parser.add_argument("--write", action="store_true", help="写入 resources/desktop-extra-zh-*.json")
    args = parser.parse_args()

    source = Source(args.resources.resolve())
    entry = find_route_chunk(source)
    messages = collect_messages(source, entry)
    print(f"路由 {ROUTE} 的 chunk: {entry}，消息 id {len(messages)} 个")

    for lang in LANGS:
        extra = build_extra(lang, messages)
        print(f"  desktop-extra-zh-{lang}.json: {len(extra)} 条")
        if args.write:
            target = patcher.RESOURCES / f"desktop-extra-zh-{lang}.json"
            target.write_text(
                json.dumps(extra, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
            )
            print(f"    已写入 {target}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
