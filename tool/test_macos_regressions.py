#!/usr/bin/env python3
"""Run registered macOS regressions against compiled public OCaml interfaces."""

import argparse
from pathlib import Path
import subprocess


REPO = Path(__file__).resolve().parent.parent
CASES = (
    "test/macos_mutation_input_diagnostics_pure_reducer_test.exe",
    "test/worker_coordination_runtime_test.exe",
    "logseq_db_worker/test/test_effect_runner.exe",
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", help="Run registered targets whose path contains this text")
    options = parser.parse_args()
    cases = [case for case in CASES if options.case is None or options.case in case]
    if not cases:
        parser.error("no registered testcase matches --case")
    for relative in cases:
        subprocess.run(["dune", "exec", relative], cwd=REPO, check=True)


if __name__ == "__main__":
    main()
