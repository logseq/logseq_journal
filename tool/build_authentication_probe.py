"""Build a disposable iPhone Simulator host of the production authentication view."""
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
host = Path(tempfile.mkdtemp(prefix='journal-authentication-probe-'))
app = host / 'AuthenticationProbe.app'
app.mkdir()
bundle = 'org.logseq.journal.authentication-probe'
(app / 'Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': bundle,
    'CFBundleExecutable': 'AuthenticationProbe',
    'CFBundleName': 'Authentication Probe',
    'CFBundlePackageType': 'APPL',
    'CFBundleVersion': '1',
    'CFBundleShortVersionString': '1.0',
    'MinimumOSVersion': '26.0',
    'UIDeviceFamily': [1],
    'UILaunchScreen': {},
    'UISupportedInterfaceOrientations': ['UIInterfaceOrientationPortrait',
        'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight'],
}))
sources = [root/'swift/JournalAuthentication.swift', root/'swift/JournalAuthenticationView.swift',
           root/'apple-tests/authentication/JournalAuthenticationProbe.swift']
sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
command = ['xcrun', '--sdk', 'iphonesimulator', 'swiftc', '-swift-version', '6',
           '-parse-as-library', '-target', 'arm64-apple-ios26.0-simulator', '-sdk', sdk,
           *map(str, sources), '-o', str(app/'AuthenticationProbe')]
result = subprocess.run(command, text=True, capture_output=True)
(host/'build.log').write_text(result.stdout + result.stderr)
report = {'app': str(app), 'bundleIdentifier': bundle, 'command': command,
          'exitCode': result.returncode, 'sourceHashes': {
              str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}}
(host/'result.json').write_text(json.dumps(report, indent=2)+'\n')
print(json.dumps(report, indent=2))
if result.returncode:
    print(result.stderr)
    raise SystemExit(result.returncode)
subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
