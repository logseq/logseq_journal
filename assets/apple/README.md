# Journal C4 icon

The approved original is `Source/Logseq-Journal-C4.png` (1254 × 1254, RGB, no alpha), supplied as Library item `libfile_38fc0fb7c96081918e306c8475c62f48`.

`Assets.xcassets/AppIcon.appiconset` contains resampled copies of that artwork. The 1024px image is the iOS universal AppIcon; macOS uses the same image and the smaller sizes listed in the catalog. All images are opaque and full bleed. iOS applies its own corner mask.

To regenerate a size on macOS:

```sh
sips --resampleHeightWidth 1024 1024 assets/apple/Source/Logseq-Journal-C4.png \
  --out assets/apple/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
```

`.agents/skills/journal-build/scripts/build_journal_apple.sh` invokes `.agents/skills/journal-build/scripts/package_journal_apple_icons.sh` before signing. The latter compiles the C4 catalog with `actool` and adds its generated declarations to the freshly assembled app's icon-free Info.plist. Existing icon configurations and alternate icons are unsupported; the helper rejects such inputs before compiling resources. Probe plists derived from Journal's source plist can still override non-icon metadata such as the bundle ID and display name.

Run the single basic packaging check for both iOS Simulator and macOS with `python3 .agents/skills/journal-build/scripts/test_apple_app_icon.py` on macOS with Xcode installed.
