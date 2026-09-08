#!/usr/bin/env python3
"""Compile and run the same native owner probe against a selected Git worktree."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

SOURCE = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--worktree', type=Path, default=SOURCE)
    parser.add_argument('--owner', choices=['timeline', 'worker', 'overlay'], required=True)
    parser.add_argument('--size', type=int, default=128)
    parser.add_argument('--shared', action='store_true')
    args = parser.parse_args()
    root = args.worktree.resolve()
    subprocess.run(['dune', 'build', '@all'], cwd=root, check=True)
    lines = []
    for target in ['app', 'logseq_overlay_db/test', 'logseq_overlay_db/tool']:
        lines += subprocess.run(['dune', 'ocaml', 'top', target], cwd=root,
                                text=True, capture_output=True, check=True).stdout.splitlines()
    includes, libraries = [], []
    for line in dict.fromkeys(lines):
        if line.startswith('#directory '):
            path = Path(json.loads(line[len('#directory '):-2]))
            if not path.is_absolute():
                path = root / path
            includes += ['-I', str(path)]
            if path.name == 'byte':
                includes += ['-I', str(path.with_name('native'))]
        elif line.startswith('#load '):
            path = Path(json.loads(line[len('#load '):-2]))
            if not path.is_absolute():
                path = root / path
            if '/native_backend/' not in str(path):
                native = path.with_suffix('.cmxa')
                if not native.exists():
                    raise RuntimeError(f'Missing native library: {native}')
                libraries.append(str(native))
    with tempfile.TemporaryDirectory(prefix='rrbvec-owner-probe-') as directory:
        directory = Path(directory)
        for source in ['test/macos_mutation_runtime_test.ml',
                       'docs/test-reports/2026-09-07-rrbvec/owner_probe.ml']:
            shutil.copyfile(SOURCE / source, directory / Path(source).name)
        executable = directory / 'owner_probe.exe'
        compiled = subprocess.run(['ocamlopt', '-thread', '-w', '-58', *includes, *libraries,
                                   'macos_mutation_runtime_test.ml', 'owner_probe.ml', '-o', str(executable)],
                                  cwd=directory)
        if compiled.returncode:
            raise SystemExit(compiled.returncode)
        subprocess.run([str(executable), args.owner, str(args.size), str(args.shared).lower()],
                       cwd=root, check=True)


if __name__ == '__main__':
    main()
