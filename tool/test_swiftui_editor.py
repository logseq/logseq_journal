"""Build an isolated native composer input probe using only public framework APIs.

Stages an LUI probe host (tool/lui_probe_host.py) embedding
apple-tests/editor/composer_probe.ml — a Lui_app signal+update probe that
self-registers via Journal_bridge.register. Launch the assembled .app binary.
Type the alphabet rapidly into the Capture field and compare native editor
text with the Observed label. No graph or auth is used.

The previous bonsai fixture's JOURNAL_PROBE_REBIND handler-rebind comparison
has no lui counterpart (Expandable_message_composer is gone); the probe
covers the same input -> state -> observed flow.

The probe's OCaml complete object is produced by the workspace build (see
tool/lui_probe_host.py): pass it via --native-object, otherwise the host links
the stub object and only verifies the Swift side.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lui_probe_host

root = lui_probe_host.ROOT
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--native-object', type=Path,
                    help='Complete OCaml object embedding the probe module')
arguments = parser.parse_args()

host = Path(tempfile.mkdtemp(prefix='journal-editor-probe-')).resolve()
print(host, flush=True)
report = {'host': str(host), 'commands': [], 'inputs': {}}

source = root/'apple-tests/editor/composer_probe.ml'
report['inputs']['apple-tests/editor/composer_probe.ml'] = hashlib.sha256(source.read_bytes()).hexdigest()

lui_probe_host.stage(host, app_swift='''import LUIAppleBackend
import SwiftUI

@MainActor private final class ProbeAuth: JournalAuthCapability {
  func currentUserID() async throws -> String? { nil }
  func freshIDToken() async throws -> String { throw CancellationError() }
  func signOut() async throws { throw CancellationError() }
}

@main struct ComposerProbe: App {
  var body: some Scene {
    Window("Composer input probe", id: "probe") {
      JournalRuntimeHost(
        platform: JournalApplicationPlatform(services: JournalPlatformServices(
          auth: ProbeAuth(),
          account: JournalAccountStore(load: { nil }, save: { _ in }, clear: {}),
          managedSyncOrigin: "https://example.invalid")),
        payload: (try? JournalNativeServices.startupPayload()) ?? Data(),
        extensions: (try? JournalExtensions.registry()) ?? LUIAppleExtensionRegistry())
        .frame(minWidth: 480, minHeight: 300)
    }
  }
}
''', bundle_id='org.logseq.journal.editor-probe', display_name='Journal Editor Probe')

app = lui_probe_host.build(host, platform='macos', app_name='JournalEditorProbe.app',
                           native_object=arguments.native_object)
report['commands'].append({'app': str(app)})
(host/'results.json').write_text(json.dumps(report, indent=2)+'\n')
print('Run from', host, ':', app/'Contents/MacOS/JournalApp', flush=True)
