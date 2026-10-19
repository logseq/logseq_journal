"""Headless native Runtime admission tests; no App, graph, Keychain or network.

The capability fixture supplies the C admission result and renderer failure.
JournalRuntime itself is always compiled from production source.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="journal-runtime-failure-") as directory:
    work = Path(directory)
    backend = work / "Backend.swift"
    backend.write_text('''
import Foundation
public struct LUIEvent: Sendable {}
public struct LUIAppleExtensionRegistry { public init() {} }
@MainActor public final class LUIAppleBackend {
  public var rootIDs: [Int] = []
  public var onEvent: ((LUIEvent) -> Void)?
  public init(appIcons: [String: String], extensionRegistry: LUIAppleExtensionRegistry) throws {}
  public func apply(json: String) throws {
    if json == "invalid" { throw NSError(domain: "SENSITIVE renderer content", code: 1) }
    rootIDs = [42]
  }
}
''')
    bridge = work / "bridge.c"
    bridge.write_text('''
#include <stdint.h>
static int mode;
static int stops;
static int platform_calls;
int32_t fixture_platform_count(void) { return platform_calls; }
int32_t fixture_stop_count(void) { return stops; }
void fixture_set_mode(int32_t value) { mode = value; }
int32_t lui_ocaml_start(void (*patch)(const char *), int32_t p, int32_t h, const char *d, int32_t n) {
  if (mode == 1) return 0;
  patch(mode == 2 ? "invalid" : "valid"); return 1;
}
int32_t lui_ocaml_stop(void) { stops++; return 1; }
int32_t journal_ocaml_pump(void) { return mode == 3 ? 0 : 1; }
void journal_ocaml_set_wakeup_callback(void (*f)(void)) {}
void journal_ocaml_set_platform_request_callback(void (*f)(const char *,int32_t)) {}
int32_t journal_ocaml_platform_event(const char *d,int32_t n) { platform_calls++; return mode == 4 ? 0 : 1; }
int32_t journal_ocaml_platform_response(const char *d,int32_t n) { platform_calls++; return mode == 5 ? 0 : 1; }
int32_t journal_ocaml_platform_failure(const char *d,int32_t n) { platform_calls++; return mode == 6 ? 0 : 1; }
''')
    def run(args):
        subprocess.run(args, cwd=work, check=True)
    run(["xcrun", "swiftc", "-swift-version", "6", "-module-cache-path", str(work / "modules"), "-emit-module", "-emit-library",
         "-module-name", "LUIAppleBackend", str(backend), "-o", str(work / "libLUIAppleBackend.dylib")])
    run(["xcrun", "clang", "-c", str(bridge), "-o", str(work / "bridge.o")])
    executable = work / "runtime-tests"
    run(["xcrun", "swiftc", "-swift-version", "6", "-Xfrontend", "-disable-sandbox", "-I", str(work), "-L", str(work),
         "-lLUIAppleBackend", "-Xlinker", "-rpath", "-Xlinker", str(work),
         "-module-cache-path", str(work / "modules"), str(ROOT / "swift/JournalRuntime.swift"),
         str(ROOT / "apple-tests/platform-services/JournalRuntimeFailureTests.swift"),
         str(work / "bridge.o"), "-o", str(executable)])
    failures = []
    for scenario in ["success", "rejected", "invalid-patch", "pump", "platform-event", "platform-response", "platform-failure", "stopped-response", "stopped-failure"]:
        result = subprocess.run([str(executable), scenario], cwd=work, capture_output=True, text=True)
        print(f"runtime {scenario}: exit={result.returncode}")
        if result.returncode:
            # Crash backtraces may include the synthetic fixture, never user data.
            failures.append(scenario)
        else:
            print(result.stdout.strip())
    if failures:
        raise SystemExit("Runtime failure reporting regressions: " + ", ".join(failures))
