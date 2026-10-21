"""Synthetic menu fixtures exercise code generation without launching Electron."""
import importlib.util
import json
import re
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("patcher", ROOT / "scripts/patch_claude_zh_cn.py")
patcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patcher)
FIXTURE = (ROOT / "tests/fixtures/slash-command-menu.js").read_text(encoding="utf-8")
LANGUAGES = ("zh-CN", "zh-TW", "zh-HK")


class SlashCommandMenuTests(unittest.TestCase):
    def test_locales_have_same_commands_and_terminology(self):
        catalogs = [patcher.load_slash_command_gloss_config(lang)[1] for lang in LANGUAGES]
        self.assertEqual(set(catalogs[0]), set(catalogs[1]))
        self.assertEqual(set(catalogs[0]), set(catalogs[2]))
        self.assertEqual(catalogs[1]["plugin"], "管理外掛程式")
        self.assertEqual(catalogs[2]["plugin"], "管理插件")

    def test_generation_and_runtime_for_all_locales(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            for lang in LANGUAGES:
                profile, labels = patcher.load_slash_command_gloss_config(lang)
                updated, status = patcher.replace_slash_command_menu_text(FIXTURE, profile, labels)
                self.assertEqual(status, "updated")
                self.assertIn('anthropicDefined===!0', updated)
                result = directory / (lang + ".js")
                result.write_text(updated, encoding="utf-8")
                subprocess.run(["node", "--check", str(result)], check=True, capture_output=True)
                subprocess.run(["node", str(ROOT / "tests/test_slash_menu_runtime.cjs"), str(result), lang], check=True)
                self.assertEqual(patcher.replace_slash_command_menu_text(updated, profile, labels), (updated, "already"))

    def test_language_switch_and_repeat_installation(self):
        profile, cn = patcher.load_slash_command_gloss_config("zh-CN")
        _, tw = patcher.load_slash_command_gloss_config("zh-TW")
        first, _ = patcher.replace_slash_command_menu_text(FIXTURE, profile, cn)
        second, _ = patcher.replace_slash_command_menu_text(first, profile, tw)
        self.assertEqual(second.count(profile["marker"]), 1)
        self.assertIn("管理外掛程式", second)
        self.assertNotIn("管理插件", second)
        self.assertEqual(patcher.replace_slash_command_menu_text(second, profile, tw), (second, "already"))

    def test_changed_minified_aliases_are_supported(self):
        renamed = FIXTURE.replace("jsx", "render$node").replace("HighlightedText", "H").replace("item", "entry").replace("query", "q")
        # The query property name is part of the component contract, not a local alias.
        renamed = renamed.replace("q:q", "query:q")
        profile, labels = patcher.load_slash_command_gloss_config("zh-CN")
        updated, _ = patcher.replace_slash_command_menu_text(renamed, profile, labels)
        self.assertIn('render$node("span",', updated)
        self.assertIn('entry.anthropicDefined', updated)

    def test_template_tokens_do_not_rewrite_captured_aliases(self):
        special = re.sub(r"\bjsx\b", "__ITEM__", FIXTURE)
        special = re.sub(r"\bitem\b", "__JSX__", special)
        profile, labels = patcher.load_slash_command_gloss_config("zh-CN")
        updated, _ = patcher.replace_slash_command_menu_text(special, profile, labels)
        self.assertIn('__ITEM__(HighlightedText, {text:__JSX__.label', updated)
        self.assertIn('__JSX__.anthropicDefined', updated)
        self.assertEqual(patcher.replace_slash_command_menu_text(updated, profile, labels), (updated, "already"))

    def test_changed_catalog_key_casing_is_corrected(self):
        profile, labels = patcher.load_slash_command_gloss_config("zh-CN")
        updated, _ = patcher.replace_slash_command_menu_text(FIXTURE, profile, labels)
        modified = updated.replace('"model":', '"Model":')
        corrected, status = patcher.replace_slash_command_menu_text(modified, profile, labels)
        self.assertEqual(status, "updated")
        self.assertEqual(corrected, updated)

    def test_missing_ambiguous_and_wrong_component_anchors_fail_closed(self):
        profile, labels = patcher.load_slash_command_gloss_config("zh-CN")
        anchor = 'children: jsx(HighlightedText, {text:item.label,query:query,highlightClassName:"font-semibold"})'
        bad = [
            FIXTURE.replace(anchor, "children: null"),
            FIXTURE + '\nconst duplicate={' + anchor + '};',
            FIXTURE.replace("SlashCommandMenuPopupBody", "MenuItems"),
            FIXTURE + '\nfunction __claudeZhSlashGloss(){}',
        ]
        for source in bad:
            with self.subTest(source=source[-80:]):
                with self.assertRaises(ValueError):
                    patcher.replace_slash_command_menu_text(source, profile, labels)

    def test_corrupt_existing_patch_is_not_overwritten(self):
        profile, labels = patcher.load_slash_command_gloss_config("zh-CN")
        updated, _ = patcher.replace_slash_command_menu_text(FIXTURE, profile, labels)
        bad = [
            FIXTURE + '\n' + profile["marker"],
            updated + profile["marker"],
            updated.replace('anthropicDefined===!0', 'anthropicDefined===!1'),
            updated.replace(';const __claudeZhSlashLabels=', ';const bad='),
        ]
        for source in bad:
            with self.assertRaises(ValueError):
                patcher.replace_slash_command_menu_text(source, profile, labels)

    def test_installer_wrapper_skips_unknown_versions_without_writes(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp)
            assets = app / patcher.FRONTEND_ASSETS_REL
            assets.mkdir(parents=True)
            decoy = assets / "add-menu.js"
            decoy.write_text(FIXTURE.replace("SlashCommandMenuPopupBody", "MenuItems"), encoding="utf-8")
            before = decoy.read_bytes()
            with patch.object(patcher, "log") as log:
                self.assertEqual(patcher.patch_slash_command_menu(app, "zh-CN"), 0)
                self.assertIn("WARNING", log.call_args.args[0])
            self.assertEqual(before, decoy.read_bytes())
            menu = assets / "menu.js"
            menu.write_text(FIXTURE, encoding="utf-8")
            self.assertEqual(patcher.patch_slash_command_menu(app, "zh-CN"), 1)
            self.assertEqual(patcher.patch_slash_command_menu(app, "zh-CN"), 0)
            self.assertEqual(before, decoy.read_bytes())
            another = assets / "second-menu.js"
            another.write_text(FIXTURE, encoding="utf-8")
            before_menu = menu.read_bytes()
            self.assertEqual(patcher.patch_slash_command_menu(app, "zh-CN"), 0)
            self.assertEqual(menu.read_bytes(), before_menu)
            self.assertEqual(another.read_text(encoding="utf-8"), FIXTURE)


if __name__ == "__main__":
    unittest.main()
