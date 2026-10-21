"""回归 #193 / #204 / #205：标识符不走静态汉化，可见文案走 i18n。"""
import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("patcher", ROOT / "scripts/patch_claude_zh_cn.py")
patcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patcher)

PROTECTED = {
    "Search", "Add", "Copy", "Check", "Tasks", "Settings", "Command", "Cancel",
    "Sort", "Voice", "Default", "Arguments", "Normal", "All", "Application",
    "Medium", "Motion", "Thinking", "Verbose",
}


class StructuralReplacementTests(unittest.TestCase):
    def test_shared_regression_cases(self):
        cases = json.loads((ROOT / "tests/fixtures/structural-replacements.json").read_text(encoding="utf-8"))
        for case in cases:
            with self.subTest(case=case["name"]):
                actual, _ = patcher.replace_frontend_hardcoded_text(case["text"], case["source"], "测试译文")
                self.assertEqual(actual, case["expected"])

    def test_bare_and_quoted_protected_rules_are_ignored(self):
        for word in sorted(PROTECTED):
            for source in (word, '"' + word + '"'):
                with self.subTest(source=source):
                    text = 'const value="' + word + '"'
                    self.assertEqual(patcher.replace_frontend_hardcoded_text(text, source, "测试译文"), (text, 0))
                    self.assertEqual(patcher._prepare_hardcoded_rules([(source, "测试译文")]), [])

    def test_catalogs_have_no_unsafe_single_word_rules(self):
        for lang in ("zh-CN", "zh-TW", "zh-HK"):
            rules = patcher.load_frontend_hardcoded_replacements(lang)
            unsafe = [source for source, _ in rules if source.strip('"') in PROTECTED]
            with self.subTest(lang=lang):
                self.assertEqual(unsafe, [])

    def test_real_rule_preparation_keeps_visible_phrases(self):
        for lang in ("zh-CN", "zh-TW", "zh-HK"):
            rules = patcher._prepare_hardcoded_rules(patcher.load_frontend_hardcoded_replacements(lang))
            self.assertGreater(len(rules), 100)
            self.assertFalse(any(source.strip('"') in PROTECTED for source, _, _ in rules))
            self.assertTrue(any(" " in source for source, _, _ in rules))

    def test_native_ui_translations_remain_available(self):
        # IDs verified against Claude Desktop 3.1623.0.0 en-US.json; Motion is also
        # a product identifier, so its accessibility setting uses its own message.
        ids = ["tWVShwh984", "FOW8QxFbvE", "EbK+xUjBAt", "uALpKq2tu/", "AHQWDTo4+e", "ti6aQl5Lr/"]
        for lang in ("zh-CN", "zh-TW", "zh-HK"):
            catalog = json.loads((ROOT / f"resources/frontend-{lang}.json").read_text(encoding="utf-8"))
            for key in ids:
                with self.subTest(lang=lang, key=key):
                    self.assertIn(key, catalog)
                    self.assertRegex(catalog[key], r"[㐀-鿿]")


if __name__ == "__main__":
    unittest.main()
