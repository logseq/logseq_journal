"""Build a public journal-list disclosure probe with observable, non-destructive events.

Stages an LUI probe host (tool/lui_probe_host.py) embedding
apple-tests/native-outline/outline_probe.ml — a Lui_app signal+update probe
mounting the `journal-list` extension (Journal_lui_native.list) with
disclosure rows; expand + row events are decoded back through the extension
event contract.

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

host = Path(tempfile.mkdtemp(prefix="journal-outline-probe-")).resolve()
print(host, flush=True)
record = {"host": str(host), "commands": [], "inputs": {}}

source = root/"apple-tests/native-outline/outline_probe.ml"
record["inputs"]["apple-tests/native-outline/outline_probe.ml"] = hashlib.sha256(source.read_bytes()).hexdigest()

lui_probe_host.stage(host, app_swift='''import LUIAppleBackend
import SwiftUI

@MainActor private final class ProbeAuth: JournalAuthCapability {
  func currentUserID() async throws -> String? { nil }
  func freshIDToken() async throws -> String { throw CancellationError() }
  func signOut() async throws { throw CancellationError() }
}

@main struct OutlineProbe: App {
  var body: some Scene {
    Window("Outline action probe", id: "probe") {
      JournalRuntimeHost(
        platform: JournalApplicationPlatform(services: JournalPlatformServices(
          auth: ProbeAuth(),
          account: JournalAccountStore(load: { nil }, save: { _ in }, clear: {}),
          managedSyncOrigin: "https://example.invalid")),
        payload: (try? JournalNativeServices.startupPayload()) ?? Data(),
        extensions: (try? JournalExtensions.registry()) ?? LUIAppleExtensionRegistry())
        .frame(minWidth: 480, minHeight: 320)
    }
  }
}
''', bundle_id='org.logseq.journal.outline-probe', display_name='Journal Outline Probe')

app = lui_probe_host.build(host, platform="macos", app_name="JournalOutlineProbe.app",
                           native_object=arguments.native_object)
record["commands"].append({"app": str(app)})
(host/"results.json").write_text(json.dumps(record, indent=2) + "\n")
print("Open", app, flush=True)
