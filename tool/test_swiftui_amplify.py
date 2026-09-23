"""Build the actual Amplify acceptance view through an isolated LUI probe host.

Stages a disposable host (tool/lui_probe_host.py) with the Amplify swift
sources, apple-tests/amplify/JournalAmplifyAcceptance.swift as the visible
probe view, and apple-tests/amplify/hub_fixture.ml as the embedded OCaml app
(a Lui_app static view self-registered via Journal_bridge.register). Synthetic
empty entitlements keep the probe off the production Keychain access group.
Launch the assembled .app binary and inspect the PASS/FAIL view with native UI
tools. No account lookup, token retrieval or sign-out is requested.
"""
import argparse
import hashlib
import json
import plistlib
from pathlib import Path
import shutil
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lui_probe_host

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--host', type=Path,
                    help='Disposable host directory (defaults to a fresh tempdir)')
parser.add_argument('--platform', choices=['macos', 'ios-simulator'], default='macos')
parser.add_argument('--native-object', type=Path,
                    help='Complete OCaml object embedding hub_fixture.ml')
args = parser.parse_args()
root = lui_probe_host.ROOT
host = (args.host or Path(tempfile.mkdtemp(prefix='journal-amplify-probe-'))).resolve()
if not host.is_relative_to(Path(tempfile.gettempdir()).resolve()):
    raise SystemExit('A disposable host is required')
result = {'host': str(host), 'inputs': {}, 'commands': []}

sources = sorted((root/'swift').glob('*.swift')) + [
    root/'apple-tests/amplify/JournalAmplifyAcceptance.swift']
for source in sources:
    result['inputs'][str(source.relative_to(root))] = hashlib.sha256(source.read_bytes()).hexdigest()
fixture = root/'apple-tests/amplify/hub_fixture.ml'
result['inputs'][str(fixture.relative_to(root))] = hashlib.sha256(fixture.read_bytes()).hexdigest()

lui_probe_host.stage(host, app_swift='''import SwiftUI
@main struct ApplicationHost: App {
    var body: some Scene {
        WindowGroup { JournalAmplifyAcceptance().frame(minWidth: 650, minHeight: 180) }
    }
}
''', bundle_id='org.logseq.journal.amplify-probe', display_name='Logseq Journal')
shutil.copy2(root/'apple-tests/amplify/JournalAmplifyAcceptance.swift',
             host/'swift'/'JournalAmplifyAcceptance.swift')

# Synthetic identity: the probe needs no production Keychain access group.
entitlements = host/'entitlements'
entitlements.mkdir(exist_ok=True)
for name in ['macos-debug-profile.entitlements', 'ios-debug-profile.entitlements',
             'macos-release.entitlements']:
    (entitlements/name).write_bytes(plistlib.dumps({}))

app = lui_probe_host.build(host, platform=args.platform,
                           app_name='JournalAmplifyProbe.app',
                           native_object=args.native_object,
                           extra_env={'JOURNAL_ENTITLEMENTS_DIR': str(entitlements)})
result['commands'].append({'app': str(app)})
(host/'amplify-test-results.json').write_text(json.dumps(result, indent=2)+'\n')
print(json.dumps(result['commands'][-1]), flush=True)
