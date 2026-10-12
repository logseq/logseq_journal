import Foundation

@main struct JournalPlatformWireTests {
  static func require(_ condition: Bool, _ label: String) {
    precondition(condition, label)
  }

  static func rejects(_ label: String, _ action: () throws -> Void) {
    do {
      try action()
      fatalError("Accepted invalid packet: \(label)")
    } catch JournalPlatformWire.Failure.invalidPacket {
    } catch {
      fatalError("Unexpected error for \(label): \(error)")
    }
  }

  static func main() throws {
    let directory = URL(fileURLWithPath: CommandLine.arguments[1])
    let requestData = try Data(contentsOf: directory.appendingPathComponent("requests.json"))
    let requests = try JSONDecoder().decode([String: String].self, from: requestData)
    let expected: [String: JournalPlatformWire.Request] = [
      "authenticated-user": .authenticatedUser, "sign-out": .signOut,
      "termination-ready": .terminationReady,
      "local-account": .localAccount,
      "timeline-presented": .timelinePresented,
      "copy-text": .copyText("Root\n  - 中文😀"),
      "notice": .showNotice(token: String(Int64.max), message: "Fixture", actionLabel: nil, durationMs: 5000),
      "cancel-notice": .cancelNotice(token: String(Int64.max)),
    ]
    var baseRequest = Data()
    for (name, expectedRequest) in expected {
      let bytes = Data(hex: requests[name]!)
      // These bytes are produced by the existing OCaml public codec.
      require(try JournalPlatformWire.decodeRequest(bytes) == expectedRequest, name)
      if name == "authenticated-user" { baseRequest = bytes }
    }

    // An independent native request fixture with an opaque challenge.
    var tokenRequest = baseRequest
    tokenRequest[6] = 8
    let challenge = Data(#"{"challengeId":"challenge-1"}"#.utf8)
    tokenRequest[24] = UInt8(challenge.count)
    tokenRequest.append(challenge)
    require(try JournalPlatformWire.decodeRequest(tokenRequest) == .idToken(challengeID: "challenge-1"), "token challenge")

    for offset in [0, 4, 8, 16, 24, 28] {
      var invalid = baseRequest
      invalid[offset] = 255
      rejects("header byte \(offset)") { _ = try JournalPlatformWire.decodeRequest(invalid) }
    }
    for length in [0, 4, 31] {
      rejects("truncated \(length)") { _ = try JournalPlatformWire.decodeRequest(baseRequest.prefix(length)) }
    }
    var extraPayload = baseRequest
    extraPayload[24] = 1
    extraPayload.append(0)
    rejects("nonempty unit request") { _ = try JournalPlatformWire.decodeRequest(extraPayload) }
    var unknown = baseRequest
    unknown[6] = 7
    rejects("response as request") { _ = try JournalPlatformWire.decodeRequest(unknown) }
    rejects("oversized packet") { _ = try JournalPlatformWire.decodeRequest(Data(repeating: 0, count: 262177)) }
    let responses: [String: JournalPlatformWire.Response] = [
      "authenticated-user": .authenticatedUser("fixture-user"), "signed-out-user": .authenticatedUser(nil),
      "id-token": .idToken(challengeID: "challenge-1", token: "fixture-token-中文"),
      "sign-out": .signedOut, "termination-ready": .terminationReady,
      "local-account": .localAccount(userID: "fixture-user", origin: "https://api.logseq.io"),
      "no-local-account": .noLocalAccount, "timeline-presented": .timelinePresented,
      "notice": .notice(token: String(Int64.max), result: "action"),
      "copy-text": .textCopied,
    ]
    var encoded: [String: String] = [:]
    for (name, response) in responses {
      encoded[name] = try JournalPlatformWire.encodeResponse(response).hex
    }
    encoded["prepare-to-terminate"] = JournalPlatformWire.prepareToTerminate().hex
    encoded["backgrounded"] = try JournalPlatformWire.lifecycle(.backgrounded, generation: 17).hex
    encoded["foreground-resumed"] = try JournalPlatformWire.lifecycle(.foregroundResumed, generation: Int64.max).hex
    rejects("negative lifecycle generation") { _ = try JournalPlatformWire.lifecycle(.backgrounded, generation: -1) }
    for user in ["", "bad\0id", String(repeating: "中", count: 171)] {
      rejects("invalid user ID") { _ = try JournalPlatformWire.encodeResponse(.authenticatedUser(user)) }
    }
    for token in ["", "bad\0token", String(repeating: "a", count: 262144)] {
      rejects("invalid or oversized token response") { _ = try JournalPlatformWire.encodeResponse(.idToken(challengeID: "challenge-1", token: token)) }
    }
    rejects("insecure binding origin") { _ = try JournalPlatformWire.encodeResponse(.localAccount(userID: "fixture-user", origin: "http://api.logseq.io")) }
    struct Environment: Encodable {
      let brightness = "dark"; let platform = "ios"
      let accessibleNavigation = true; let highContrast = false
    }
    encoded["environment"] = try JournalPlatformWire.environment(Environment()).hex
    encoded["startup"] = try JournalStartupConfiguration.encode(
      applicationSupportPath: "/tmp/journal-native-fixture", managedSyncOrigin: "https://api.logseq.io"
    ).hex
    for path in ["", "/", "relative", "/tmp//journal", "/tmp/../journal", "/tmp/./journal",
                 "/tmp/journal/", "/tmp/bad\\path", "/tmp/bad\0path", "/" + String(repeating: "a", count: 4096)] {
      do {
        _ = try JournalStartupConfiguration.encode(applicationSupportPath: path, managedSyncOrigin: "https://api.logseq.io")
        fatalError("Invalid startup path was accepted")
      } catch JournalStartupConfiguration.Failure.invalidConfiguration {}
    }
    for origin in ["http://api.logseq.io", "https://user@api.logseq.io", "https://api.logseq.io/path",
                   "https://api.logseq.io?query=yes", "https://api.logseq.io#fragment", "https://"] {
      do {
        _ = try JournalStartupConfiguration.encode(applicationSupportPath: "/tmp/journal-native-fixture", managedSyncOrigin: origin)
        fatalError("Invalid startup origin was accepted")
      } catch JournalStartupConfiguration.Failure.invalidConfiguration {}
    }
    let binding = try JournalLocalAccountBindingStore.encode(userID: "fixture-user", managedSyncOrigin: "https://api.logseq.io")
    let restored = try JournalLocalAccountBindingStore.decode(binding)
    require(restored["userId"] as? String == "fixture-user", "generated account binding roundtrip")
    do {
      _ = try JournalLocalAccountBindingStore.decode(Data(#"{"version":1,"userId":"fixture-user","managedSyncOrigin":"https://api.logseq.io"}"#.utf8))
      fatalError("Legacy account binding was accepted")
    } catch {}
    try JSONEncoder().encode(encoded).write(to: directory.appendingPathComponent("responses.json"))
    print("Swift: OCaml requests accepted; invalid packets rejected; native responses emitted")
  }
}

extension Data {
  init(hex: String) {
    self.init()
    var index = hex.startIndex
    while index < hex.endIndex {
      let end = hex.index(index, offsetBy: 2)
      append(UInt8(hex[index..<end], radix: 16)!)
      index = end
    }
  }
  var hex: String { map { String(format: "%02x", $0) }.joined() }
}
