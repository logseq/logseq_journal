"""Build the actual Amplify acceptance view through an installed-CLI host.

The supplied disposable schema-4 host must already resolve exact Amplify 2.61.0.
Launch with the CLI and inspect the PASS/FAIL view with native UI tools.
No account lookup, token retrieval or sign-out is requested by the fixture.
"""
import argparse
import hashlib
import json
import plistlib
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--host', required=True, type=Path)
parser.add_argument('--platform', choices=['macos', 'ios'], default='macos')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
host = args.host.resolve()
if not host.is_relative_to(Path(tempfile.gettempdir()).resolve()):
    raise SystemExit('A disposable host is required')
config = host/'bonsai-swiftui.sexp'
value = config.read_text()
if '(name journal_gate)' not in value or '(exact 2.61.0)' not in value:
    raise SystemExit('Expected the schema-4 Amplify package host')
value = re.sub(r'\(bundle_identifier [^)]+\)',
               '(bundle_identifier org.logseq.journal.amplify-probe)', value)
config.write_text(value)
for name in ['macos-debug-profile.entitlements', 'macos-release.entitlements']:
    # Synthetic identity: the probe needs no production Keychain access group.
    (host/'config/entitlements'/name).write_bytes(plistlib.dumps({}))
result = {'host': str(host), 'inputs': {}, 'commands': []}
sources = [root/'swift'/name for name in [
    'JournalPlatformWire.swift', 'JournalPlatformEvents.swift', 'JournalPlatformServices.swift', 'JournalAmplifySession.swift',
    'JournalApplicationPlatform.swift', 'JournalNativeServices.swift',
    'JournalAuthentication.swift', 'JournalAmplifyAuthentication.swift', 'JournalAuthenticationView.swift',
    'JournalLocalAccountBindingStore.swift', 'JournalStartupConfiguration.swift',
    'JournalE2EECrypto.swift']]
for source in sources + [root/'apple-tests/amplify/JournalAmplifyAcceptance.swift']:
    result['inputs'][str(source.relative_to(root))] = hashlib.sha256(source.read_bytes()).hexdigest()
    shutil.copy2(source, host/'swift'/source.name)
for name in ['JournalPlatformWire.swift', 'JournalPlatformServices.swift',
             'JournalAmplifySession.swift', 'JournalAmplifySessionTests.swift']:
    (host/'apple-tests'/name).unlink(missing_ok=True)
fixture = root/'apple-tests/amplify/hub_fixture.ml'
result['inputs'][str(fixture.relative_to(root))] = hashlib.sha256(fixture.read_bytes()).hexdigest()
shutil.copy2(fixture, host/'app/application.ml')
(host/'swift/App.swift').write_text('''import SwiftUI
@main struct ApplicationHost: App {
    var body: some Scene {
        WindowGroup { JournalAmplifyAcceptance().frame(minWidth: 650, minHeight: 180) }
    }
}
''')
build = ['bonsai-swiftui', 'build', args.platform, '--profile',
         'debug' if args.platform == 'macos' else 'release']
if args.platform == 'ios':
    build.append('--no-codesign')
for command in [
    ['bonsai-swiftui', 'init', '--adopt'],
    ['bonsai-swiftui', 'sync-host', '--check'],
    build,
]:
    log = host/('amplify-test-%d.log' % len(result['commands']))
    with log.open('w') as output:
        process = subprocess.run(command, cwd=host, stdout=output, stderr=subprocess.STDOUT)
    result['commands'].append({'command': command, 'exit_code': process.returncode,
                               'log': str(log), 'log_sha256': hashlib.sha256(log.read_bytes()).hexdigest()})
    (host/'amplify-test-results.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(result['commands'][-1]), flush=True)
    if process.returncode:
        raise SystemExit(process.returncode)
