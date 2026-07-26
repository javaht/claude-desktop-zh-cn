#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Regression tests for replace_frontend_hardcoded_text()'s raw-substring branch
(sources that contain code syntax like `Ca="Local"` rather than a plain quoted
UI string).

Background: a real-world install broke `g._addDefaultMeta is not a function`
in the renderer after patching. The raw-substring branch did an unconditional
`text.replace(source, target)` with no check for (a) the same short, minifier-
generated identifier being reused for something unrelated elsewhere in the
same file, or (b) the source text being a fragment of a longer identifier.
These tests pin the fix down so it can't silently regress.

Run with: python3 -m unittest tests/test_hardcoded_replacement_safety.py -v
(no external dependencies — stdlib unittest only)
"""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parent.parent / "scripts" / "patch_claude_zh_cn.py"
spec = importlib.util.spec_from_file_location("patch_claude_zh_cn", MODULE_PATH)
patch_mod = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = patch_mod
spec.loader.exec_module(patch_mod)

replace_frontend_hardcoded_text = patch_mod.replace_frontend_hardcoded_text


class RawSubstringSafetyTests(unittest.TestCase):
    def test_single_unambiguous_match_is_replaced(self):
        # The common, legitimate case: the short-identifier assignment
        # appears exactly once in the file and isn't part of a longer name.
        text = 'function f(){return e?Ca="Local":Ba="Cloud"}'
        patched, count = replace_frontend_hardcoded_text(
            text, 'Ca="Local"', 'Ca="本機"', file_label="test.js"
        )
        self.assertEqual(count, 1)
        self.assertIn('Ca="本機"', patched)
        self.assertNotIn('Ca="Local"', patched)

    def test_ambiguous_multi_occurrence_is_skipped(self):
        # The exact failure class that broke _addDefaultMeta: a minifier
        # reuses the same short identifier for unrelated values in two
        # different closures within one file. Blindly replacing both is
        # how unrelated code gets corrupted — must skip instead.
        text = (
            'function labelA(){return Ca="Local"}'
            'function unrelatedThing(){var Ca="Local";return Ca.toUpperCase()}'
        )
        patched, count = replace_frontend_hardcoded_text(
            text, 'Ca="Local"', 'Ca="本機"', file_label="test.js"
        )
        self.assertEqual(count, 0)
        self.assertEqual(patched, text, "text must be left untouched when ambiguous")

    def test_identifier_boundary_collision_is_skipped(self):
        # source is a fragment of a longer, unrelated identifier assignment.
        # A naive text.replace() would have corrupted this.
        text = 'function g(){var XCa="Local"; return XCa}'
        patched, count = replace_frontend_hardcoded_text(
            text, 'Ca="Local"', 'Ca="本機"', file_label="test.js"
        )
        self.assertEqual(count, 0)
        self.assertEqual(patched, text, "text must be left untouched on boundary collision")

    def test_trailing_boundary_collision_is_skipped(self):
        # source's tail character is an identifier char and is immediately
        # followed by more identifier characters in the bundle.
        text = 'var ya="ScheduledExtra"'
        patched, count = replace_frontend_hardcoded_text(
            text, 'ya="Scheduled', 'ya="排程任務', file_label="test.js"
        )
        self.assertEqual(count, 0)
        self.assertEqual(patched, text)

    def test_no_match_is_a_safe_no_op(self):
        text = 'function f(){return 1}'
        patched, count = replace_frontend_hardcoded_text(
            text, 'Ca="Local"', 'Ca="本機"', file_label="test.js"
        )
        self.assertEqual(count, 0)
        self.assertEqual(patched, text)

    def test_quoted_plain_ui_text_path_is_unaffected(self):
        # Sanity check: the existing quoted-literal path (used for genuine
        # plain UI strings, no code markers) must keep working exactly as
        # before — this fix only touches the raw-substring branch.
        text = 'e.createElement("span",null,"New chat")'
        patched, count = replace_frontend_hardcoded_text(
            text, "New chat", "新增聊天", file_label="test.js"
        )
        self.assertEqual(count, 1)
        self.assertIn('"新增聊天"', patched)


if __name__ == "__main__":
    unittest.main()
