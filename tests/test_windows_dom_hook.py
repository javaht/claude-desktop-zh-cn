r"""Regression tests for the Windows installer's online DOM translation hook scanner.

Covers the bundle format change seen in Claude Desktop 1.32885.1, where the
main-process bundle was split into index.chunk-*.js files and the dom-ready
handler is registered as webContents.on(`dom-ready`,(()=>{...})) (arrow
function wrapped in an extra paren pair), instead of the older
webContents.on("dom-ready",()=>{...}) form.
"""

import json
import shutil
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WINDOWS_PATCHER = ROOT / "scripts" / "install_windows.ps1"

# 1.32885.1-era shape: backtick event name, extra paren around the arrow,
# ternary/nested-call body, comma-chain terminator. Structurally identical to
# the real bundle, no Anthropic code copied.
NEW_FORMAT = (
    "c.webContents.on(`dom-ready`,(()=>{"
    "let ok=canLoad();d=ok?Date.now():void 0,track(ok?c.webContents:null)"
    "})),Jdn(c),a.contentView.addChildView(c);"
)

# Pre-1.32-era shape (e.g. 0.14.10): double-quoted event name, plain arrow,
# trivial body, semicolon terminator.
OLD_FORMAT = (
    'r.webContents.on("dom-ready",()=>{a0()});'
    'const n=y7({webPreferences:{preload:Be.join(se.app.getAppPath(),'
    '".vite/build/findInPage.js")}});'
)

HARNESS = r'''
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
{PARAMS_AND_FUNCTIONS}
$fixture = @'
{FIXTURE}
'@
$result = Find-OnlineDomTranslationHook $fixture -Quiet
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$result | ConvertTo-Json -Compress
'''


def find_function_region(source: str) -> str:
    """Return the patcher's definitions without its executable main flow.

    The script ends with an unconditional `param(...)` block plus function
    definitions followed by a top-level `try {` main flow; we drop the param
    block and everything from `try {` onward so the functions can be loaded
    without running an install.
    """
    import re

    main_flow = re.search(r"(?m)^try \{", source)
    if main_flow is None:
        raise AssertionError("could not locate main flow in install_windows.ps1")
    body = source[: main_flow.start()]
    lines = body.split("\n")
    close = next(i for i, line in enumerate(lines) if line.strip() == ")")
    return "\n".join(lines[close + 1 :])


def run_hook_scan(fixture: str) -> dict:
    pwsh = shutil.which("pwsh")
    if pwsh is None:
        raise unittest.SkipTest("pwsh not available")
    source = WINDOWS_PATCHER.read_text(encoding="utf-8-sig")
    functions = find_function_region(source)
    harness = HARNESS.replace("{PARAMS_AND_FUNCTIONS}", functions).replace("{FIXTURE}", fixture)
    proc = subprocess.run(
        [pwsh, "-NoProfile", "-NonInteractive", "-Command", harness],
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=120,
    )
    if proc.returncode != 0:
        raise AssertionError(
            f"pwsh failed ({proc.returncode}):\nstdout: {proc.stdout}\nstderr: {proc.stderr}"
        )
    return json.loads(proc.stdout)


class WindowsDomHookScanTest(unittest.TestCase):
    def test_new_bundle_parenthesized_handler(self):
        result = run_hook_scan(NEW_FORMAT)
        self.assertTrue(result["Success"], result)
        self.assertEqual(result["Receiver"], "c")
        self.assertEqual(
            result["Body"],
            "let ok=canLoad();d=ok?Date.now():void 0,track(ok?c.webContents:null)",
        )
        self.assertEqual(result["Terminator"], ",")
        self.assertEqual(result["EventQuote"], "`")

    def test_old_bundle_plain_handler_still_works(self):
        result = run_hook_scan(OLD_FORMAT)
        self.assertTrue(result["Success"], result)
        self.assertEqual(result["Receiver"], "r")
        self.assertEqual(result["Body"], "a0()")
        self.assertEqual(result["Terminator"], ";")
        self.assertEqual(result["EventQuote"], '"')


if __name__ == "__main__":
    unittest.main()
