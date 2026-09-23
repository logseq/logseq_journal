"""Build a native encrypted warm-start acceptance host with the real Journal object.

Stages an LUI probe host (tool/lui_probe_host.py) with
apple-tests/warm-start/JournalWarmStartAcceptance.swift as the @main app,
linked against the production native_embed complete object. The fixture uses
generated disposable data, memory-only E2EE secrets and blocked network
authentication. Run the printed CLI commands and inspect actual native
Timeline/recovery content and the adjacent JSONL observations before accepting.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lui_probe_host

root = lui_probe_host.ROOT
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--rows', type=int, default=500, help='Number of fixture journal roots (1–5000)')
parser.add_argument('--children', type=int, default=35, help='Children under the first root (0–5000)')
parser.add_argument('--graphs', type=int, default=1, help='Independent encrypted fixture graphs (1–4)')
parser.add_argument('--history-days', type=int, default=0, help='Additional journal days with 12 rows each (0–30)')
parser.add_argument('--platform', choices=['macos', 'ios-simulator'], default='macos')
parser.add_argument('--native-object', type=Path, help='Use the current verified production object')
arguments = parser.parse_args()
if not 1 <= arguments.rows <= 5000:
    parser.error('--rows must be between 1 and 5000')
if not 0 <= arguments.children <= 5000:
    parser.error('--children must be between 0 and 5000')
if not 1 <= arguments.graphs <= 4:
    parser.error('--graphs must be between 1 and 4')
if not 0 <= arguments.history_days <= 30:
    parser.error('--history-days must be between 0 and 30')
host = Path(tempfile.mkdtemp(prefix='journal-native-warm-start-')).resolve()
print(host, flush=True)
record = {'host': str(host), 'commands': [], 'inputs': {}}
debug_config = host/'test-debug.xcconfig'
debug_config.write_text('SWIFT_ACTIVE_COMPILATION_CONDITIONS = $(inherited) DEBUG\n')
environment = dict(os.environ, XCODE_XCCONFIG_FILE=str(debug_config))


def run(command, cwd=host):
    log = host / ('command-%d.log' % len(record['commands']))
    with log.open('w') as output:
        result = subprocess.run(command, cwd=cwd, stdout=output, stderr=subprocess.STDOUT, env=environment)
    record['commands'].append({'command': list(map(str, command)), 'cwd': str(cwd),
                              'exitCode': result.returncode, 'log': str(log)})
    (host/'results.json').write_text(json.dumps(record, indent=2)+'\n')
    if result.returncode:
        raise SystemExit(log.read_text()[-12000:])
    return log.read_text()


# The OCaml side ships the production complete object: app/native_embed.exe.o.
# Build it first with the workspace dune build (see tool/build_journal_apple.sh);
# pass a prebuilt artifact via --native-object.
artifact = arguments.native_object.resolve() if arguments.native_object else (
    root/'_build/default/app/native_embed.exe.o')
if not artifact.is_file():
    raise SystemExit('Build the current Journal native object first: '
                     'dune build app/native_embed.exe (native object mode), '
                     'or pass --native-object')
record['nativeObject'] = {'path': str(artifact), 'sha256': hashlib.sha256(artifact.read_bytes()).hexdigest()}

bootstrap = "\n".join(subprocess.run(['dune', 'ocaml', 'top', target], cwd=root,
    capture_output=True, text=True, check=True).stdout for target in ['app', 'logseq_overlay_db/test'])
bootstrap = "\n".join(line for line in dict.fromkeys(bootstrap.splitlines())
                      if not (line.startswith('#load ') and '/native_backend/' in line))
generator = host/'generate.ml'
generator.write_text(bootstrap+'\n#use '+json.dumps(str(root/'apple-tests/warm-start/generate_fixture.ml'))+';;\n')

sources = [root/'swift'/name for name in
           ['JournalE2EECrypto.swift', 'JournalPlatformWire.swift', 'JournalPlatformServices.swift',
            'JournalStartupConfiguration.swift', 'JournalChrome.swift']]
source = root/'apple-tests/warm-start/JournalWarmStartAcceptance.swift'
for tracked in sources + [source]:
    record['inputs'][str(tracked.relative_to(root))] = hashlib.sha256(tracked.read_bytes()).hexdigest()

lui_probe_host.stage(host, app_swift=source.read_text(),
                     bundle_id='org.logseq.journal.warm-start-probe',
                     display_name='Logseq Journal')

for case in ['valid', 'missing']:
    support = host/('support-'+case)
    support.mkdir()
    fixture = run(['ocaml', '-noinit', '-noprompt', generator, support, str(arguments.rows), str(arguments.children), str(arguments.graphs), str(arguments.history_days)], cwd=root)
    (host/(case+'.json')).write_text(json.dumps(json.loads(fixture), indent=2)+'\n')

# XCODE_XCCONFIG_FILE enables DEBUG inside the probe build (the test host's
# memory-only secret stores are gated on it).
app = lui_probe_host.build(host, platform=arguments.platform,
                           app_name='JournalWarmStartProbe.app',
                           native_object=artifact,
                           extra_env={'XCODE_XCCONFIG_FILE': str(debug_config)})

if arguments.platform == 'ios-simulator':
    print('Install', app, 'in the org.logseq.journal.warm-start-probe container.', flush=True)
    print('Copy valid.json and support-valid into this test app Documents directory.', flush=True)
    print('Launch with both memory-only secret environment variables and arguments:',
          '--fixture valid.json --support-root support-valid', flush=True)
    raise SystemExit(0)

for case in ['valid', 'missing']:
    print('Run from', host, ':',
          'LOGSEQ_JOURNAL_E2EE_TEST_PRIVATE_KEY_STORAGE=memory',
          'LOGSEQ_JOURNAL_E2EE_TEST_WRAPPED_KEY_STORAGE=memory',
          app/'Contents/MacOS/JournalApp',
          '--fixture', host/(case+'.json'), '--support-root', host/('support-'+case),
          '--missing-key' if case == 'missing' else '', flush=True)
