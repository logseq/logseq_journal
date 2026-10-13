#!/usr/bin/env python3
"""Compile the production icon catalog and verify installed-bundle declarations."""
import pathlib
import plistlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class AppIconPackagingTests(unittest.TestCase):
    def package(self, platform, app, existing_info=None):
        info_path = app / ("Contents/Info.plist" if platform == "macos" else "Info.plist")
        info_path.parent.mkdir(parents=True, exist_ok=True)
        if existing_info is None:
            info_path.write_bytes((ROOT / "apple/Info.plist").read_bytes())
        else:
            info_path.write_bytes(plistlib.dumps(existing_info))
        result = subprocess.run([
            "bash", str(ROOT / "tool/package_journal_apple_icons.sh"), platform, str(app),
        ], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        info = plistlib.loads(info_path.read_bytes())
        self.assertEqual(info["CFBundleIdentifier"], "com.logseq.journal")
        self.assertEqual(info["CFBundleExecutable"], "JournalApp")
        return info

    def test_ios_packaging_preserves_custom_icon_configuration(self):
        with tempfile.TemporaryDirectory(prefix="journal-custom-icons-") as directory:
            app = pathlib.Path(directory) / "Journal.app"
            existing = plistlib.loads((ROOT / "apple/Info.plist").read_bytes())
            alternate = {"Night": {"CFBundleIconFiles": ["NightIcon"], "UIPrerenderedIcon": True}}
            for key in ("CFBundleIcons", "CFBundleIcons~ipad"):
                existing[key] = {
                    "CFBundleAlternateIcons": alternate,
                    "CFBundlePrimaryIcon": {
                        "CFBundleIconName": "PreviousPrimary",
                        "CFBundleIconFiles": ["PreviousPrimary"],
                        "CFBundleIconDisplayName": "Custom Journal",
                        "UIPrerenderedIcon": True,
                    },
                }
            info = self.package("ios-simulator", app, existing)
            for key in ("CFBundleIcons", "CFBundleIcons~ipad"):
                with self.subTest(idiom=key):
                    self.assertIn("CFBundleAlternateIcons", info[key])
                    self.assertEqual(info[key]["CFBundleAlternateIcons"], alternate)
                    primary = info[key]["CFBundlePrimaryIcon"]
                    self.assertEqual(primary["CFBundleIconName"], "AppIcon")
                    self.assertNotIn("PreviousPrimary", primary["CFBundleIconFiles"])
                    self.assertEqual(primary["CFBundleIconDisplayName"], "Custom Journal")
                    self.assertTrue(primary["UIPrerenderedIcon"])
                    for name in primary["CFBundleIconFiles"]:
                        self.assertTrue(list(app.glob(name + "*.png")), name)
            self.assertEqual(self.package("ios-simulator", app, info), info)

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
