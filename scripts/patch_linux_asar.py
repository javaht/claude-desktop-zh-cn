#!/usr/bin/env python3
"""为 Linux 版 Claude Desktop 安装中文前端词表。

支持官方 deb 包与 claude-desktop-rpm（Fedora 等 RPM 发行版）共用的两种布局：

* Claude 4.29+：前端打包在 ``resources/ion-dist.asar``，脚本先解包到临时目录，
  合并词表、注册语言白名单后重新打包（Linux 的 Electron 不校验 asar 完整性，
  也没有 Info.plist，因此不需要重签名）。
* 更早版本：``resources/ion-dist/`` 是普通目录，直接在临时副本上修改后输出。

桌面壳层词库不改写：Claude 5.x 的 ``app.asar`` 已自带官方的 zh-Hans / zh-Hant
词库，前端只需补上自己的词表并使用同一个语言代码。

用法:
    python3 patch_linux_asar.py --resources <resources 目录> --lang zh-CN \
        --output /path/to/ion-dist.asar
    python3 patch_linux_asar.py --resources <resources 目录> --check-patched
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import patch_claude_zh_cn as patcher  # noqa: E402

TARGET_CODES = {
    "zh-CN": "zh-Hans",
    "zh-TW": "zh-Hant",
    "zh-HK": "zh-Hant",
}
PATCHED_CODES = ("zh-Hans", "zh-Hant")


def log(message: str) -> None:
    print(message, flush=True)


def find_frontend_bundle(resources: Path) -> tuple[str, Path]:
    asar = resources / "ion-dist.asar"
    directory = resources / "ion-dist"
    if asar.is_file():
        return "asar", asar
    if directory.is_dir() and any(directory.rglob("*.js")):
        return "directory", directory
    raise SystemExit(
        f"未找到前端资源：{asar} 或包含 JS 的 {directory}。\n"
        "Claude Desktop 的目录结构可能已变化，请携带版本号反馈。"
    )


def is_patched(resources: Path) -> bool:
    mode, bundle = find_frontend_bundle(resources)
    if mode == "directory":
        return any((bundle / "i18n" / f"{code}.json").exists() for code in PATCHED_CODES)
    data = bundle.read_bytes()
    _size, _header_string, header = patcher.read_asar_header(data, bundle)
    paths = {relative for relative, _entry in patcher.walk_asar_entries(header)}
    return any(f"i18n/{code}.json" in paths for code in PATCHED_CODES)


def merge_catalog(base_path: Path, overlay_path: Path, target_path: Path) -> tuple[int, int]:
    """Merge an overlay catalog into the current en-US catalog."""
    base = patcher.load_json(base_path)
    overlay = patcher.load_json(overlay_path) if overlay_path.exists() else {}
    if not isinstance(base, dict) or not isinstance(overlay, dict):
        raise SystemExit(f"词表格式不受支持: {base_path} / {overlay_path}")
    merged: dict[str, object] = {}
    translated = 0
    for key, value in base.items():
        if key in overlay:
            merged[key] = overlay[key]
            if overlay[key] != value:
                translated += 1
        else:
            merged[key] = value
    patcher.save_json(target_path, merged)
    return translated, len(base) - translated


def install_overrides(work: Path, target_code: str, merged_frontend: dict) -> None:
    i18n = work / "i18n"
    template = i18n / "en-US.overrides.json"
    if not template.exists():
        candidates = sorted(i18n.glob("*.overrides.json"))
        if not candidates:
            return
        template = candidates[0]
    keys = patcher.load_json(template)
    out = {key: merged_frontend[key] for key in keys if key in merged_frontend}
    patcher.save_json(i18n / f"{target_code}.overrides.json", out)
    log(f"Installed frontend overrides {target_code}: {len(out)} entries")


def verify_work_dir(work: Path, target_code: str) -> int:
    catalog = work / "i18n" / f"{target_code}.json"
    if not catalog.is_file():
        raise SystemExit(f"词表未写入: {catalog}")
    dynamic = work / "i18n" / "dynamic" / f"{target_code}.json"
    if (work / "i18n" / "dynamic" / "en-US.json").exists() and not dynamic.is_file():
        raise SystemExit(f"dynamic 词表未写入: {dynamic}")

    hits = 0
    for js_path in work.rglob("*.js"):
        text = js_path.read_text(encoding="utf-8", errors="ignore")
        for match in patcher.LANG_LIST_RE.finditer(text):
            if f'"{target_code}"' in match.group(0):
                hits += 1
    if hits == 0:
        raise SystemExit(
            "补丁未生效：前端 bundle 中没有找到包含 "
            f'"{target_code}" 的语言白名单。Claude Desktop 可能改动了前端结构。'
        )
    return hits


def patch(resources: Path, lang: str, output: Path | None = None) -> None:
    target_code = TARGET_CODES[lang]
    source_code = patcher.resource_language_code(target_code)
    mode, bundle = find_frontend_bundle(resources)
    log(f"前端布局: {mode} ({bundle})")
    log(f"语言: {lang} -> {target_code}（词表来源 frontend-{source_code}.json）")

    temp_root = Path(tempfile.mkdtemp(prefix="claude-zh-linux."))
    try:
        work = temp_root / "ion-dist"
        if mode == "asar":
            unpacked: set[str] = set()
            patcher.extract_asar(bundle, work, unpacked)
            log(f"已解包 ion-dist.asar（{len(unpacked)} 个 unpacked 文件）")
        else:
            shutil.copytree(bundle, work)
            unpacked = set()

        fake_app = temp_root / "Claude.app"
        fake_resources = fake_app / "Contents" / "Resources"
        fake_resources.mkdir(parents=True)
        (fake_resources / "ion-dist").symlink_to(work, target_is_directory=True)

        patcher.patch_language_whitelist(fake_app, target_code)
        translated, fallback = merge_catalog(
            work / "i18n" / "en-US.json",
            patcher.RESOURCES / f"frontend-{source_code}.json",
            work / "i18n" / f"{target_code}.json",
        )
        log(
            f"已合并前端词表 {target_code}: {translated} 条已翻译，"
            f"{fallback} 条保留英文"
        )

        dynamic_source = patcher.RESOURCES / f"dynamic-{source_code}.json"
        dynamic_en = work / "i18n" / "dynamic" / "en-US.json"
        if dynamic_en.exists():
            d_translated, d_fallback = merge_catalog(
                dynamic_en,
                dynamic_source,
                work / "i18n" / "dynamic" / f"{target_code}.json",
            )
            log(
                f"已合并 dynamic 词表 {target_code}: {d_translated} 条已翻译，"
                f"{d_fallback} 条保留英文"
            )

        statsig_dir = work / "i18n" / "statsig"
        if statsig_dir.is_dir() and (statsig_dir / "en-US.json").exists():
            s_translated, s_fallback = merge_catalog(
                statsig_dir / "en-US.json",
                patcher.RESOURCES / f"statsig-{source_code}.json",
                statsig_dir / f"{target_code}.json",
            )
            log(
                f"已合并 statsig 词表 {target_code}: {s_translated} 条已翻译，"
                f"{s_fallback} 条保留英文"
            )

        merged_frontend = patcher.load_json(work / "i18n" / f"{target_code}.json")
        install_overrides(work, target_code, merged_frontend)

        hits = verify_work_dir(work, target_code)
        log(f"语言白名单已注册 {target_code}（{hits} 处）")

        destination = output or bundle
        if mode == "asar":
            temporary = temp_root / "ion-dist.asar"
            patcher.build_asar(work, temporary, unpacked)
            data = temporary.read_bytes()
            _size, _header_string, header = patcher.read_asar_header(data, temporary)
            paths = {relative for relative, _entry in patcher.walk_asar_entries(header)}
            if f"i18n/{target_code}.json" not in paths or not any(
                path.startswith("assets/") and path.endswith(".js") for path in paths
            ):
                raise SystemExit("重新打包后的 ion-dist.asar 未通过结构校验。")
            destination.parent.mkdir(parents=True, exist_ok=True)
            staged = destination.with_name(destination.name + ".zh-cn-new")
            shutil.copy2(temporary, staged)
            os.replace(staged, destination)
        else:
            if destination == bundle:
                staged = temp_root / "ion-dist-new"
                shutil.copytree(work, staged)
                shutil.rmtree(bundle)
                shutil.move(str(staged), str(bundle))
            else:
                if destination.exists():
                    shutil.rmtree(destination)
                shutil.copytree(work, destination)

        log(f"完成: {destination}")
    finally:
        shutil.rmtree(temp_root, ignore_errors=True)


def main() -> int:
    parser = argparse.ArgumentParser(description="Install Chinese frontend catalogs into Linux Claude Desktop.")
    parser.add_argument("--resources", type=Path, required=True, help="Claude Desktop 的 resources 目录")
    parser.add_argument("--lang", choices=sorted(TARGET_CODES), help="要安装的仓库语言代码")
    parser.add_argument("--output", type=Path, help="输出路径（asar 文件；目录布局时为目录）")
    parser.add_argument(
        "--check-patched",
        action="store_true",
        help="仅检查当前前端是否已被本补丁修改，已修改时退出码为 0",
    )
    args = parser.parse_args()

    resources = args.resources.resolve()
    if not resources.is_dir():
        raise SystemExit(f"资源目录不存在: {resources}")

    if args.check_patched:
        patched = is_patched(resources)
        print("patched" if patched else "clean")
        return 0 if patched else 1

    if not args.lang:
        parser.error("--lang is required unless --check-patched is used")
    patch(resources, args.lang, args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
