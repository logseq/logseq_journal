#!/usr/bin/env python3
"""Run the registered worker/mutation fixtures through compiled public APIs."""

import json
from pathlib import Path
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[3]


def main():
    subprocess.run(
        ["dune", "build", "app/app.cmxa",
         "logseq_overlay_db/test/logseq_overlay_db_test_support.cmxa"],
        cwd=ROOT, check=True,
    )
    lines = []
    for target in ("app", "logseq_overlay_db/test"):
        lines.extend(subprocess.check_output(
            ["dune", "ocaml", "top", target], cwd=ROOT, text=True,
        ).splitlines())
    includes = []
    libraries = []
    for line in dict.fromkeys(lines):
        if line.startswith("#directory "):
            path = Path(json.loads(line[len("#directory "):-2]))
            if not path.is_absolute():
                path = ROOT / path
            includes.extend(["-I", str(path)])
            if path.name == "byte":
                includes.extend(["-I", str(path.with_name("native"))])
        elif line.startswith("#load "):
            path = Path(json.loads(line[len("#load "):-2]))
            if not path.is_absolute():
                path = ROOT / path
            if "/native_backend/" not in str(path):
                libraries.append(str(path.with_suffix(".cmxa")))
    with tempfile.TemporaryDirectory(prefix="journal-native-regression-") as directory:
        directory = Path(directory)
        source = ROOT / "test/macos_mutation_runtime_test.ml"
        shutil.copyfile(source, directory / source.name)
        executable = directory / "regression.exe"
        subprocess.run(
            ["ocamlopt", "-thread", "-w", "-58", *includes, *libraries,
             source.name, "-o", str(executable)],
            cwd=directory, check=True,
        )
        subprocess.run([str(executable)], cwd=ROOT, check=True)


if __name__ == "__main__":
    main()
