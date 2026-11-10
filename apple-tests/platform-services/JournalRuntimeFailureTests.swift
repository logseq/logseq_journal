import Foundation
import LUIAppleBackend

@_silgen_name("fixture_set_mode") private func setMode(_ mode: Int32)
@_silgen_name("fixture_stop_count") private func stopCount() -> Int32
@_silgen_name("fixture_platform_count") private func platformCount() -> Int32

// The UI reducer cannot execute native startup admission or renderer callbacks.
// Replace only those capabilities; exercise production JournalRuntime.swift.
@MainActor final class JournalApplicationPlatform {
  var connected = false
  func connect(to runtime: JournalRuntime) { connected = true }
  func disconnect() { connected = false }
  var response: Data?
  var hold = false
  var waiter: CheckedContinuation<Data?, Never>?
  func request(_ bytes: Data) async -> Data? {
    if hold { return await withCheckedContinuation { waiter = $0 } }
    return response
  }
}
let journalAppIcons: [String: String] = [:]
enum JournalLUIEvents {
  static func dispatch(_ event: LUIEvent) -> Int32 { 1 }
}

@MainActor @main struct JournalRuntimeFailureTests {
  static func main() async throws {
    precondition(JournalRuntime.safeDescription(JournalPlatformWire.Failure.invalidPacket,
      operation: "lifecycle").contains("invalidPayload"), "lifecycle packet cause lost")
    let scenario = CommandLine.arguments[1]
    let modes = ["rejected":1, "invalid-patch":2, "pump":3, "platform-event":4, "platform-response":5, "platform-failure":6, "stop-retry":7, "stop-failure":7, "startup-truncated":501, "startup-magic":503, "worker-permission":615, "worker-space":617]
    setMode(Int32(modes[scenario] ?? 0))
    let platform = JournalApplicationPlatform()
    let runtime = try JournalRuntime(platform: platform, startupPayload: Data(),
      extensionRegistry: LUIAppleExtensionRegistry())
    var reported: Error?
    do { try runtime.start() } catch { reported = error }
    if scenario == "host-lifetime" {
      precondition(reported == nil && platform.connected)
      var owner: JournalRuntimeLifetime? = JournalRuntimeLifetime()
      owner?.runtime = runtime
      weak var released = owner
      precondition(platform.connected && stopCount() == 0,
        "A mounted owner keeps the runtime connected independently of visible presentation")
      owner = nil
      precondition(released == nil && !platform.connected && stopCount() == 1,
        "Removing the actual host owner releases native runtime exactly once")
    } else if scenario == "stop-retry" || scenario == "stop-failure" {
      precondition(reported == nil && platform.connected)
      runtime.stop()
      precondition(runtime.failure == .stop && !platform.connected,
        "Failed native cleanup must remain visible and detach platform delivery")
      if scenario == "stop-retry" { setMode(0) }
      runtime.stop()
      precondition(stopCount() == 2, "Retry must reattempt a previously rejected native cleanup")
      precondition(runtime.failure == .stop, "Cleanup must not erase the failure before the host admits retry")
    } else if scenario == "stopped-response" || scenario == "stopped-failure" {
      platform.hold = true
      let delivery = Task { await runtime.deliverPlatformRequest(Data([0, 1])) }
      while platform.waiter == nil { await Task.yield() }
      runtime.stop()
      platform.waiter!.resume(returning: scenario == "stopped-response" ? Data([0, 1]) : nil)
      await delivery.value
      precondition(platformCount() == 0, "A stopped Runtime must discard its late platform completion")
      precondition(runtime.failure == nil && !platform.connected)
    } else if ["pump", "platform-event", "platform-response", "platform-failure"].contains(scenario) {
      precondition(reported == nil && platform.connected)
      switch scenario {
      case "pump": runtime.pump()
      case "platform-event": runtime.sendPlatformEvent(Data([0, 1]))
      default:
        platform.response = scenario == "platform-response" ? Data([0, 1]) : (Data([76,74,70,49,6,0,6,0])+Data(repeating:0,count:16))
        await runtime.deliverPlatformRequest(Data([0, 1]))
      }
      let expected: [String: JournalRuntime.Failure] = ["pump": .pump, "platform-event": .platformEvent,
        "platform-response": .platformResponse, "platform-failure": .platformFailure]
      precondition(runtime.failure == expected[scenario], "The host must receive the exact failed native stage")
      precondition(runtime.failure!.localizedDescription.contains("runtime."))
      runtime.stop()
    } else if scenario == "success" {
      precondition(reported == nil && platform.connected && runtime.rootID == 42)
      runtime.stop()
    } else {
      precondition(reported != nil, "Rejected native startup must reach the host error path")
      precondition(!platform.connected, "A failed startup cannot attach its platform")
      precondition(stopCount() == 1, "A failed startup must dispose its partial OCaml context")
      let message = reported!.localizedDescription
      precondition(!message.contains("SENSITIVE"), "Native failure must exclude raw renderer details")
      precondition(message.contains("runtime."), "Native failure must identify its fixed stage/code")
      let detail = ["startup-truncated": "startupPayloadTruncated", "startup-magic": "startupMagicInvalid",
        "worker-permission": "permissionDenied", "worker-space": "noSpace"]
      precondition(message.contains(detail[scenario] ?? (scenario == "invalid-patch" ? "backendUnsupportedProperty" : "callbackFailed")),
        "native runtime must preserve the safe producer reason")

    }
    print("PASS runtime \(scenario)")
  }
}
