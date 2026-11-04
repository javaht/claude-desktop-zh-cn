"""ASAR frontend support for Claude Desktop 4.29+ (ion-dist.asar)."""
import importlib.util
import json
import plistlib
import struct
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("patcher", ROOT / "scripts/patch_claude_zh_cn.py")
patcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patcher)

NEEDLE = '"en-US","de-DE","fr-FR","ko-KR","ja-JP"'


def make_frontend_source(root: Path) -> None:
    assets = root / "assets" / "v1"
    i18n = root / "i18n"
    dynamic = i18n / "dynamic"
    for directory in (assets, dynamic):
        directory.mkdir(parents=True, exist_ok=True)
    (assets / "index-abc.js").write_text(f'const l=[{NEEDLE}];', encoding="utf-8")
    (i18n / "en-US.json").write_text('{"hello":"Hello"}', encoding="utf-8")
    (dynamic / "en-US.json").write_text('{"m":"Model"}', encoding="utf-8")
    (root / "index.html").write_text("<html></html>", encoding="utf-8")


def write_raw_asar(path: Path, header: dict) -> None:
    header_string = json.dumps(header, separators=(",", ":"))
    header_bytes = header_string.encode("utf-8")
    payload_size = patcher.align4(4 + len(header_bytes))
    header_size = 4 + payload_size
    payload = (
        struct.pack("<II", payload_size, len(header_bytes))
        + header_bytes
        + b"\x00" * (payload_size - 4 - len(header_bytes))
    )
    path.write_bytes(struct.pack("<II", 4, header_size) + payload)


class AsarFrontendTests(unittest.TestCase):
    def test_round_trip_preserves_header_and_contents(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            source = tmp / "source"
            make_frontend_source(source)
            archive = tmp / "ion-dist.asar"
            patcher.build_asar(source, archive)

            data = archive.read_bytes()
            header_size, header_string, header = patcher.read_asar_header(data, archive)
            entries = dict(patcher.walk_asar_entries(header))
            self.assertIn("i18n/en-US.json", entries)
            self.assertEqual(
                patcher.read_asar_entry(data, header_size, header, "index.html"),
                b"<html></html>",
            )

            extracted = tmp / "extracted"
            patcher.extract_asar(archive, extracted)
            self.assertEqual(
                (extracted / "assets/v1/index-abc.js").read_text(encoding="utf-8"),
                f'const l=[{NEEDLE}];',
            )

            rebuilt = tmp / "rebuilt.asar"
            patcher.build_asar(extracted, rebuilt)
            rebuilt_data = rebuilt.read_bytes()
            rebuilt_header_size, rebuilt_header_string, rebuilt_header = patcher.read_asar_header(
                rebuilt_data, rebuilt
            )
            self.assertEqual(header_string, rebuilt_header_string)
            self.assertEqual(
                patcher.asar_header_hash(header_string),
                patcher.asar_header_hash(rebuilt_header_string),
            )
            for relative in entries:
                self.assertEqual(
                    patcher.read_asar_entry(data, header_size, header, relative),
                    patcher.read_asar_entry(rebuilt_data, rebuilt_header_size, rebuilt_header, relative),
                    relative,
                )

    def test_extract_rejects_unsafe_paths(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            archive = tmp / "evil.asar"
            write_raw_asar(archive, {"files": {"..": {"size": 1, "offset": "0"}}})
            with self.assertRaises(SystemExit):
                patcher.extract_asar(archive, tmp / "out")

    def test_prepare_and_finalize_frontend_target(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            app = tmp / "Claude.app"
            resources = app / "Contents/Resources"
            resources.mkdir(parents=True)
            source = tmp / "source"
            make_frontend_source(source)
            frontend_asar = resources / "ion-dist.asar"
            patcher.build_asar(source, frontend_asar)

            app_source = tmp / "app-source"
            app_source.mkdir()
            (app_source / "main.js").write_text("// main", encoding="utf-8")
            app_asar = resources / "app.asar"
            patcher.build_asar(app_source, app_asar)

            app_hash = patcher.asar_header_hash(
                patcher.read_asar_header(app_asar.read_bytes(), app_asar)[1]
            )
            frontend_hash = patcher.asar_header_hash(
                patcher.read_asar_header(frontend_asar.read_bytes(), frontend_asar)[1]
            )
            info = {
                "CFBundleIdentifier": "com.example.test",
                "ElectronAsarIntegrity": {
                    "Resources/app.asar": {"algorithm": "SHA256", "hash": app_hash},
                    "Resources/ion-dist.asar": {"algorithm": "SHA256", "hash": frontend_hash},
                },
            }
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY))

            self.assertEqual(patcher.get_frontend_bundle_mode(app), "asar")
            target = patcher.prepare_frontend_target(app)
            try:
                self.assertEqual(target["mode"], "asar")
                work = target["work"]
                self.assertTrue((work / "i18n/en-US.json").is_file())
                (work / "i18n/zh-CN.json").write_text('{"hello":"你好"}', encoding="utf-8")
                patcher.finalize_frontend_target(app, target)
            finally:
                patcher.cleanup_frontend_target(target)

            self.assertFalse((resources / "ion-dist").exists())
            self.assertEqual(patcher.read_frontend_entry(app, "i18n/zh-CN.json"), '{"hello":"你好"}'.encode())
            self.assertIsNone(patcher.read_frontend_entry(app, "i18n/missing.json"))

            new_hash = patcher.asar_header_hash(
                patcher.read_asar_header(frontend_asar.read_bytes(), frontend_asar)[1]
            )
            self.assertNotEqual(new_hash, frontend_hash)
            updated = plistlib.loads((app / "Contents/Info.plist").read_bytes())
            self.assertEqual(updated["ElectronAsarIntegrity"]["Resources/ion-dist.asar"]["hash"], new_hash)
            self.assertEqual(updated["ElectronAsarIntegrity"]["Resources/app.asar"]["hash"], app_hash)
            patcher.verify_electron_asar_integrity(app)

    def test_directory_mode_is_untouched(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / "Claude.app"
            assets = app / "Contents/Resources/ion-dist/assets/v1"
            assets.mkdir(parents=True)
            (assets / "index-abc.js").write_text(f'const l=[{NEEDLE}];', encoding="utf-8")
            target = patcher.prepare_frontend_target(app)
            self.assertEqual(target["mode"], "directory")
            self.assertFalse((app / "Contents/Resources/ion-dist.asar").exists())

    def test_placeholder_directory_coexists_with_asar(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            app = tmp / "Claude.app"
            resources = app / "Contents/Resources"
            resources.mkdir(parents=True)
            source = tmp / "source"
            make_frontend_source(source)
            patcher.build_asar(source, resources / "ion-dist.asar")
            placeholder = resources / "ion-dist"
            placeholder.mkdir()
            (placeholder / "index.html").write_text("<html>Claude was updated</html>", encoding="utf-8")

            target = patcher.prepare_frontend_target(app)
            try:
                self.assertEqual(target["mode"], "asar")
                self.assertTrue((target["work"] / "assets/v1/index-abc.js").is_file())
            finally:
                patcher.cleanup_frontend_target(target)

    def test_directory_with_js_blocks_asar_layout(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            app = tmp / "Claude.app"
            resources = app / "Contents/Resources"
            resources.mkdir(parents=True)
            source = tmp / "source"
            make_frontend_source(source)
            patcher.build_asar(source, resources / "ion-dist.asar")
            stray = resources / "ion-dist/assets/v1"
            stray.mkdir(parents=True)
            (stray / "index-abc.js").write_text("// stray", encoding="utf-8")

            with self.assertRaises(SystemExit):
                patcher.prepare_frontend_target(app)

    def test_language_whitelist_patches_every_chunk(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            app = tmp / "Claude.app"
            resources = app / "Contents/Resources"
            resources.mkdir(parents=True)
            source = tmp / "source"
            make_frontend_source(source)
            assets = source / "assets/v1"
            language_list = f'{patcher.BASE_LANGUAGE_LIST}];'
            for name in ("shared-123.js", "shared-62.js"):
                (assets / name).write_text(f"const a={language_list}", encoding="utf-8")
            patcher.build_asar(source, resources / "ion-dist.asar")

            target = patcher.prepare_frontend_target(app)
            try:
                patcher.patch_language_whitelist(app, "zh-CN")
                for name in ("shared-123.js", "shared-62.js"):
                    text = (target["work"] / "assets/v1" / name).read_text(encoding="utf-8")
                    self.assertIn('"zh-CN"', text, name)
            finally:
                patcher.cleanup_frontend_target(target)

    def test_missing_bundle_raises(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / "Claude.app"
            (app / "Contents/Resources").mkdir(parents=True)
            with self.assertRaises(SystemExit):
                patcher.prepare_frontend_target(app)

    def test_integrity_digest_slot_is_synced_per_slice(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / "Claude.app"
            framework = app / patcher.ELECTRON_FRAMEWORK_REL
            framework.parent.mkdir(parents=True)
            sentinel = patcher.INTEGRITY_DIGEST_SENTINEL
            slot = sentinel + bytes([1, 1]) + bytes(32)
            fail_open = sentinel + bytes([0, 0]) + bytes(32)
            framework.write_bytes(b"PAD" + slot + b"MID" + slot + b"OPEN" + fail_open + b"END")

            integrity = {
                "Resources/app.asar": {"algorithm": "SHA256", "hash": "a" * 64},
                "Resources/ion-dist.asar": {"algorithm": "SHA256", "hash": "b" * 64},
            }
            self.assertEqual(patcher.sync_integrity_digest_slot(app, integrity), 2)
            expected = bytes.fromhex(patcher.compute_integrity_dictionary_digest(integrity))
            data = framework.read_bytes()
            self.assertEqual(data.count(expected), 2)
            self.assertEqual(data.count(b"\x00" * 32), 1)  # used=0 slot stays fail-open
            patcher.verify_integrity_digest_slot(app, integrity)

            integrity["Resources/ion-dist.asar"]["hash"] = "c" * 64
            with self.assertRaises(SystemExit):
                patcher.verify_integrity_digest_slot(app, integrity)

    def test_integrity_entry_absent_is_a_noop(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            app = tmp / "Claude.app"
            resources = app / "Contents/Resources"
            resources.mkdir(parents=True)
            source = tmp / "source"
            source.mkdir()
            (source / "a.txt").write_text("a", encoding="utf-8")
            asar = resources / "ion-dist.asar"
            patcher.build_asar(source, asar)
            info = {"ElectronAsarIntegrity": {"Resources/app.asar": {"algorithm": "SHA256", "hash": "0" * 64}}}
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
            self.assertFalse(patcher.update_electron_asar_integrity(app, "Resources/ion-dist.asar", asar))


if __name__ == "__main__":
    unittest.main()
