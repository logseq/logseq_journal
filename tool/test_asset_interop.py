"""Exchange raw asset envelopes between upstream Logseq and production Apple crypto.

Requires macOS, swiftc, nbb, Node with WebCrypto, and the project's OCaml toolchain.
Usage: python3 tool/test_asset_interop.py /path/to/logseq
No account, Keychain operation, server connection, or user graph is involved.
"""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
upstream = Path(sys.argv[1]).resolve()
crypt = upstream / "src/main/frontend/common/crypt.cljs"
if not crypt.is_file():
    raise SystemExit("Supply a Logseq checkout containing frontend.common.crypt")
work = Path(tempfile.mkdtemp(prefix="journal-asset-interop-"))
print(work, flush=True)
record = {"commands": [], "sources": {}, "result": "incomplete"}
for source in [crypt, upstream / "deps/db/src/logseq/db/sqlite/util.cljs",
               root / "swift/JournalE2EECrypto.swift",
               root / "logseq_sync/lib/effect_runner/protocol/asset_codec.ml",
               root / "logseq_sync/test/asset_native_interop.ml",
               root / "logseq_sync/test/asset_adapter_memory.ml",
               root / "logseq_sync/lib/effect_runner/platform/platform_crypto.ml",
               root / "logseq_sync/lib/effect_runner/platform/platform_crypto_stubs.c",
               root / "tool/asset_interop.cljs", Path(__file__).resolve()]:
    record["sources"][str(source)] = hashlib.sha256(source.read_bytes()).hexdigest()
record["upstreamCommit"] = subprocess.check_output(
    ["git", "rev-parse", "HEAD"], cwd=upstream, text=True).strip()


def run(command, env=None):
    result = subprocess.run(command, cwd=root, env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    record["commands"].append({"command": command, "exitCode": result.returncode,
                               "output": result.stdout})
    (work / "results.json").write_text(json.dumps(record, indent=2) + "\n")
    print(result.stdout, end="", flush=True)
    if result.returncode:
        raise SystemExit(result.returncode)


# Load the unchanged upstream crypto namespace. Its logger and protected-title
# dependency are irrelevant to raw asset encryption; provide narrow host shims.
# Binary envelopes use cognitect.transit's built-in Uint8Array handler, also used
# by upstream sqlite.util. Its custom Entity/error/bean handlers are not involved.
for name, contents in {
    "lambdaisland/glogi.cljs": "(ns lambdaisland.glogi)\n(defn error [& _] nil)\n",
    "logseq/db.cljs": "(ns logseq.db (:require [cognitect.transit :as t]))\n"
                      "(defn read-transit-str [s] (t/read (t/reader :json) s))\n",
}.items():
    target = work / name
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(contents)
(work / "key.bin").write_bytes(bytes(range(32)))
for size in [0, 1, 256, 4097, 131057, 8388608]:
    (work / f"{size}.bin").write_bytes(bytes(i % 256 for i in range(size)))
nbb = ["nbb", "--classpath", f"{work}:{upstream / 'src/main'}",
       str(root / "tool/asset_interop.cljs")]
run(["node", "--version"])
run(["nbb", "--version"])
run(["swiftc", "--version"])
run(nbb + ["generate", str(work)])
library = work / "libJournalAssetCrypto.dylib"
run(["swiftc", "-emit-library", str(root / "swift/JournalE2EECrypto.swift"),
     "-o", str(library)])
run(["dune", "build", "logseq_sync/test/asset_native_interop.exe",
     "logseq_sync/test/asset_adapter_memory.exe"])
native_env = dict(os.environ, DYLD_INSERT_LIBRARIES=str(library))
run([sys.executable, "-c",
     "import resource,subprocess,sys; "
     "result=subprocess.run(sys.argv[1:]); "
     "rss=resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss; "
     "print('Native peak RSS bytes:', rss); "
     "sys.exit(result.returncode or (0 if rss <= 384 * 1024 * 1024 else 1))",
     str(root / "_build/default/logseq_sync/test/asset_native_interop.exe"), str(work)],
    env=native_env)
adapter_support = work / "adapter"
adapter_support.mkdir()
run([sys.executable, "-c",
     "import resource,subprocess,sys; "
     "result=subprocess.run(sys.argv[1:]); "
     "rss=resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss; "
     "print('Production adapter peak RSS bytes:', rss); "
     "sys.exit(result.returncode or (0 if rss <= 192 * 1024 * 1024 else 1))",
     str(root / "_build/default/logseq_sync/test/asset_adapter_memory.exe"), str(adapter_support)],
    env=native_env)
run(nbb + ["verify", str(work)])
record["result"] = "passed"
(work / "results.json").write_text(json.dumps(record, indent=2) + "\n")
print("Both directions passed; evidence:", work / "results.json")
