"""Build an isolated native composer input probe using only public framework APIs.

Launch the generated CLI host with JOURNAL_PROBE_REBIND=1 (Journal-style handler
updates) or 0 (stable-handler control). Open Capture, type the alphabet rapidly,
and compare native editor text with the Observed label. No graph or auth is used.
"""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
host = Path(tempfile.mkdtemp(prefix='journal-editor-probe-')).resolve()
print(host, flush=True)
report = {'host': str(host), 'commands': [], 'inputs': {}}


def run(command):
    log = host / ('command-%d.log' % len(report['commands']))
    with log.open('w') as output:
        result = subprocess.run(command, cwd=host, stdout=output, stderr=subprocess.STDOUT)
    report['commands'].append({'command': command, 'exitCode': result.returncode, 'log': str(log)})
    (host/'results.json').write_text(json.dumps(report, indent=2)+'\n')
    if result.returncode:
        raise SystemExit(log.read_text()[-8000:])


run(['bonsai-swiftui', 'init', '--name', 'journal_editor_probe',
     '--macos-bundle-identifier', 'org.logseq.journal.editor-probe',
     '--ios-bundle-identifier', 'org.logseq.journal.editor-probe'])
source = root/'apple-tests/editor/composer_probe.ml'
shutil.copy2(source, host/'app/application.ml')
report['inputs']['apple-tests/editor/composer_probe.ml'] = hashlib.sha256(source.read_bytes()).hexdigest()
shutil.copyfile(root/'logseq_journal.opam.locked', host/'journal_editor_probe.opam.locked')
(host/'swift/App.swift').write_text('''import BonsaiSwiftUI
import SwiftUI

@main struct ComposerProbe: App {
  var body: some Scene {
    Window("Composer input probe", id: "probe") {
      BonsaiApplicationView(entrypoint: "journal_editor_probe")
        .frame(minWidth: 480, minHeight: 300)
    }
  }
}
''')
run(['bonsai-swiftui', 'init', '--adopt'])
run(['bonsai-swiftui', 'sync-host', '--check'])
run(['bonsai-swiftui', 'build', 'macos', '--profile', 'debug'])
print('Run from', host, ': JOURNAL_PROBE_REBIND=1 bonsai-swiftui run macos --profile debug', flush=True)
