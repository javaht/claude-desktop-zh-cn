from __future__ import annotations

import importlib.util
import json
import plistlib
import shutil
import sys
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
# macos_auto_repair does `import patch_claude_zh_cn`; register the already
# loaded instance so both modules share state and mock.patch.object works.
sys.modules["patch_claude_zh_cn"] = patcher

auto_repair = None
if sys.platform != "win32":  # fcntl/pwd imports are Unix-only
    AUTO_REPAIR_SPEC = importlib.util.spec_from_file_location(
        "macos_auto_repair",
        ROOT / "scripts/macos_auto_repair.py",
    )
    assert AUTO_REPAIR_SPEC and AUTO_REPAIR_SPEC.loader
    auto_repair = importlib.util.module_from_spec(AUTO_REPAIR_SPEC)
    AUTO_REPAIR_SPEC.loader.exec_module(auto_repair)


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

    def test_doctor_flags_selected_bundle_with_missing_anchor(self) -> None:
        # The legacy-path fallback in find_main_process_asar_target can select
        # a bundle whose dom-ready anchor is gone; doctor must not report that
        # as full-compatible (upstream-watch relies on this signal).
        app = make_app(self.root, "9.9.9", "999")
        make_frontend(app)
        write_single_file_asar(app, ".vite/build/index.js", b"console.log('no anchor');")
        report = patcher.doctor_report(app, "zh-CN")
        self.assertTrue(report["basicCompatible"])
        self.assertFalse(report["checks"]["asarFullPatch"]["ok"])
        self.assertFalse(report["fullCompatible"])

        anchored = b'a.webContents.on("dom-ready",()=>{t.track("main_view_dom_ready")});'
        app2 = make_app(self.root / "anchored", "9.9.9", "999")
        make_frontend(app2)
        write_single_file_asar(app2, ".vite/build/index.js", anchored)
        report2 = patcher.doctor_report(app2, "zh-CN")
        self.assertTrue(report2["checks"]["asarFullPatch"]["ok"])
        self.assertTrue(report2["fullCompatible"])

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


@unittest.skipIf(sys.platform == "win32", "macos_auto_repair is Unix-only (fcntl/pwd)")
class AutoRepairTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def test_log_rotation_only_when_over_cap(self) -> None:
        log_path = self.tmp / "auto-repair.log"
        rotated = self.tmp / "auto-repair.log.old"
        with mock.patch.object(patcher, "AUTO_REPAIR_LOG", log_path):
            auto_repair.rotate_log_if_needed()  # missing file is a no-op
            log_path.write_bytes(b"x" * (auto_repair.LOG_ROTATE_BYTES - 1))
            auto_repair.rotate_log_if_needed()
            self.assertTrue(log_path.exists())
            self.assertFalse(rotated.exists())
            log_path.write_bytes(b"x" * auto_repair.LOG_ROTATE_BYTES)
            auto_repair.rotate_log_if_needed()
            self.assertFalse(log_path.exists())
            self.assertTrue(rotated.exists())

    def test_claude_is_running_uses_anchored_bundle_prefix(self) -> None:
        app = Path("/Applications/Claude.app")
        with mock.patch.object(auto_repair.subprocess, "run") as run:
            run.return_value = mock.Mock(returncode=0)
            self.assertTrue(auto_repair.claude_is_running(app))
        argv = run.call_args[0][0]
        self.assertEqual(argv[:2], ["/usr/bin/pgrep", "-f"])
        pattern = argv[2]
        # Anchored to argv[0] and scoped inside the bundle: unrelated commands
        # that merely mention the path in an argument must not match.
        self.assertTrue(pattern.startswith("^"))
        self.assertIn("Contents/", pattern)
        self.assertIn(r"Claude\.app", pattern)

    def test_failure_backoff_quadrants(self) -> None:
        fingerprint = {"identity": {"version": "1.0"}, "asarSize": 1}
        base = {
            "failedFingerprint": fingerprint,
            "patchRelease": "1.4.2",
            "failedAt": 1_000_000.0,
        }
        with mock.patch.object(auto_repair.time, "time", return_value=1_000_000.0 + 60):
            self.assertTrue(auto_repair.failure_is_backed_off(base, fingerprint, "1.4.2"))
            self.assertFalse(
                auto_repair.failure_is_backed_off(base, {"identity": {}, "asarSize": 2}, "1.4.2")
            )
            self.assertFalse(auto_repair.failure_is_backed_off(base, fingerprint, "1.4.3"))
            self.assertFalse(
                auto_repair.failure_is_backed_off({**base, "failedAt": "bad"}, fingerprint, "1.4.2")
            )
        after = 1_000_000.0 + auto_repair.FAILURE_RETRY_SECONDS + 1
        with mock.patch.object(auto_repair.time, "time", return_value=after):
            self.assertFalse(auto_repair.failure_is_backed_off(base, fingerprint, "1.4.2"))

    def test_quit_claude_for_user_delivers_via_launchctl_asuser(self) -> None:
        app = Path("/Applications/Claude.app")
        calls: list[list[str]] = []

        def fake_run(argv, **kwargs):
            calls.append(argv)
            return mock.Mock(returncode=0)

        running = iter([True, False])  # running before quit, gone afterwards
        with (
            mock.patch.object(auto_repair, "claude_is_running", lambda _: next(running)),
            mock.patch.object(auto_repair.subprocess, "run", side_effect=fake_run),
            mock.patch.object(auto_repair.pwd, "getpwuid") as getpwuid,
            mock.patch.object(Path, "stat") as stat,
        ):
            stat.return_value = mock.Mock(st_uid=501)
            getpwuid.return_value = mock.Mock(pw_name="tester")
            self.assertTrue(auto_repair.quit_claude_for_user(app, Path("/Users/tester")))
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][:3], ["/bin/launchctl", "asuser", "501"])
        self.assertIn("/usr/bin/osascript", calls[0])
        self.assertIn(
            f'tell application id "{auto_repair.CLAUDE_BUNDLE_ID}" to quit', calls[0]
        )

    def test_quit_claude_for_user_reports_lingering_process(self) -> None:
        app = Path("/Applications/Claude.app")
        with (
            mock.patch.object(auto_repair, "claude_is_running", return_value=True),
            mock.patch.object(auto_repair.subprocess, "run") as run,
            mock.patch.object(auto_repair.pwd, "getpwuid") as getpwuid,
            mock.patch.object(Path, "stat") as stat,
            mock.patch.object(auto_repair, "QUIT_WAIT_SECONDS", 0),
        ):
            stat.return_value = mock.Mock(st_uid=501)
            getpwuid.return_value = mock.Mock(pw_name="tester")
            run.return_value = mock.Mock(returncode=0)
            self.assertFalse(auto_repair.quit_claude_for_user(app, Path("/Users/tester")))


if __name__ == "__main__":
    unittest.main()
