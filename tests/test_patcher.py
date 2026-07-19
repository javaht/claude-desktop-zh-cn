from __future__ import annotations

import importlib.util
import json
import plistlib
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "patch_claude_zh_cn",
    ROOT / "scripts/patch_claude_zh_cn.py",
)
assert SPEC and SPEC.loader
patcher = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(patcher)


def make_app(root: Path, version: str, build: str, asar: bytes = b"official-asar") -> Path:
    app = root / "Claude.app"
    resources = app / "Contents/Resources"
    resources.mkdir(parents=True)
    with (app / "Contents/Info.plist").open("wb") as f:
        plistlib.dump(
            {
                "CFBundleIdentifier": "com.anthropic.claudefordesktop",
                "CFBundleShortVersionString": version,
                "CFBundleVersion": build,
            },
            f,
        )
    (resources / "app.asar").write_bytes(asar)
    return app


def make_frontend(app: Path, asset_version: str = "v2") -> tuple[Path, Path]:
    i18n = app / "Contents/Resources/ion-dist/locales"
    assets = app / f"Contents/Resources/ion-dist/assets/{asset_version}"
    i18n.mkdir(parents=True)
    assets.mkdir(parents=True)
    (i18n / "en-US.json").write_text(
        json.dumps({"hello": "Hello", "new": "New upstream text"}),
        encoding="utf-8",
    )
    bundle = assets / "app-HASH.js"
    bundle.write_text(
        "const languageOptions = ['fr-FR', 'en-US', 'nl-NL', 'de-DE', "
        "'ja-JP', 'ko-KR', 'id-ID'];",
        encoding="utf-8",
    )
    return i18n, bundle


def write_minimal_asar(app: Path) -> None:
    header = {
        "files": {
            "empty.js": {
                "size": 0,
                "offset": "0",
                "integrity": patcher.calculate_file_integrity(b""),
            },
            "next.js": {
                "size": 4,
                "offset": "0",
                "integrity": patcher.calculate_file_integrity(b"NEXT"),
            },
        }
    }
    header_string = json.dumps(header, separators=(",", ":"))
    (app / patcher.APP_ASAR_REL).write_bytes(
        patcher.encode_asar_header_dynamic(header_string) + b"NEXT"
    )


def write_single_file_asar(app: Path, file_path: str, content: bytes) -> None:
    files: dict[str, object] = {}
    cursor = files
    parts = file_path.split("/")
    for part in parts[:-1]:
        node: dict[str, object] = {"files": {}}
        cursor[part] = node
        cursor = node["files"]  # type: ignore[assignment]
    cursor[parts[-1]] = {
        "size": len(content),
        "offset": "0",
        "integrity": patcher.calculate_file_integrity(content),
    }
    header_string = json.dumps({"files": files}, separators=(",", ":"))
    (app / patcher.APP_ASAR_REL).write_bytes(
        patcher.encode_asar_header_dynamic(header_string) + content
    )


class PatcherTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_semantic_whitelist_supports_v2_and_preserves_upstream_locales(self) -> None:
        app = make_app(self.root, "2.0.0", "200")
        _i18n, bundle = make_frontend(app, "v2")

        selected = patcher.patch_language_whitelist(app, "zh-CN")
        patcher.patch_language_display_names(app, selected)
        text = bundle.read_text(encoding="utf-8")

        self.assertEqual(selected, bundle)
        self.assertIn('"nl-NL"', text)
        self.assertEqual(text.count('"zh-CN"'), 2)  # whitelist plus display-name runtime patch
        self.assertIn("__claudeZhLabelPatch", text)

    def test_frontend_merge_discovers_locales_and_falls_back_to_current_english(self) -> None:
        app = make_app(self.root, "2.0.0", "200")
        i18n, _bundle = make_frontend(app)
        resource_root = self.root / "pack"
        resource_root.mkdir()
        (resource_root / "frontend-zh-CN.json").write_text(
            json.dumps({"hello": "你好", "removed": "旧字段"}),
            encoding="utf-8",
        )

        with mock.patch.object(patcher, "RESOURCES", resource_root):
            translated, fallback, extra = patcher.merge_frontend_locale(app, "zh-CN")

        merged = json.loads((i18n / "zh-CN.json").read_text(encoding="utf-8"))
        self.assertEqual(merged, {"hello": "你好", "new": "New upstream text"})
        self.assertEqual((translated, fallback, extra), (1, 1, 1))

    def test_cross_version_backup_is_never_restored_into_official_update(self) -> None:
        current = make_app(self.root, "2.0.0", "200", b"v2")
        stale_root = self.root / "stale"
        stale = make_app(stale_root, "1.0.0", "100", b"v1")
        stale_backup = self.root / "Claude.backup-before-zh-CN-20260101-000000.app"
        shutil.move(str(stale), str(stale_backup))

        restored = patcher.restore_oldest_backup(current, dry_run=False)

        self.assertIsNone(restored)
        self.assertEqual(patcher.get_app_identity(current)["version"], "2.0.0")
        self.assertFalse(stale_backup.exists())

    def test_matching_marker_restores_exact_source_backup(self) -> None:
        source_root = self.root / "source"
        source = make_app(source_root, "2.0.0", "200", b"source-v2")
        current = make_app(self.root, "2.0.0", "200", b"patched-v2")
        backup = self.root / "Claude.backup-before-zh-CN-20260101-000000.app"
        shutil.copytree(source, backup)
        patcher.write_patch_marker(current, source, "zh-CN", "safe")

        restored = patcher.restore_oldest_backup(current, dry_run=False)

        self.assertEqual(restored, backup)
        self.assertEqual((current / patcher.APP_ASAR_REL).read_bytes(), b"source-v2")
        self.assertIsNone(patcher.read_patch_marker(current))

    def test_current_marker_detects_in_place_asar_replacement(self) -> None:
        app = make_app(self.root, "2.0.0", "200", b"patched-asar")
        i18n, _bundle = make_frontend(app)
        patcher.patch_language_whitelist(app, "zh-CN")
        (i18n / "zh-CN.json").write_text('{"hello":"你好"}', encoding="utf-8")
        patcher.write_patch_marker(app, app, "zh-CN", "full")

        self.assertTrue(patcher.patch_is_current(app, "zh-CN", "full"))
        (app / patcher.APP_ASAR_REL).write_bytes(b"upstream-replaced-asar")
        self.assertFalse(patcher.patch_is_current(app, "zh-CN", "full"))

    def test_in_place_update_discards_stale_marker_and_old_backup(self) -> None:
        old_root = self.root / "old"
        old = make_app(old_root, "1.0.0", "100", b"old-official")
        current = make_app(self.root, "2.0.0", "200", b"new-official")
        stale_backup = self.root / "Claude.backup-before-zh-CN-20260101-000000.app"
        shutil.copytree(old, stale_backup)
        patcher.write_patch_marker(current, old, "zh-CN", "full")

        prepared_root = self.root / "prepared"
        prepared = make_app(prepared_root, "2.0.0", "200", b"new-patched")
        patcher.backup_and_replace(current, prepared, dry_run=False)

        backups = patcher.find_app_backups(current)
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / patcher.APP_ASAR_REL).read_bytes(), b"new-official")
        self.assertIsNone(patcher.read_patch_marker(backups[0]))
        self.assertFalse(stale_backup.exists())
        self.assertEqual((current / patcher.APP_ASAR_REL).read_bytes(), b"new-patched")

    def test_commit_failure_rolls_original_app_back(self) -> None:
        original = make_app(self.root, "2.0.0", "200", b"original")
        patched_root = self.root / "prepared"
        patched = make_app(patched_root, "2.0.0", "200", b"patched")
        real_move = shutil.move
        calls = 0

        def flaky_move(src: str, dst: str) -> str:
            nonlocal calls
            calls += 1
            if calls == 2:
                raise OSError("injected commit failure")
            return real_move(src, dst)

        with mock.patch.object(patcher.shutil, "move", side_effect=flaky_move):
            with self.assertRaisesRegex(OSError, "injected"):
                patcher.backup_and_replace(original, patched, dry_run=False)

        self.assertTrue(original.exists())
        self.assertEqual((original / patcher.APP_ASAR_REL).read_bytes(), b"original")
        self.assertEqual(patcher.find_app_backups(original), [])

    def test_safe_mode_never_calls_asar_patchers(self) -> None:
        source = self.root / "source.app"
        target = self.root / "target.app"
        structural_names = [
            "patch_online_locale_preload",
            "patch_online_locale_main_process",
            "patch_hardcoded_main_process_menu_labels",
            "patch_custom3p_model_validation",
            "patch_model_picker_strings",
        ]
        mocks = {name: mock.patch.object(patcher, name) for name in structural_names}
        started = [item.start() for item in mocks.values()]
        self.addCleanup(lambda: [item.stop() for item in mocks.values()])
        baseline = [
            mock.patch.object(patcher, "copy_app"),
            mock.patch.object(patcher, "patch_language_whitelist", return_value=Path("bundle.js")),
            mock.patch.object(patcher, "patch_hardcoded_frontend_strings"),
            mock.patch.object(patcher, "patch_language_display_names"),
            mock.patch.object(patcher, "merge_frontend_locale"),
            mock.patch.object(patcher, "install_desktop_locale"),
            mock.patch.object(patcher, "install_statsig_locale"),
            mock.patch.object(patcher, "write_patch_marker"),
            mock.patch.object(patcher, "resign_app"),
            mock.patch.object(patcher, "clear_quarantine"),
            mock.patch.object(patcher, "verify"),
        ]
        baseline_mocks = [item.start() for item in baseline]
        self.addCleanup(lambda: [item.stop() for item in baseline])

        patcher.prepare_patched_app(source, target, "zh-CN", True)

        for structural_mock in started:
            structural_mock.assert_not_called()
        baseline_mocks[-1].assert_called_once_with(
            target,
            "zh-CN",
            expect_online_patch=False,
            verify_asar=False,
        )

    def test_growing_empty_asar_entry_moves_following_shared_offset(self) -> None:
        app = make_app(self.root, "2.0.0", "200")
        write_minimal_asar(app)

        with mock.patch.object(patcher, "update_electron_asar_integrity"):
            patcher.replace_asar_file_content(app, "empty.js", b"PATCH")

        data = (app / patcher.APP_ASAR_REL).read_bytes()
        header_size, _header_string, header = patcher.read_asar_header(data, app / patcher.APP_ASAR_REL)
        empty_entry = patcher.get_asar_file_entry(header, "empty.js")
        next_entry = patcher.get_asar_file_entry(header, "next.js")
        self.assertEqual(
            patcher.read_asar_entry_content(data, header_size, empty_entry, "empty.js"),
            b"PATCH",
        )
        self.assertEqual(
            patcher.read_asar_entry_content(data, header_size, next_entry, "next.js"),
            b"NEXT",
        )
        self.assertEqual(int(next_entry["offset"]), 5)

    def test_hashed_main_process_chunk_is_discovered_dynamically(self) -> None:
        app = make_app(self.root, "2.0.0", "200")
        hashed_path = ".vite/build/index.chunk-DINfBFDm.js"
        write_single_file_asar(
            app,
            hashed_path,
            f"/*{patcher.ONLINE_LOCALE_MAIN_MARKER}*/".encode(),
        )

        asar_path = app / patcher.APP_ASAR_REL
        data = asar_path.read_bytes()
        header_size, _header_string, header = patcher.read_asar_header(data, asar_path)

        self.assertEqual(
            patcher.find_main_process_asar_target(data, header_size, header),
            hashed_path,
        )

    def test_resource_manifests_match_actual_key_counts(self) -> None:
        manifests = {
            "zh-CN": "manifest.json",
            "zh-TW": "manifest-zh-TW.json",
            "zh-HK": "manifest-zh-HK.json",
        }
        for language, manifest_name in manifests.items():
            with self.subTest(language=language):
                manifest = json.loads((ROOT / "resources" / manifest_name).read_text(encoding="utf-8"))
                frontend = json.loads(
                    (ROOT / "resources" / f"frontend-{language}.json").read_text(encoding="utf-8")
                )
                desktop = json.loads(
                    (ROOT / "resources" / f"desktop-{language}.json").read_text(encoding="utf-8")
                )
                self.assertEqual(manifest["language"], language)
                self.assertEqual(manifest["frontend_strings"], len(frontend))
                self.assertEqual(manifest["desktop_shell_strings"], len(desktop))


if __name__ == "__main__":
    unittest.main()
