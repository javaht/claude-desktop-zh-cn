"""Tests for skills/claude-desktop-zh-localize/scripts/verify_mapping.py."""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "skills" / "claude-desktop-zh-localize" / "scripts" / "verify_mapping.py"


class VerifyMappingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmpdir.cleanup)
        self.root = Path(self.tmpdir.name)
        (self.root / "resources").mkdir()
        (self.root / "scripts").symlink_to(REPO / "scripts")
        for code in ("CN", "TW", "HK"):
            self.write_catalog(f"frontend-zh-{code}.json", {})
            self.write_catalog(f"frontend-hardcoded-zh-{code}.json", [])
        self.i18n_dir = self.root / "app" / "resources" / "ion-dist" / "i18n"
        self.i18n_dir.mkdir(parents=True)
        self.write_app_en({"key.copy": "Copy details"})

    def write_catalog(self, name: str, data: object) -> None:
        path = self.root / "resources" / name
        path.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")

    def write_app_en(self, data: dict[str, str]) -> None:
        (self.i18n_dir / "en-US.json").write_text(json.dumps(data), encoding="utf-8")

    def run_script(self, *phrases: str, app: bool = True) -> subprocess.CompletedProcess[str]:
        env = dict(os.environ, CLAUDE_ZH_REPO=str(self.root))
        env["CLAUDE_APP"] = str(self.root / "app") if app else "/nonexistent"
        return subprocess.run(
            [sys.executable, "-B", str(SCRIPT), *phrases],
            capture_output=True,
            text=True,
            env=env,
            check=False,
        )

    def test_i18n_phrase_passes(self) -> None:
        for code in ("CN", "TW", "HK"):
            self.write_catalog(f"frontend-zh-{code}.json", {"key.copy": "复制详情"})
        result = self.run_script("Copy details")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("i18n: 'Copy details'", result.stdout)

    def test_hardcoded_phrase_passes_and_decodes_js_escapes(self) -> None:
        pairs = [["Line one\\nLine two", "第一行\\n第二行"]]
        for code in ("CN", "TW", "HK"):
            self.write_catalog(f"frontend-hardcoded-zh-{code}.json", pairs)
        result = self.run_script("Line one\nLine two")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("hardcoded", result.stdout)

    def test_missing_phrase_fails(self) -> None:
        result = self.run_script("Nothing matches this")
        self.assertEqual(result.returncode, 1)
        self.assertIn("MISSING", result.stdout)

    def test_broken_bold_fails(self) -> None:
        for code in ("CN", "TW", "HK"):
            self.write_catalog(f"frontend-zh-{code}.json", {"key.bold": "**标签：**正文"})
        result = self.run_script("Copy details")
        self.assertEqual(result.returncode, 1)
        self.assertIn("[bold] frontend-zh-CN.json", result.stdout)

    def test_missing_app_reports_unchecked(self) -> None:
        result = self.run_script("Copy details", app=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn("UNCHECKED", result.stdout)
        self.assertIn("未找到 Claude 安装目录", result.stdout)


if __name__ == "__main__":
    unittest.main()
