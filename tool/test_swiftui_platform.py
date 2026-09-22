"""Run the native wire port against the unchanged public OCaml platform codec.

Invoke from the repository: dune exec -- python3 tool/test_swiftui_platform.py
The temporary service adapter uses installed SwiftUI types; no production OCaml
or Dune file is modified and no application, credentials or graph is opened.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PACKAGES = ','.join([
    'bonsai_swiftui.spec_impl', 'bonsai_swiftui.ui', 'bonsai_swiftui.driver',
    'digestif.c', 'mirage-ptime.unix', 'logseq_overlay_db.impl',
    'logseq_sync.pure_reducer.impl', 'logseq_sync.effect_runner.impl',
    'logseq_db_worker.pure_reducer.impl', 'logseq_db_worker.effect_runner.impl',
    'logseq_db_worker', 'logseq_sync.effect_runner', 'melange-transit-native',
    'mtime.clock.os', 'unix', 'uri', 'yojson',
])


def run(directory, command):
    result = subprocess.run(command, cwd=directory, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f'{command[0]} exited {result.returncode}:\n{result.stdout}{result.stderr}')
    if result.stdout:
        print(result.stdout.strip())


with tempfile.TemporaryDirectory(prefix='journal-platform-wire-') as directory:
    destination = Path(directory)
    sources = [ROOT / 'app' / ('journal_validation' + suffix) for suffix in ['.mli', '.ml']]
    sources += [ROOT / 'logseq_db_worker/bonsai' / ('logseq_db_worker_bonsai_service' + suffix)
                for suffix in ['.mli', '.ml']]
    sources += [ROOT / 'app' / ('journal_platform' + suffix) for suffix in ['.mli', '.ml']]
    sources += [ROOT / 'app' / ('journal_startup' + suffix) for suffix in ['.mli', '.ml']]
    sources += [ROOT / 'apple-tests/platform-wire/journal_platform_wire_test.ml']
    compiler = ['ocamlfind', 'ocamlopt', '-thread', '-package', PACKAGES]
    for source in sources:
        adapted = source.read_text().replace(
            'Logseq_db_worker_bonsai.Logseq_db_worker_bonsai_service',
            'Logseq_db_worker_bonsai_service')
        (destination / source.name).write_text(adapted)
        run(destination, [*compiler, '-c', source.name])
    run(destination, [*compiler, '-linkpkg', '-o', 'wire_ocaml',
                      *[source.stem + '.cmx' for source in sources if source.suffix == '.ml']])
    run(destination, [str(destination / 'wire_ocaml'), 'emit', 'requests.json'])
    run(destination, ['swiftc', '-swift-version', '6', '-o', 'wire_swift',
                      str(ROOT / 'swift/JournalPlatformWire.swift'),
                      str(ROOT / 'swift/JournalStartupConfiguration.swift'),
                      str(ROOT / 'apple-tests/platform-wire/JournalPlatformWireTests.swift')])
    run(destination, [str(destination / 'wire_swift'), directory])
    run(destination, [str(destination / 'wire_ocaml'), 'verify', 'responses.json'])
