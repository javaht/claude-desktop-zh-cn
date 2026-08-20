r"""Regression tests for the macOS patcher's dom-ready handler locator.

Covers the bundle format change seen in Claude Desktop 1.32885.1, where the
main-process bundle was split into index.chunk-*.js files and the dom-ready
handler is registered as webContents.on(`dom-ready`,(()=>{...})) (arrow
function wrapped in an extra paren pair), instead of the older
webContents.on("dom-ready",()=>{...}) form.
"""

import shutil
import subprocess
import unittest

from tests.test_dom_translation_guards import load_python_patcher

# 1.32885.1-era shape: backtick event name, extra paren around the arrow,
# ternary/nested-call body, comma-chain terminator. Structurally identical to
# the real bundle, no Anthropic code copied.
NEW_FORMAT = (
    "c.webContents.on(`dom-ready`,(()=>{"
    "let ok=canLoad();d=ok?Date.now():void 0,track(ok?c.webContents:null),done()"
    "})),nextCall(c);"
)

# Pre-1.32-era shape: double-quoted event name, plain arrow, trivial body,
# semicolon terminator.
OLD_FORMAT = 'r.webContents.on("dom-ready",()=>{a0()});const n=setup();'


def patch_text(patcher, text: str) -> str:
    handler = patcher.find_main_view_dom_ready_handler(text)
    assert handler is not None
    injection = patcher.build_online_locale_main_process_script(
        "zh-CN",
        {"Settings": "设置"},
        handler.group("web_contents"),
        handler.group("body"),
        handler.group("terminator"),
        handler.group("quote"),
    )
    return text[: handler.start()] + injection + text[handler.end() :]


class MacosDomReadyHookTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.patcher = load_python_patcher()

    def test_new_split_bundle_handler_is_located(self):
        handler = self.patcher.find_main_view_dom_ready_handler(NEW_FORMAT)
        self.assertIsNotNone(handler)
        self.assertEqual(handler.group("web_contents"), "c.webContents")
        self.assertEqual(handler.group("quote"), "`")
        self.assertEqual(handler.group("wrap"), "(")
        self.assertEqual(handler.group("terminator"), ",")
        self.assertIn("track(ok?c.webContents:null)", handler.group("body"))

    def test_legacy_handler_still_matches(self):
        handler = self.patcher.find_main_view_dom_ready_handler(OLD_FORMAT)
        self.assertIsNotNone(handler)
        self.assertEqual(handler.group("web_contents"), "r.webContents")
        self.assertEqual(handler.group("quote"), '"')
        self.assertIsNone(handler.group("wrap"))
        self.assertEqual(handler.group("terminator"), ";")
        self.assertEqual(handler.group("body"), "a0()")

    def test_unbalanced_handler_parens_are_rejected(self):
        # Guard against a partial match that would unbalance the bundle when
        # the matched span is replaced by the injection.
        for broken in (
            "y.webContents.on(`dom-ready`,(()=>{z()}),",
            "y.webContents.on(`dom-ready`,()=>{z()})),",
        ):
            with self.subTest(broken=broken):
                self.assertIsNone(
                    self.patcher.find_main_view_dom_ready_handler(broken)
                )

    def test_patch_round_trips_for_both_formats(self):
        for name, source in (("new", NEW_FORMAT), ("legacy", OLD_FORMAT)):
            with self.subTest(format=name):
                patched = patch_text(self.patcher, source)
                self.assertIn(self.patcher.ONLINE_LOCALE_MAIN_MARKER, patched)

                reverted, had_patch = (
                    self.patcher.strip_online_locale_main_process_patch(patched)
                )
                self.assertTrue(had_patch)
                self.assertNotIn(
                    self.patcher.ONLINE_LOCALE_MAIN_MARKER, reverted
                )
                # The patcher always emits the canonical unwrapped handler, so a
                # wrapped source loses its decorative parens; re-patching the
                # reverted text must then be a no-op.
                self.assertEqual(patch_text(self.patcher, reverted), patched)

    @unittest.skipUnless(shutil.which("node"), "node is required for syntax checks")
    def test_patched_bundle_text_is_valid_javascript(self):
        for name, source in (("new", NEW_FORMAT), ("legacy", OLD_FORMAT)):
            with self.subTest(format=name):
                patched = patch_text(self.patcher, source)
                for label, text in (("patched", patched), ("source", source)):
                    result = subprocess.run(
                        ["node", "--check", "-"],
                        input=text,
                        capture_output=True,
                        text=True,
                    )
                    self.assertEqual(
                        result.returncode, 0, f"{label} {name}: {result.stderr}"
                    )


if __name__ == "__main__":
    unittest.main()
