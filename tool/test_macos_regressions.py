#!/usr/bin/env python3
"""Run registered macOS regressions against compiled public OCaml interfaces."""

import argparse
import json
from pathlib import Path
import subprocess
import tempfile


REPO = Path(__file__).resolve().parent.parent
CASES = [
    (
        "test/macos_mutation_input_diagnostics_pure_reducer_test.ml",
        "MACOS_PURE_REDUCER_TESTS_PASSED",
    ),
    ("test/macos_application_dispatch_test.ml", "MACOS_APPLICATION_DISPATCH_TESTS_PASSED"),
    ("test/macos_mutation_runtime_test.ml", "MACOS_MUTATION_RUNTIME_TESTS_PASSED"),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", help="Run registered files whose path contains this text")
    options = parser.parse_args()
    cases = [case for case in CASES if options.case is None or options.case in case[0]]
    if not cases:
        parser.error("no registered testcase matches --case")
    bootstrap = "\n".join(
        subprocess.run(
            ["dune", "ocaml", "top", target],
            cwd=REPO, text=True, capture_output=True, check=True,
        ).stdout
        for target in ("app", "logseq_overlay_db/test")
    )
    if not bootstrap.strip():
        raise RuntimeError("Dune emitted no compiled application dependencies")
    # The app directory also contains native_embed; its host embedding runtime
    # cannot be loaded into the OCaml toplevel and is not used by the app library.
    bootstrap = "\n".join(
        line
        for line in dict.fromkeys(bootstrap.splitlines())
        if not (line.startswith("#load ") and "/native_backend/" in line)
    )
    test_library = subprocess.run(
        ["ocamlfind", "query", "bonsai_flutter_test"],
        cwd=REPO, text=True, capture_output=True, check=True,
    ).stdout.strip()
    bootstrap += "\n#directory " + json.dumps(test_library) + ";;\n"
    bootstrap += "#load " + json.dumps(str(Path(test_library) / "bonsai_flutter_test.cma")) + ";;\n"
    with tempfile.TemporaryDirectory(prefix="journal-macos-regressions-") as directory:
        for relative, sentinel in cases:
            entry = Path(directory) / "run.ml"
            entry.write_text(
                bootstrap + "\n#use " + json.dumps(str(REPO / relative)) + ";;\n"
            )
            result = subprocess.run(
                ["ocaml", "-noinit", "-noprompt", str(entry)],
                cwd=REPO,
                text=True,
                capture_output=True,
            )
            print(result.stdout, end="")
            print(result.stderr, end="")
            if result.returncode or sentinel not in result.stdout.splitlines():
                raise SystemExit(1)


if __name__ == "__main__":
    main()
