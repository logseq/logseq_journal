import CryptoKit
import Darwin
import Foundation

@main struct ServerFixture {
  @MainActor static func main() async {
    let path = CommandLine.arguments[1]
    let mode = CommandLine.arguments[2]
    if mode == "disabled" {
      let udid = "11111111-1111-4111-8111-111111111111"
      guard JournalAcceptanceServer.endpoint(environment: ["SIMULATOR_UDID": udid]) == nil,
            JournalAcceptanceServer.endpoint(environment: ["JOURNAL_ACCEPTANCE": "1", "SIMULATOR_UDID": "invalid"]) == nil,
            JournalAcceptanceServer.endpoint(environment: ["JOURNAL_ACCEPTANCE": "1", "SIMULATOR_UDID": udid]) != nil else { exit(2) }
      return
    }
    let instance = UUID().uuidString
    let server = JournalAcceptanceServer(path: path) { challenge in
      if mode == "timeout" { try? await Task.sleep(for: .seconds(2)) }
      if mode == "oversize" { return Data(repeating: 120, count: 9000) }
      var value: [String: Any] = [
        "schema_version": 1, "challenge": mode == "replay" ? UUID().uuidString : challenge,
        "udid": "11111111-1111-4111-8111-111111111111", "bundle_id": "example.synthetic.journal",
        "source_sha": String(repeating: "a", count: 40),
        "executable_sha256": try! SHA256.hash(data: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]))).map { String(format: "%02x", $0) }.joined(),
        "graph_id": "22222222-2222-4222-8222-222222222222", "graph_generation": 7,
        "presentation_generation": 7, "phase": "open", "foreground": true,
        "pid": mode == "wrong-pid" ? 1 : getpid(), "process_instance": instance]
      if mode == "extra-field" { value["token"] = "synthetic-secret" }
      return try? JSONSerialization.data(withJSONObject: value)
    }
    do { try server.start() }
    catch { exit(1) }
    print("ready"); fflush(stdout)
    if mode == "stop-reading" {
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(100))
        server.stop()
        print("stopped"); fflush(stdout)
      }
    }
    while true { try? await Task.sleep(for: .seconds(1)) }
  }
}
