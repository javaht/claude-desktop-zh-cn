"""Tests for user locale configuration and ownership handling in patch_claude_zh_cn.py."""
import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("patcher", ROOT / "scripts/patch_claude_zh_cn.py")
patcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patcher)


class UserLocaleTests(unittest.TestCase):
    def test_creates_claude_dir_and_sets_locale(self):
        with tempfile.TemporaryDirectory() as tmp:
            user_home = Path(tmp)
            claude_dir = user_home / "Library" / "Application Support" / "Claude"
            config_file = claude_dir / "config.json"
            self.assertFalse(claude_dir.exists())

            patcher.set_user_locale(user_home, "zh-CN")

            self.assertTrue(claude_dir.is_dir())
            self.assertTrue(config_file.is_file())
            data = json.loads(config_file.read_text(encoding="utf-8"))
            self.assertEqual(data.get("locale"), "zh-CN")
            if hasattr(os, "geteuid"):
                self.assertEqual(config_file.stat().st_mode & 0o777, 0o600)

    def test_skips_creating_third_party_dir_when_absent(self):
        with tempfile.TemporaryDirectory() as tmp:
            user_home = Path(tmp)
            third_party_dir = user_home / "Library" / "Application Support" / "Claude-3p"
            self.assertFalse(third_party_dir.exists())

            patcher.set_user_locale(user_home, "zh-CN")

            # Claude-3p must NOT be created if it did not exist before
            self.assertFalse(third_party_dir.exists())

    def test_updates_third_party_config_when_present(self):
        with tempfile.TemporaryDirectory() as tmp:
            user_home = Path(tmp)
            third_party_dir = user_home / "Library" / "Application Support" / "Claude-3p"
            third_party_dir.mkdir(parents=True, exist_ok=True)
            config_file = third_party_dir / "config.json"
            config_file.write_text('{"foo":"bar"}', encoding="utf-8")

            patcher.set_user_locale(user_home, "zh-TW")

            self.assertTrue(config_file.is_file())
            data = json.loads(config_file.read_text(encoding="utf-8"))
            self.assertEqual(data.get("locale"), "zh-TW")
            self.assertEqual(data.get("foo"), "bar")

    @patch.object(patcher, "safe_chown")
    def test_chowns_parent_directories_and_file_when_sudo(self, mock_safe_chown):
        with tempfile.TemporaryDirectory() as tmp:
            user_home = Path(tmp)
            claude_dir = user_home / "Library" / "Application Support" / "Claude"
            config_file = claude_dir / "config.json"

            with patch.dict(os.environ, {"SUDO_UID": "1001", "SUDO_GID": "1002"}):
                patcher.set_user_locale(user_home, "zh-CN")

            # Check that safe_chown was invoked with (uid=1001, gid=1002) for claude_dir and config_file
            chowned_paths = [call[0][0] for call in mock_safe_chown.call_args_list]
            self.assertIn(claude_dir, chowned_paths)
            self.assertIn(config_file, chowned_paths)
            for call in mock_safe_chown.call_args_list:
                self.assertEqual(call[0][1], 1001)
                self.assertEqual(call[0][2], 1002)

    @patch.object(patcher, "safe_chown")
    def test_repairs_ownership_even_when_locale_already_matches(self, mock_safe_chown):
        with tempfile.TemporaryDirectory() as tmp:
            user_home = Path(tmp)
            claude_dir = user_home / "Library" / "Application Support" / "Claude"
            claude_dir.mkdir(parents=True, exist_ok=True)
            config_file = claude_dir / "config.json"
            config_file.write_text('{"locale":"zh-CN"}', encoding="utf-8")

            with patch.dict(os.environ, {"SUDO_UID": "1001", "SUDO_GID": "1002"}):
                patcher.set_user_locale(user_home, "zh-CN")

            chowned_paths = [call[0][0] for call in mock_safe_chown.call_args_list]
            # Must repair parent directory and config file even when locale is already zh-CN
            self.assertIn(claude_dir, chowned_paths)
            self.assertIn(config_file, chowned_paths)


if __name__ == "__main__":
    unittest.main()
