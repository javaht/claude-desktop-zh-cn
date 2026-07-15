import importlib.util
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).resolve().parents[1] / "scripts" / "patch_claude_zh_cn.py"
SPEC = importlib.util.spec_from_file_location("patch_claude_zh_cn", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
PATCHER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PATCHER)


class OnlineLocaleHookTests(unittest.TestCase):
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
