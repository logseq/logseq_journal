"""Build a public Native_list disclosure probe with observable, non-destructive events."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
host = Path(tempfile.mkdtemp(prefix="journal-outline-probe-")).resolve()
print(host, flush=True)
record = {"host": str(host), "commands": [], "inputs": {}}

def run(command):
    log = host / f"command-{len(record['commands'])}.log"
    with log.open("w") as output:
        result = subprocess.run(command, cwd=host, stdout=output, stderr=subprocess.STDOUT)
    record["commands"].append({"command": command, "exitCode": result.returncode, "log": str(log)})
    (host / "results.json").write_text(json.dumps(record, indent=2) + "\n")
    if result.returncode:
        raise SystemExit(log.read_text()[-8000:])

run(["bonsai-swiftui", "init", "--name", "journal_outline_probe",
     "--macos-bundle-identifier", "org.logseq.journal.outline-probe",
     "--ios-bundle-identifier", "org.logseq.journal.outline-probe"])
for source, target in [("apple-tests/native-outline/outline_probe.ml", "app/application.ml")]:
    shutil.copyfile(root/source, host/target)
    record["inputs"][source] = hashlib.sha256((root/source).read_bytes()).hexdigest()
shutil.copyfile(root/"logseq_journal.opam.locked", host/"journal_outline_probe.opam.locked")
(host/"swift/App.swift").write_text('''import BonsaiSwiftUI
import SwiftUI

@main struct OutlineProbe: App {
  var body: some Scene {
    Window("Outline action probe", id: "probe") {
      BonsaiApplicationView(entrypoint: "journal_outline_probe")
        .frame(minWidth: 480, minHeight: 320)
    }
  }
}
''')
run(["bonsai-swiftui", "init", "--adopt"])
run(["bonsai-swiftui", "sync-host", "--check"])
run(["bonsai-swiftui", "build", "macos", "--profile", "debug"])
print("Open", host/"apple/DerivedData/Build/Products/Debug/BonsaiJournalOutlineProbe.app", flush=True)
