"""Linux frontend patcher (scripts/patch_linux_asar.py) behaviour."""
import contextlib
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("linux_patcher", ROOT / "scripts/patch_linux_asar.py")
linux_patcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(linux_patcher)
patcher = linux_patcher.patcher

WHITELIST_JS = f"const a=[{patcher.BASE_LANGUAGE_LIST}];"


def run_patch(*args, **kwargs):
    """Patch with the log output captured.

    The patcher logs in Chinese; printing it would fail on consoles using a
    legacy code page (for example the cp1252 stdout of a Windows CI runner).
    """
    with contextlib.redirect_stdout(io.StringIO()):
        linux_patcher.patch(*args, **kwargs)


def make_frontend(root: Path) -> None:
    assets = root / "assets"
    assets.mkdir(parents=True)
    (assets / "index-abc.js").write_text(WHITELIST_JS, encoding="utf-8")
    (assets / "shared-1.js").write_text(WHITELIST_JS, encoding="utf-8")
    i18n = root / "i18n"
    (i18n / "dynamic").mkdir(parents=True)
    (i18n / "statsig").mkdir()
    (i18n / "en-US.json").write_text(json.dumps({"hello": "Hello", "extra": "Extra"}), encoding="utf-8")
    (i18n / "dynamic" / "en-US.json").write_text(json.dumps({"model": "Model"}), encoding="utf-8")
    (i18n / "statsig" / "en-US.json").write_text(json.dumps({"flag": "Flag"}), encoding="utf-8")
    (root / "index.html").write_text("<html></html>", encoding="utf-8")


def first_overlay_entry(name: str) -> tuple[str, str]:
    overlay = json.loads((patcher.RESOURCES / name).read_text(encoding="utf-8"))
    key = next(iter(overlay))
    return key, overlay[key]


class LinuxAsarPatcherTests(unittest.TestCase):
    def test_asar_install_and_check_patched(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            resources = tmp / "resources"
            source = tmp / "source"
            resources.mkdir()
            make_frontend(source)
            key, value = first_overlay_entry("frontend-zh-CN.json")
            (source / "i18n" / "en-US.json").write_text(
                json.dumps({key: "Source", "extra": "Extra"}), encoding="utf-8"
            )
            patcher.build_asar(source, resources / "ion-dist.asar")

            self.assertFalse(linux_patcher.is_patched(resources))
            output = tmp / "patched.asar"
            run_patch(resources, "zh-CN", output)
            self.assertTrue(output.is_file())

            # Install the patched archive back into the resources layout.
            original = resources / "ion-dist.asar"
            original.write_bytes(output.read_bytes())
            self.assertTrue(linux_patcher.is_patched(resources))

            data = original.read_bytes()
            header_size, _header_string, header = patcher.read_asar_header(data, original)
            paths = {relative for relative, _entry in patcher.walk_asar_entries(header)}
            self.assertIn("i18n/zh-Hans.json", paths)
            self.assertIn("i18n/dynamic/zh-Hans.json", paths)
            self.assertIn("i18n/statsig/zh-Hans.json", paths)
            self.assertNotIn("i18n/zh-CN.json", paths)

            catalog = json.loads(patcher.read_asar_entry(data, header_size, header, "i18n/zh-Hans.json"))
            self.assertEqual(catalog[key], value)
            self.assertEqual(catalog["extra"], "Extra")
            dynamic = json.loads(
                patcher.read_asar_entry(data, header_size, header, "i18n/dynamic/zh-Hans.json")
            )
            self.assertEqual(dynamic, {"model": "Model"})

            script = patcher.read_asar_entry(data, header_size, header, "assets/index-abc.js").decode()
            self.assertIn('"zh-Hans"', script)
            self.assertEqual(script.count('"zh-Hans"'), 1)

    def test_patch_in_place_uses_staging_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            resources = tmp / "resources"
            resources.mkdir()
            make_frontend(tmp / "source")
            patcher.build_asar(tmp / "source", resources / "ion-dist.asar")

            run_patch(resources, "zh-TW")
            self.assertTrue(linux_patcher.is_patched(resources))
            self.assertFalse((resources / "ion-dist.asar.zh-cn-new").exists())

            data = (resources / "ion-dist.asar").read_bytes()
            _size, _string, header = patcher.read_asar_header(data, resources / "ion-dist.asar")
            paths = {relative for relative, _entry in patcher.walk_asar_entries(header)}
            self.assertIn("i18n/zh-Hant.json", paths)
            self.assertNotIn("i18n/zh-Hans.json", paths)

    def test_directory_layout_is_patched_in_place(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            resources = tmp / "resources"
            work = resources / "ion-dist"
            work.mkdir(parents=True)
            make_frontend(work)

            self.assertFalse(linux_patcher.is_patched(resources))
            run_patch(resources, "zh-CN")
            self.assertTrue(linux_patcher.is_patched(resources))
            self.assertTrue((work / "i18n" / "zh-Hans.json").is_file())
            self.assertIn('"zh-Hans"', (work / "assets" / "index-abc.js").read_text(encoding="utf-8"))

    def test_missing_whitelist_anchor_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            resources = tmp / "resources"
            resources.mkdir()
            source = tmp / "source"
            make_frontend(source)
            (source / "assets" / "index-abc.js").write_text("const a=[];", encoding="utf-8")
            (source / "assets" / "shared-1.js").write_text("// no list", encoding="utf-8")
            patcher.build_asar(source, resources / "ion-dist.asar")

            with self.assertRaises(SystemExit):
                run_patch(resources, "zh-CN", tmp / "out.asar")

    def test_language_mapping(self):
        self.assertEqual(linux_patcher.TARGET_CODES["zh-CN"], "zh-Hans")
        self.assertEqual(linux_patcher.TARGET_CODES["zh-TW"], "zh-Hant")
        self.assertEqual(linux_patcher.TARGET_CODES["zh-HK"], "zh-Hant")

    def test_zh_hk_uses_hong_kong_catalog(self):
        """zh-TW 与 zh-HK 都输出 zh-Hant，但写入的必须是各自词表。"""
        tw = json.loads((patcher.RESOURCES / "frontend-zh-TW.json").read_text(encoding="utf-8"))
        hk = json.loads((patcher.RESOURCES / "frontend-zh-HK.json").read_text(encoding="utf-8"))
        key = next(k for k in tw if k in hk and tw[k] != hk[k])

        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            resources = tmp / "resources"
            resources.mkdir()
            source = tmp / "source"
            make_frontend(source)
            (source / "i18n" / "en-US.json").write_text(
                json.dumps({key: "Source"}), encoding="utf-8"
            )
            patcher.build_asar(source, resources / "ion-dist.asar")

            run_patch(resources, "zh-HK")
            data = (resources / "ion-dist.asar").read_bytes()
            header_size, _string, header = patcher.read_asar_header(data, resources / "ion-dist.asar")
            catalog = json.loads(
                patcher.read_asar_entry(data, header_size, header, "i18n/zh-Hant.json")
            )
            self.assertEqual(catalog[key], hk[key])


if __name__ == "__main__":
    unittest.main()
