"""End-to-end tests for scripts/install_linux.sh state handling.

These run the real shell installer against a synthetic Claude Desktop layout.
They only run on Linux, with bash, as a non-root user.
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "linux_patcher_installer_test", ROOT / "scripts" / "patch_linux_asar.py"
)
linux_patcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(linux_patcher)
patcher = linux_patcher.patcher

RUN_INSTALLER = (
    sys.platform.startswith("linux")
    and shutil.which("bash") is not None
    and hasattr(os, "getuid")
    and os.getuid() != 0
)


def make_frontend(root: Path) -> None:
    assets = root / "assets"
    assets.mkdir(parents=True)
    (assets / "index-abc.js").write_text(
        f"const a=[{patcher.BASE_LANGUAGE_LIST}];", encoding="utf-8"
    )
    i18n = root / "i18n"
    (i18n / "dynamic").mkdir(parents=True)
    (i18n / "statsig").mkdir()
    (i18n / "en-US.json").write_text(json.dumps({"hello": "Hello"}), encoding="utf-8")
    (i18n / "dynamic" / "en-US.json").write_text(json.dumps({"model": "Model"}), encoding="utf-8")
    (i18n / "statsig" / "en-US.json").write_text(json.dumps({"flag": "Flag"}), encoding="utf-8")
    (root / "index.html").write_text("<html></html>", encoding="utf-8")


def make_desktop(resources: Path, native: str = "官方简体", *, include_traditional: bool = True) -> bytes:
    with tempfile.TemporaryDirectory() as tmp:
        source = Path(tmp)
        locale_dir = source / "resources" / "i18n"
        locale_dir.mkdir(parents=True)
        catalogs = {
            "en-US": {"2bmlYpf1g0": "Device tools access", "2f4ipR1XJ3": "Allow once"},
            "zh-Hans": {"2bmlYpf1g0": native},
        }
        if include_traditional:
            catalogs["zh-Hant"] = {"2bmlYpf1g0": "官方繁體"}
        for locale, messages in catalogs.items():
            (locale_dir / f"{locale}.json").write_text(json.dumps(messages), encoding="utf-8")
        archive = resources / "app.asar"
        patcher.build_asar(source, archive)
        return archive.read_bytes()


@unittest.skipUnless(RUN_INSTALLER, "requires bash on Linux, run as a non-root user")
class LinuxInstallerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmpdir.cleanup)
        self.root = Path(self.tmpdir.name)

        self.home = self.root / "home"
        self.config_dir = self.home / ".config" / "Claude"
        self.config_dir.mkdir(parents=True)
        self.config = self.config_dir / "config.json"
        self.write_locale(self.config, "en-US", theme="dark")

        self.app = self.root / "app"
        self.resources = self.app / "resources"
        self.resources.mkdir(parents=True)
        self.original_desktop = make_desktop(self.resources)
        source = self.root / "source"
        make_frontend(source)
        patcher.build_asar(source, self.resources / "ion-dist.asar")
        self.original_frontend = (self.resources / "ion-dist.asar").read_bytes()

        self.state = self.root / "state"
        self.state_root = self.state / "claude-desktop-zh-cn"
        self.env = os.environ.copy()
        self.env.update(
            {
                "HOME": str(self.home),
                "XDG_STATE_HOME": str(self.state),
                "CLAUDE_RESOURCES": str(self.resources),
                "CLAUDE_DESKTOP_PREFIX": str(self.root / "prefix"),
                "CLAUDE_ZH_SKIP_UPDATE_CHECK": "1",
            }
        )

    # helpers ---------------------------------------------------------------

    def write_locale(self, path: Path, locale: str, **extra) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        payload = {"locale": locale, **extra}
        path.write_text(json.dumps(payload, indent=2), encoding="utf-8")

    def read_locale(self, path: Path | None = None) -> str:
        data = json.loads((path or self.config).read_text(encoding="utf-8"))
        return data["locale"]

    def run_installer(self, *args: str) -> subprocess.CompletedProcess:
        result = subprocess.run(
            ["bash", str(ROOT / "scripts" / "install_linux.sh"), *args],
            env=self.env,
            capture_output=True,
            text=True,
            timeout=180,
        )
        return result

    def install(self, lang: str = "zh-CN") -> None:
        result = self.run_installer("install", lang)
        self.assertEqual(result.returncode, 0, result.stderr or result.stdout)

    def uninstall(self) -> None:
        result = self.run_installer("uninstall")
        self.assertEqual(result.returncode, 0, result.stderr or result.stdout)

    def state_dirs(self) -> list[Path]:
        return sorted(path for path in self.state_root.glob("*") if path.is_dir())

    def use_resources(self, resources: Path) -> None:
        self.env["CLAUDE_RESOURCES"] = str(resources)

    def desktop_state(self) -> Path:
        return next(self.state_root.glob("desktop@*.json"))

    def simulate_legacy_desktop(self) -> None:
        archive = self.resources / "app.asar"
        data = archive.read_bytes()
        header_size, _, header = patcher.read_asar_header(data, archive)
        header["claudeDesktopZhOriginalSha256"] = hashlib.sha256(self.original_desktop).hexdigest()
        archive.write_bytes(patcher.encode_asar_header(header) + data[8 + header_size:])
        self.desktop_state().unlink()

    # tests -----------------------------------------------------------------

    def shell_catalog(self, lang: str) -> dict:
        archive = self.resources / "app.asar"
        data = archive.read_bytes()
        size, _, header = patcher.read_asar_header(data, archive)
        return json.loads(patcher.read_asar_entry(data, size, header, f"resources/i18n/{lang}.json"))

    def test_repeat_install_keeps_original_locale(self):
        """同一版本重复安装后卸载，locale 必须回到安装前的值。"""
        self.install("zh-CN")
        self.assertEqual(self.read_locale(), "zh-Hans")
        catalog = self.shell_catalog("zh-Hans")
        self.assertEqual(catalog["2bmlYpf1g0"], "官方简体")
        self.assertEqual(catalog["2f4ipR1XJ3"], "仅允许一次")
        # 独立窗口词条（前端消息 id）也应注入壳层词表，供第三方推理配置窗口使用。
        self.assertEqual(catalog["ySAk9qhogV"], "在资源管理器中显示")
        self.assertEqual(self.shell_catalog("en-US")["2f4ipR1XJ3"], "Allow once")
        archive = self.resources / "app.asar"
        first_install = archive.read_bytes()
        _, _, original_header = patcher.read_asar_header(self.original_desktop, archive)
        _, _, patched_header = patcher.read_asar_header(first_install, archive)
        self.assertEqual(patched_header.keys(), original_header.keys())
        self.assertEqual(json.loads(self.desktop_state().read_bytes()), {
            "original": hashlib.sha256(self.original_desktop).hexdigest(),
            "patched": [hashlib.sha256(first_install).hexdigest()],
        })
        self.install("zh-CN")
        self.assertEqual(archive.read_bytes(), first_install)

        self.install("zh-TW")
        self.assertEqual(self.read_locale(), "zh-Hant")
        self.assertEqual(self.shell_catalog("zh-Hant")["2f4ipR1XJ3"], "僅允許一次")
        self.assertNotIn("2f4ipR1XJ3", self.shell_catalog("zh-Hans"))

        state = self.desktop_state()
        self.uninstall()
        self.assertEqual(self.read_locale(), "en-US")
        self.assertEqual(archive.read_bytes(), self.original_desktop)
        self.assertFalse(state.exists())
        self.assertEqual(
            (self.resources / "ion-dist.asar").read_bytes(), self.original_frontend
        )

    def test_switch_to_language_without_desktop_catalog_clears_state(self):
        original = make_desktop(self.resources, include_traditional=False)
        archive = self.resources / "app.asar"
        self.install()
        state = self.desktop_state()
        version_dir = self.state_dirs()[0]

        self.install("zh-TW")
        self.assertEqual(self.read_locale(), "zh-Hant")
        self.assertEqual(archive.read_bytes(), original)
        self.assertFalse(state.exists())
        self.assertEqual(self.state_dirs(), [version_dir])

        self.install()
        self.assertEqual(self.desktop_state(), state)
        self.uninstall()
        self.assertEqual(archive.read_bytes(), original)

    def test_legacy_header_patch_migrates_or_uninstalls(self):
        archive = self.resources / "app.asar"
        for action in ("install", "uninstall"):
            with self.subTest(action=action):
                self.install()
                version_dir = self.state_dirs()[0]
                self.simulate_legacy_desktop()
                if action == "install":
                    self.install("zh-TW")
                    self.assertEqual(self.state_dirs(), [version_dir])
                    self.assertEqual(self.shell_catalog("zh-Hant")["2f4ipR1XJ3"], "僅允許一次")
                    data = archive.read_bytes()
                    _, _, header = patcher.read_asar_header(data, archive)
                    self.assertNotIn("claudeDesktopZhOriginalSha256", header)
                    self.assertIn(hashlib.sha256(data).hexdigest(), json.loads(self.desktop_state().read_bytes())["patched"])
                self.uninstall()
                self.assertEqual(archive.read_bytes(), self.original_desktop)
                self.assertFalse(list(self.state_root.glob("desktop@*.json")))

    def test_interrupted_shell_replacement_keeps_current_patch_recognizable(self):
        self.install()
        archive = self.resources / "app.asar"
        first_install = archive.read_bytes()
        staging_path = self.resources / ".app.asar.zh-new"
        staging_path.mkdir()
        result = self.run_installer("install", "zh-TW")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(archive.read_bytes(), first_install)
        transition = json.loads(self.desktop_state().read_bytes())
        self.assertEqual(len(transition["patched"]), 2)
        self.assertIn(hashlib.sha256(first_install).hexdigest(), transition["patched"])
        shutil.rmtree(staging_path)

        self.install("zh-TW")
        self.assertIn(hashlib.sha256(archive.read_bytes()).hexdigest(), transition["patched"])
        self.uninstall()
        self.assertEqual(archive.read_bytes(), self.original_desktop)

    def test_unrecognized_desktop_state_preserves_original_backup(self):
        self.install()
        archive = self.resources / "app.asar"
        frontend = self.resources / "ion-dist.asar"
        patched_desktop, patched_frontend = archive.read_bytes(), frontend.read_bytes()
        backup = self.state_dirs()[0] / "app.asar"
        state = self.desktop_state()
        record = state.read_bytes()
        mismatched = json.loads(record)
        mismatched["patched"] = ["0" * 64]
        for contents, error in (
            (None, "无法确认当前 app.asar"),
            (b"{}", "壳层补丁状态中的摘要无效"),
            (json.dumps(mismatched).encode(), "无法确认当前 app.asar"),
        ):
            if contents is None:
                state.unlink()
            else:
                state.write_bytes(contents)
            for action in ("install", "uninstall"):
                with self.subTest(contents=contents, action=action):
                    result = self.run_installer(action)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(error, result.stderr)
                    self.assertEqual(archive.read_bytes(), patched_desktop)
                    self.assertEqual(frontend.read_bytes(), patched_frontend)
                    self.assertEqual(backup.read_bytes(), self.original_desktop)
            state.write_bytes(record)

    def test_missing_desktop_backup_refuses_install_and_uninstall(self):
        self.install()
        archive = self.resources / "app.asar"
        patched = archive.read_bytes()
        (self.state_dirs()[0] / "app.asar").unlink()
        for action in ("install", "uninstall"):
            with self.subTest(action=action):
                result = self.run_installer(action)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("找不到原始 app.asar 备份", result.stderr)
                self.assertEqual(archive.read_bytes(), patched)
                self.assertEqual(self.read_locale(), "zh-Hans")

    def test_uninstall_resets_config_created_after_install(self):
        """安装后才生成的 Claude-3p 配置也要恢复，不能残留 zh-Hans。"""
        self.install("zh-CN")
        three_p = self.home / ".config" / "Claude-3p" / "config.json"
        self.write_locale(three_p, "zh-Hans")

        self.uninstall()
        self.assertEqual(self.read_locale(), "en-US")
        self.assertEqual(self.read_locale(three_p), "en-US")

    def test_missing_record_only_resets_patch_locale(self):
        """记录丢失时只回退补丁写入的 locale，用户手选的其他语言保持不变。"""
        self.install("zh-CN")
        for record in self.state_root.glob("locale-originals@*.json"):
            record.unlink()
        self.write_locale(self.config, "ja-JP")
        three_p = self.home / ".config" / "Claude-3p" / "config.json"
        self.write_locale(three_p, "zh-Hans")

        self.uninstall()
        self.assertEqual(self.read_locale(), "ja-JP")
        self.assertEqual(self.read_locale(three_p), "en-US")

    def test_upgrade_keeps_locale_record_and_drops_old_backup(self):
        """升级换版本后，locale 原值仍应保留，旧版本备份应被清理。"""
        self.install("zh-CN")
        self.assertEqual(len(self.state_dirs()), 1)

        # 模拟应用升级：前端和壳层一起换包，版本元数据变化。
        (self.resources / "ion-dist.asar").write_bytes(self.original_frontend)
        upgraded_desktop = make_desktop(self.resources, "升级后的官方简体")
        (self.app / ".deb-version").write_text("9.9.9\n", encoding="utf-8")
        self.install("zh-CN")
        self.assertEqual(self.shell_catalog("zh-Hans")["2bmlYpf1g0"], "升级后的官方简体")
        self.assertEqual(len(self.state_dirs()), 1)
        self.assertEqual(self.read_locale(), "zh-Hans")

        self.uninstall()
        self.assertEqual(self.read_locale(), "en-US")
        self.assertEqual((self.resources / "app.asar").read_bytes(), upgraded_desktop)
        self.assertEqual(
            (self.resources / "ion-dist.asar").read_bytes(), self.original_frontend
        )

    def test_installations_do_not_share_state(self):
        """同版本的两份安装各自备份；卸载一份不能删掉另一份的还原文件。"""
        second = self.root / "app2"
        second_resources = second / "resources"
        second_resources.mkdir(parents=True)
        make_desktop(second_resources)
        (second_resources / "ion-dist.asar").write_bytes(self.original_frontend)

        self.install("zh-CN")
        self.use_resources(second_resources)
        self.install("zh-CN")
        self.assertEqual(len(self.state_dirs()), 2)

        self.use_resources(self.resources)
        self.uninstall()
        self.assertEqual(len(self.state_dirs()), 1)
        self.assertEqual(
            (self.resources / "ion-dist.asar").read_bytes(), self.original_frontend
        )

        self.use_resources(second_resources)
        self.uninstall()
        self.assertEqual(self.state_dirs(), [])
        self.assertEqual(
            (second_resources / "ion-dist.asar").read_bytes(), self.original_frontend
        )
        self.assertEqual(self.read_locale(), "en-US")

    def test_legacy_state_layout_is_migrated(self):
        """旧版“仅版本号”目录与版本内 locale 记录要能迁移，不能丢备份。"""
        self.install("zh-CN")
        version_dir = self.state_dirs()[0]
        version = version_dir.name.rsplit("@", 1)[0]
        legacy = self.state_root / version
        version_dir.rename(legacy)
        record = next(self.state_root.glob("locale-originals@*.json"))
        record.rename(legacy / "config-locales.json")

        self.install("zh-TW")
        self.assertEqual(self.read_locale(), "zh-Hant")
        self.uninstall()
        self.assertEqual(self.read_locale(), "en-US")
        self.assertEqual(
            (self.resources / "ion-dist.asar").read_bytes(), self.original_frontend
        )

    def test_directory_layout_refuses_patched_frontend_without_backup(self):
        """目录布局同样不能在缺少备份时把已汉化目录当成原始文件。"""
        resources = self.root / "dir-app" / "resources"
        ion_dist = resources / "ion-dist"
        ion_dist.mkdir(parents=True)
        make_frontend(ion_dist)
        (ion_dist / "i18n" / "zh-Hans.json").write_text("{}", encoding="utf-8")
        make_desktop(resources)
        self.use_resources(resources)

        result = self.run_installer("install", "zh-CN")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("找不到同版本的原始备份", result.stderr)
        self.assertTrue((ion_dist / "i18n" / "zh-Hans.json").is_file())
        self.assertEqual(list(self.state_root.glob("*/ion-dist.tar")), [])


if __name__ == "__main__":
    unittest.main()
