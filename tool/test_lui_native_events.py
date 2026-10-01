"""Exercise the production Swift event adapter, C trampoline and OCaml hooks.

No pure reducer can detect a missing ABI symbol or mismatched callback arguments.
This headless test uses Journal_bridge's public hook boundary and opens no app,
account, simulator or graph. It leaves the shared opam switch untouched.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
LUI = Path(os.environ.get("JOURNAL_LUI_PACKAGE_PATH", ROOT / "../lui/platform/apple")).resolve()
SCRATCH = ROOT / "_build/apple-tests/native-events/lui"


def run(command, cwd=ROOT):
    subprocess.run(command, cwd=cwd, check=True)


run(["swift", "build", "--package-path", str(LUI), "--scratch-path", str(SCRATCH),
     "--product", "LUIAppleBackendStatic", "-j", "8"])
binary_directory = Path(subprocess.check_output(
    ["swift", "build", "--package-path", str(LUI), "--scratch-path", str(SCRATCH),
     "--show-bin-path"], text=True).strip())
ocaml_include = subprocess.check_output(["ocamlc", "-where"], text=True).strip()

with tempfile.TemporaryDirectory(prefix="journal-lui-events-") as directory:
    temporary = Path(directory)
    for name in ["journal_bridge.mli", "journal_bridge.ml"]:
        shutil.copy2(ROOT / "app" / name, temporary / name)
    shutil.copy2(ROOT / "apple-tests/native-events/bridge_fixture.ml", temporary)
    compiler = ["ocamlfind", "ocamlopt", "-package", "lui"]
    for name in ["journal_bridge.mli", "journal_bridge.ml", "bridge_fixture.ml"]:
        run([*compiler, "-c", name], temporary)
    run([*compiler, "-linkpkg", "-output-complete-obj", "-o", "fixture.o",
         "journal_bridge.cmx", "bridge_fixture.cmx"], temporary)
    run(["xcrun", "clang", "-Wall", "-Wextra", "-Werror", "-I", ocaml_include,
         "-c", str(ROOT / "app/journal_lui_bridge.c"), "-o", str(temporary / "bridge.o")])
    executable = temporary / "events-tests"
    run(["xcrun", "swiftc", "-swift-version", "6", "-I", str(binary_directory / "Modules"),
         str(ROOT / "swift/JournalLUIEvents.swift"),
         str(ROOT / "apple-tests/native-events/JournalLUIEventsTests.swift"),
         str(binary_directory / "libLUIAppleBackendStatic.a"),
         str(temporary / "fixture.o"), str(temporary / "bridge.o"), "-o", str(executable)])
    run([str(executable)], temporary)
