import Foundation
import LUIAppleBackend

@_silgen_name("fixture_set_mode") private func setMode(_ mode: Int32)
@_silgen_name("fixture_stop_count") private func stopCount() -> Int32

// The UI reducer cannot execute native startup admission or renderer callbacks.
// Replace only those capabilities; exercise production JournalRuntime.swift.
@MainActor final class JournalApplicationPlatform {
  var connected = false
  func connect(to runtime: JournalRuntime) { connected = true }
  func disconnect() { connected = false }
  func request(_ bytes: Data) async -> Data? { nil }
}
let journalAppIcons: [String: String] = [:]
@MainActor enum JournalLUIEvents {
  static func dispatch(_ event: LUIEvent) -> Int32 { 1 }
}

@MainActor @main struct JournalRuntimeFailureTests {
  static func main() throws {
    let scenario = CommandLine.arguments[1]
    setMode(scenario == "rejected" ? 1 : (scenario == "invalid-patch" ? 2 : 0))
    let platform = JournalApplicationPlatform()
    let runtime = try JournalRuntime(platform: platform, startupPayload: Data(),
      extensionRegistry: LUIAppleExtensionRegistry())
    var reported: Error?
    do { try runtime.start() } catch { reported = error }
    if scenario == "success" {
      precondition(reported == nil && platform.connected && runtime.rootID == 42)
      runtime.stop()
    } else {
      precondition(reported != nil, "Rejected native startup must reach the host error path")
      precondition(!platform.connected, "A failed startup cannot attach its platform")
      precondition(stopCount() == 1, "A failed startup must dispose its partial OCaml context")
      let message = reported!.localizedDescription
      precondition(!message.contains("SENSITIVE"), "Native failure must exclude raw renderer details")
      precondition(message.contains("runtime."), "Native failure must identify its fixed stage/code")
    }
    print("PASS runtime \(scenario)")
  }
}
