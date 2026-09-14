#!/usr/bin/env python3
"""在 Linux 版 Claude Desktop 的 app.asar 上应用在线 claude.ai 页面的中文补丁。

复用 patch_claude_zh_cn.py 中的 asar 补丁逻辑（DOM 翻译注入 + locale 锁），
通过构造 macOS 布局的临时目录（符号链接）来适配其路径约定。

用法:
    python3 patch_linux_asar.py <app.asar工作副本> [zh-CN|zh-TW|zh-HK] [资源目录]

脚本对传入的 asar 副本就地打补丁，不直接修改系统文件；
调用方（install_linux.sh）负责复制 /usr/lib/claude-desktop/resources/app.asar、
打完补丁后装回，以及备份/恢复。
"""
from __future__ import annotations

import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import patch_claude_zh_cn as patcher  # noqa: E402


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    asar_copy = Path(sys.argv[1]).resolve()
    lang = sys.argv[2] if len(sys.argv) > 2 else "zh-CN"
    res_dir = (
        Path(sys.argv[3]).resolve()
        if len(sys.argv) > 3
        else Path("/usr/lib/claude-desktop/resources")
    )
    if not asar_copy.is_file():
        raise SystemExit(f"未找到 asar 文件: {asar_copy}")
    if not (res_dir / "ion-dist/i18n/en-US.json").is_file():
        raise SystemExit(f"资源目录不完整（缺 ion-dist/i18n/en-US.json）: {res_dir}")

    # macOS 版会更新 Info.plist 里的 ElectronAsarIntegrity 并 codesign；
    # Linux 版 Electron 不强制 asar 完整性校验，也没有 Info.plist，故置为空操作。
    # asar 头内每个文件的 integrity 字段仍由 replace_asar_file_content 正常重算。
    patcher.update_electron_asar_integrity = lambda *args, **kwargs: None

    with tempfile.TemporaryDirectory() as td:
        fake_app = Path(td) / "Claude.app"
        fake_res = fake_app / "Contents/Resources"
        fake_res.mkdir(parents=True)
        (fake_res / "app.asar").symlink_to(asar_copy)
        (fake_res / "ion-dist").symlink_to(res_dir / "ion-dist")

        # 上游的 patch_online_locale_main_process 已能自动探测主进程 chunk
        # （find_main_process_asar_target）并兼容 ;/, 分隔符、不同引号、包裹回调，
        # 故这里直接调用即可，无需手动指定补丁目标。
        patcher.patch_online_locale_main_process(fake_app, lang)

    # 防"假成功"：patch_online_locale_main_process 找不到锚点时只打 Warning
    # 就正常返回。显式校验补丁标记是否真的写进了 asar，缺失即报错，避免
    # Claude 升级改了主进程结构后脚本静默跳过、用户误以为装好了。
    patched = asar_copy.read_bytes()
    for marker in (b"__claudeZhOnlineLocaleMain", b"__claudeZhLocaleLock"):
        if marker not in patched:
            raise SystemExit(
                f"补丁未生效：app.asar 中缺少标记 {marker.decode()}。\n"
                "很可能是本次 Claude Desktop 版本改动了主进程代码结构，补丁锚点已失效。\n"
                "请携带 Claude Desktop 版本号反馈，需更新补丁脚本以适配新版本。"
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
