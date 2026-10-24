"""Test production Runtime at Swift/native admission boundary.

Swift actor scheduling, callback ownership and host publication are not owned by
the OCaml pure reducer; the capability emits requests synchronously from native
start and holds their async completion. No graph, Keychain or network is used.
Use --baseline only on pre-barrier source to reproduce immediate publication.
"""
from pathlib import Path
import subprocess
import sys
import tempfile
ROOT=Path(__file__).resolve().parents[1]
B=ROOT/'apple-tests/platform-services'
workspace=tempfile.TemporaryDirectory(prefix='journal-runtime-startup-')
W=Path(workspace.name)
source=ROOT/'swift/JournalRuntime.swift'
for name,target in [('Backend.swift','JournalRuntimeStartupBackend.swift'),('bridge.c','JournalRuntimeStartupBridge.c'),('Tests.swift','JournalRuntimeStartupTests.swift')]:
 (W/name).write_text((B/target).read_text())
if '--baseline' in sys.argv:
 with (W/'Tests.swift').open('a') as out:out.write('\nextension JournalRuntime {func waitForInitialPlatformRequests() async throws {}}\n')
def run(c):subprocess.run(c,cwd=W,check=True)
flags=['-swift-version','6','-module-cache-path',str(W/'modules')]
run(['xcrun','swiftc',*flags,'-emit-module','-emit-library','-module-name','LUIAppleBackend',str(W/'Backend.swift'),'-o',str(W/'libLUIAppleBackend.dylib')])
run(['xcrun','clang','-c',str(W/'bridge.c'),'-o',str(W/'bridge.o')])
run(['xcrun','swiftc',*flags,'-Xfrontend','-disable-sandbox','-I',str(W),'-L',str(W),'-lLUIAppleBackend','-Xlinker','-rpath','-Xlinker',str(W),str(ROOT/'swift/JournalSafeDiagnostic.swift'),str(ROOT/'swift/JournalPlatformWire.swift'),str(source.resolve()),str(W/'Tests.swift'),str(W/'bridge.o'),'-o',str(W/'tests')])
rows=[]
for scenario in ['normal','worker','multiple','repeated-start','rejected','patch-failure','stopped','cancelled','stale-cancel','nil-response','same-tag']:
 r=subprocess.run([str(W/'tests'),scenario],capture_output=True,text=True,timeout=20)
 rows.append(r.returncode);print(scenario,r.returncode,r.stdout.strip(),r.stderr.splitlines()[:1],flush=True)

sys.exit(any(rows))
