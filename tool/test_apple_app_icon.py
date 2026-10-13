#!/usr/bin/env python3
"""Compile the production icon catalog and verify installed-bundle declarations."""
import pathlib
import plistlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class AppIconPackagingTests(unittest.TestCase):
    def package(self, platform, app):
        info_path = app / ("Contents/Info.plist" if platform == "macos" else "Info.plist")
        info_path.parent.mkdir(parents=True)
        info_path.write_bytes((ROOT / "apple/Info.plist").read_bytes())
        result = subprocess.run([
            "bash", str(ROOT / "tool/package_journal_apple_icons.sh"), platform, str(app),
        ], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        info = plistlib.loads(info_path.read_bytes())
        self.assertEqual(info["CFBundleIdentifier"], "com.logseq.journal")
        self.assertEqual(info["CFBundleExecutable"], "JournalApp")
        return info

    def test_ios_primary_icon_is_compiled_and_referenced_for_phone_and_ipad(self):
        with tempfile.TemporaryDirectory(prefix="journal-ios-icon-") as directory:
            app = pathlib.Path(directory) / "Journal.app"
            info = self.package("ios-simulator", app)
            self.assertGreater((app / "Assets.car").stat().st_size, 0)
            self.assertFalse((app / "Contents").exists())
            for key in ("CFBundleIcons", "CFBundleIcons~ipad"):
                primary = info[key]["CFBundlePrimaryIcon"]
                self.assertEqual(primary["CFBundleIconName"], "AppIcon")
                self.assertTrue(primary["CFBundleIconFiles"])
                for name in primary["CFBundleIconFiles"]:
                    self.assertTrue(list(app.glob(name + "*.png")), name)

    def test_macos_icon_file_is_compiled_and_referenced_in_resources(self):
        with tempfile.TemporaryDirectory(prefix="journal-macos-icon-") as directory:
            app = pathlib.Path(directory) / "Journal.app"
            info = self.package("macos", app)
            resources = app / "Contents/Resources"
            icon = resources / info["CFBundleIconFile"]
            if not icon.suffix:
                icon = icon.with_suffix(".icns")
            self.assertEqual(icon.read_bytes()[:4], b"icns")
            self.assertEqual(info["CFBundleIconName"], "AppIcon")
            self.assertGreater((resources / "Assets.car").stat().st_size, 0)


if __name__ == "__main__":
    unittest.main()
