#!/usr/bin/env python3
"""Run the Worker Service and effect-runner regressions through their public APIs."""

from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]
TARGETS = (
    "test/worker_coordination_runtime_test.exe",
    "logseq_db_worker/test/test_effect_runner.exe",
)


def main():
    for target in TARGETS:
        subprocess.run(["dune", "exec", target], cwd=ROOT, check=True)


if __name__ == "__main__":
    main()
