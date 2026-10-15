#!/usr/bin/env python3
"""One basic check that Journal's C4 icon is packaged for both Apple hosts."""
import pathlib
import plistlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class AppIconPackagingTests(unittest.TestCase):
    def test_journal_icon_is_packaged(self):
        with tempfile.TemporaryDirectory(prefix="journal-app-icon-") as directory:
            for platform in ("ios-simulator", "ios-device", "macos"):
                with self.subTest(platform=platform):
                    app = pathlib.Path(directory) / (platform + ".app")
                    info_path = app / ("Contents/Info.plist" if platform == "macos" else "Info.plist")
                    info_path.parent.mkdir(parents=True)
                    info_path.write_bytes((ROOT / "apple/Info.plist").read_bytes())
                    result = subprocess.run([
                        "bash", str(ROOT / "tool/package_journal_apple_icons.sh"), platform, str(app),
                    ], capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    info = plistlib.loads(info_path.read_bytes())
                    self.assertEqual(info["CFBundleIdentifier"], "com.logseq.journal")
                    resources = app / "Contents/Resources" if platform == "macos" else app
                    self.assertGreater((resources / "Assets.car").stat().st_size, 0)
                    if platform == "macos":
                        self.assertEqual(info["CFBundleIconName"], "AppIcon")
                        icon = resources / info["CFBundleIconFile"]
                        if not icon.suffix:
                            icon = icon.with_suffix(".icns")
                        self.assertEqual(icon.read_bytes()[:4], b"icns")
                    else:
                        for key in ("CFBundleIcons", "CFBundleIcons~ipad"):
                            primary = info[key]["CFBundlePrimaryIcon"]
                            self.assertEqual(primary["CFBundleIconName"], "AppIcon")
                            self.assertTrue(primary["CFBundleIconFiles"])
                            for name in primary["CFBundleIconFiles"]:
                                self.assertTrue(list(resources.glob(name + "*.png")), name)


if __name__ == "__main__":
    unittest.main()
