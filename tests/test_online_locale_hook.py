import importlib.util
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).resolve().parents[1] / "scripts" / "patch_claude_zh_cn.py"
SPEC = importlib.util.spec_from_file_location("patch_claude_zh_cn", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
PATCHER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PATCHER)


class OnlineLocaleHookTests(unittest.TestCase):
    def test_online_account_reflect_and_focus_settings_have_translations(self) -> None:
        expected = {
            "zh-CN": ("回顾", "时间与专注", "勿扰时段"),
            "zh-TW": ("回顧", "時間與專注", "勿擾時段"),
            "zh-HK": ("回顧", "時間與專注", "勿擾時段"),
        }

        for lang_code, translations in expected.items():
            with self.subTest(lang_code=lang_code):
                mapping = dict(PATCHER.load_frontend_hardcoded_replacements(lang_code))
                self.assertEqual(mapping["Reflect"], translations[0])
                self.assertEqual(mapping["Time and focus"], translations[1])
                self.assertEqual(mapping["Quiet hours"], translations[2])
                self.assertIn("Based on your conversations in Claude chat.", mapping)
                self.assertIn("Looking at your month ...", mapping)
                self.assertIn("Looking at your month …", mapping)
                self.assertIn("This should only take a minute or so.", mapping)
                self.assertIn("Break reminders", mapping)
                self.assertIn(
                    "Get a nudge to take a break from Claude. You can snooze or adjust anytime.",
                    mapping,
                )
                self.assertIn(
                    "Set time limits for Claude. You can dismiss or adjust anytime.",
                    mapping,
                )

    def test_online_account_weekday_initials_use_contextual_translation(self) -> None:
        script = PATCHER.build_online_dom_translation_script("zh-CN", {})

        self.assertIn('"SMTWTFS"', script)
        self.assertIn('["日","一","二","三","四","五","六"]', script)

    def test_finds_semicolon_terminated_handler(self) -> None:
        text = 'a.webContents.on("dom-ready",()=>{track("main_view_dom_ready")});next()'

        match = PATCHER.find_main_view_dom_ready_handler(text)

        self.assertIsNotNone(match)
        assert match is not None
        self.assertEqual(match.group("web_contents"), "a.webContents")
        self.assertEqual(match.group("body"), 'track("main_view_dom_ready")')
        self.assertEqual(match.group("terminator"), ";")

    def test_finds_comma_terminated_handler_without_consuming_following_code(self) -> None:
        text = (
            'a.webContents.on("dom-ready",()=>{track("main_view_dom_ready"),ready()}),'
            'addView(a);window.on("close",()=>{hide()});'
        )

        match = PATCHER.find_main_view_dom_ready_handler(text)

        self.assertIsNotNone(match)
        assert match is not None
        self.assertEqual(match.group("body"), 'track("main_view_dom_ready"),ready()')
        self.assertEqual(match.group("terminator"), ",")
        self.assertEqual(text[match.end() :], 'addView(a);window.on("close",()=>{hide()});')

    def test_patch_round_trip_preserves_handler_terminator(self) -> None:
        for terminator in (";", ","):
            with self.subTest(terminator=terminator):
                original = f'a.webContents.on("dom-ready",()=>{{ready()}}){terminator}'
                injection = PATCHER.build_online_locale_main_process_script(
                    "zh-CN",
                    {},
                    "a.webContents",
                    "ready()",
                    terminator,
                )

                restored, changed = PATCHER.strip_online_locale_main_process_patch(injection)

                self.assertTrue(changed)
                self.assertEqual(restored, original)

    def test_rejects_unknown_handler_terminator(self) -> None:
        with self.assertRaises(ValueError):
            PATCHER.build_online_locale_main_process_script(
                "zh-CN",
                {},
                "a.webContents",
                "ready()",
                ":",
            )


if __name__ == "__main__":
    unittest.main()
