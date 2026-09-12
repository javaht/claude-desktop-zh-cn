"""Unit tests for the pre-install backup/restore downgrade fix (issue #156).

The macOS installer restores `Claude.backup-before-zh-CN-*.app` backups
before re-patching. It used to restore the OLDEST backup unconditionally,
which downgraded Claude to a stale version and deleted a freshly updated
official app. These tests cover the version-aware helpers that replaced it:

* version_key / bundle_version: numeric version comparison;
* select_backup: always picks the highest-version backup;
* _official_signature: Developer ID = official, ad-hoc = patched;
* preinstall_should_restore: official builds are never restored.
"""

import importlib.util
import plistlib
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
PYTHON_PATCHER = ROOT / "scripts" / "patch_claude_zh_cn.py"


def load_python_patcher():
    spec = importlib.util.spec_from_file_location("claude_zh_patcher", PYTHON_PATCHER)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to import {PYTHON_PATCHER}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


patcher = load_python_patcher()


def make_bundle(root: Path, name: str, version: str) -> Path:
    app = root / name
    contents = app / "Contents"
    contents.mkdir(parents=True)
    info = {
        "CFBundleIdentifier": "com.anthropic.claudefordesktop",
        "CFBundleShortVersionString": version,
    }
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    return app


class VersionKeyTests(unittest.TestCase):
    def test_issue_156_regression_pair(self):
        # The reporter's stale backup (1.2) vs the freshly downloaded app.
        self.assertLess(patcher.version_key("1.2"), patcher.version_key("1.46388.3"))

    def test_numeric_segments_compare_numerically(self):
        self.assertLess(patcher.version_key("0.9.9"), patcher.version_key("0.9.10"))

    def test_unreadable_version_sorts_lowest(self):
        self.assertEqual(patcher.version_key("not-a-version"), (0, 0, 0))
        self.assertLess(patcher.version_key("not-a-version"), patcher.version_key("0.0.1"))


class BundleVersionTests(unittest.TestCase):
    def test_reads_short_version_string(self):
        with TemporaryDirectory() as tmp:
            app = make_bundle(Path(tmp), "Claude.app", "1.46388.3")
            self.assertEqual(patcher.bundle_version(app), "1.46388.3")

    def test_falls_back_to_cf_bundle_version(self):
        with TemporaryDirectory() as tmp:
            app = Path(tmp) / "Claude.app"
            (app / "Contents").mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleVersion": "77"}))
            self.assertEqual(patcher.bundle_version(app), "77")

    def test_missing_plist_returns_zero(self):
        self.assertEqual(patcher.bundle_version(Path("/nonexistent/Claude.app")), "0")


class SelectBackupTests(unittest.TestCase):
    def test_picks_highest_version_not_oldest_name(self):
        # The highest version (1.46388.3) carries the OLDEST timestamp, so
        # neither name order nor timestamp order alone may decide the pick.
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            backups = [
                make_bundle(root, "Claude.backup-before-zh-CN-20260801-000000.app", "1.46388.3"),
                make_bundle(root, "Claude.backup-before-zh-CN-20260810-000000.app", "1.2"),
                make_bundle(root, "Claude.backup-before-zh-CN-20260901-000000.app", "1.3"),
            ]
            self.assertEqual(patcher.select_backup(backups), backups[0])

    def test_tie_breaks_on_name(self):
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            backups = [
                make_bundle(root, "Claude.backup-before-zh-CN-20260801-000000.app", "1.2"),
                make_bundle(root, "Claude.backup-before-zh-CN-20260901-000000.app", "1.2"),
            ]
            self.assertEqual(patcher.select_backup(backups), backups[1])


class OfficialSignatureTests(unittest.TestCase):
    def test_developer_id_is_official(self):
        info = {
            "adhoc": False,
            "raw": (
                "Authority=Developer ID Application: Anthropic, PBC (TEAMID)\n"
                "TeamIdentifier=TEAMID"
            ),
        }
        self.assertTrue(patcher._official_signature(info))

    def test_adhoc_is_not_official(self):
        info = {"adhoc": True, "raw": "Authority=(unavailable)\nSignature=adhoc"}
        self.assertFalse(patcher._official_signature(info))

    def test_unreadable_codesign_is_not_official(self):
        with patch.object(patcher, "codesign_info", side_effect=RuntimeError("boom")):
            self.assertFalse(patcher.is_officially_signed(Path("/nonexistent")))


class PreinstallShouldRestoreTests(unittest.TestCase):
    def test_official_build_is_never_restored(self):
        with TemporaryDirectory() as tmp:
            app = make_bundle(Path(tmp), "Claude.app", "1.46388.3")
            with patch.object(patcher, "is_officially_signed", return_value=True):
                self.assertFalse(patcher.preinstall_should_restore(app))

    def test_patched_build_is_restored(self):
        with TemporaryDirectory() as tmp:
            app = make_bundle(Path(tmp), "Claude.app", "1.46388.3")
            with patch.object(patcher, "is_officially_signed", return_value=False):
                self.assertTrue(patcher.preinstall_should_restore(app))

    def test_missing_app_is_restored(self):
        # No installed app while backups exist: the backup is the only source.
        with patch.object(patcher, "is_officially_signed", return_value=True):
            self.assertTrue(patcher.preinstall_should_restore(Path("/nonexistent/Claude.app")))


if __name__ == "__main__":
    unittest.main()
