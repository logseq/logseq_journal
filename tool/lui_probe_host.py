"""Stage and build isolated LUI Apple probe hosts (replaces `bonsai-swiftui init`).

A probe host is a copy of the repo's `swift/` SwiftPM package with the probe's
`App.swift` (and a probe `Info.plist`) laid on top, then built through
`tool/build_journal_apple.sh` — the same LUI plumbing the app uses:
`JournalRuntimeHost` + `JournalRuntime` + `JournalApplicationPlatform` boot the
probe's OCaml complete object.

The OCaml side is produced separately: build the workspace (`dune build`) and
create the complete object with `ocamlfind ocamlopt -linkpkg
-output-complete-obj` over the `app` archive plus the probe module (the probe
self-registers via `Journal_bridge.register`, so link it last so its
registration wins). Pass the result via `--native-object` / JOURNAL_OCAML_OBJECT;
without it the build links the stub object (link-only validation).
"""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def stage(host, app_swift, bundle_id, display_name, swift_names=None):
    """Copy swift/ (+ Package.swift) into host, overlay the probe App.swift and
    write a probe Info.plist. `swift_names` optionally restricts the copied
    sources (always excluding App.swift, which app_swift replaces)."""
    swift_dir = Path(host) / "swift"
    swift_dir.mkdir(parents=True, exist_ok=True)
    names = swift_names or [
        source.name for source in (ROOT / "swift").glob("*.swift")
        if source.name != "App.swift"
    ]
    for name in names:
        shutil.copy2(ROOT / "swift" / name, swift_dir / name)
    shutil.copy2(ROOT / "swift" / "Package.swift", swift_dir / "Package.swift")
    (swift_dir / "App.swift").write_text(app_swift)
    (Path(host) / "apple").mkdir(exist_ok=True)
    info = plistlib.loads((ROOT / "apple" / "Info.plist").read_bytes())
    info["CFBundleIdentifier"] = bundle_id
    info["CFBundleName"] = display_name
    info["CFBundleDisplayName"] = display_name
    (Path(host) / "apple" / "Info.plist").write_bytes(plistlib.dumps(info))
    return swift_dir


def build(host, platform="macos", app_name="JournalApp.app", native_object=None,
          extra_env=None):
    """Build the staged host through tool/build_journal_apple.sh. Returns the
    assembled .app path. `platform` is 'macos' or 'ios-simulator'."""
    host = Path(host)
    env = dict(
        os.environ,
        JOURNAL_SWIFT_DIR=str(host / "swift"),
        JOURNAL_INFO_PLIST=str(host / "apple" / "Info.plist"),
        JOURNAL_LUI_PACKAGE_PATH=os.environ.get(
            "JOURNAL_LUI_PACKAGE_PATH",
            str((ROOT / "../lui/platform/apple").resolve())),
    )
    env.update(extra_env or {})
    if native_object:
        env["JOURNAL_OCAML_OBJECT"] = str(Path(native_object).resolve())
    app_dir = host / "apple" / app_name
    result = subprocess.run(
        ["bash", str(ROOT / "tool" / "build_journal_apple.sh"), platform, str(app_dir)],
        cwd=ROOT, env=env, capture_output=True, text=True)
    print(result.stdout, end="")
    print(result.stderr, end="")
    if result.returncode:
        raise SystemExit(result.returncode)
    return app_dir
