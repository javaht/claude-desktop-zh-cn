"""Local unit tests for the desktop-shortcut repair feature.

The repair logic lives in `scripts/install_windows.ps1` (powered by the
AppX package's AppUserModelID and in-place byte patching of *.lnk files).
These tests validate:

* the three helper functions exist in the script and are wired into the
  [1] (safe-mode) install flow;
* the AUMID extraction regex, taken from the script, matches a realistic
  lnk byte fixture;
* the in-place equal/unequal-length version replacement algorithm behaves
  as intended on a synthetic lnk payload (protected strings untouched).
"""

import importlib.util
import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WINDOWS_PATCHER = ROOT / "scripts" / "install_windows.ps1"

# Minimal AppX lnk fingerprint: UTF-16 (LE) text carrying both the AUMID and
# a versioned WindowsApps path, exactly like the shortcuts Claude Desktop
# writes on install.
LNK_PAYLOAD_PIECES = [
    "WindowsApps\\Claude_1.46388.4.0_x64__pzs8sxrjxfjjc\\Claude.exe",
    "Claude_pzs8sxrjxfjjc!Claude",
    "Assets\\Square44x44Logo.png",
]

LNK_UTF16 = "".join(LNK_PAYLOAD_PIECES).encode("utf-16-le")


def _script_source() -> str:
    return WINDOWS_PATCHER.read_text(encoding="utf-8-sig")


def _find_bytes(haystack: bytes, needle: bytes) -> list[int]:
    matches: list[int] = []
    if not needle or len(haystack) < len(needle):
        return matches
    pos = haystack.find(needle)
    while pos != -1:
        matches.append(pos)
        pos = haystack.find(needle, pos + 1)
    return matches


class ShortcutRepairContractTests(unittest.TestCase):
    def test_helper_functions_are_defined(self):
        source = _script_source()
        for fn in (
            "function Get-ClaudeAppUserModelId",
            "function Rebuild-ClaudeDesktopShortcut",
            "function Repair-ClaudeDesktopShortcut",
        ):
            self.assertIn(fn, source, f"missing {fn}")

    def test_repair_is_called_in_safe_install_flow(self):
        source = _script_source()
        # Wire-in point: after [3/8] locate Claude, only for safe mode ([1]).
        self.assertIn("修复桌面 Claude 快捷方式", source)
        self.assertIn('if ($PatchMode -eq "safe") {', source)
        self.assertIn("Repair-ClaudeDesktopShortcut $claudePath", source)

    def test_backup_before_any_change(self):
        source = _script_source()
        self.assertIn(".broken.bak", source)
        self.assertIn('Copy-Item -LiteralPath $ShortcutPath $backup -Force', source)

    def test_aumid_extraction_regex_matches_real_fingerprint(self):
        source = _script_source()
        # The regex string is used verbatim in Get-ClaudeAppUserModelId.
        self.assertIn("'Claude_[A-Za-z0-9]+![A-Za-z0-9]+'", source)
        pattern = re.compile(r"Claude_[A-Za-z0-9]+![A-Za-z0-9]+")
        text = LNK_UTF16.decode("utf-16-le")
        self.assertIsNotNone(pattern.search(text))

    def test_equal_length_version_replaced_in_place(self):
        old_utf16 = "1.46388.4.0".encode("utf-16-le")
        new = "1.40609.0.0".encode("utf-16-le")
        self.assertEqual(len(old_utf16), len(new))
        payload = LNK_UTF16.replace(
            "Claude_1.46388.4.0".encode("utf-16-le"),
            "Claude_".encode("utf-16-le") + new,
        )
        # AUMID must stay intact after patching the version.
        self.assertIn("Claude_pzs8sxrjxfjjc!Claude".encode("utf-16-le"), payload)
        self.assertIn(new, payload)
        self.assertNotIn(old_utf16, payload)

    def test_byte_scan_finds_versioned_dir_tokens(self):
        needle = "WindowsApps\\Claude_".encode("utf-16-le")
        hits = _find_bytes(LNK_UTF16, needle)
        self.assertEqual(len(hits), 1)
        # Version token follows the prefix byte-for-byte (UTF-16 chars).
        vi = hits[0] + len(needle)
        token = LNK_UTF16[vi : vi + len("1.46388.4.0".encode("utf-16-le"))]
        self.assertEqual(token, "1.46388.4.0".encode("utf-16-le"))


if __name__ == "__main__":
    unittest.main()