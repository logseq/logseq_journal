import Foundation
import Synchronization

// Only Security I/O is replaced. Files outlive each separate test process.
enum JournalLocalAccountBindingStore {
  static let gate = Mutex<DispatchSemaphore?>(nil)
  static var directory: URL {
    URL(fileURLWithPath: ProcessInfo.processInfo.arguments[2], isDirectory: true)
  }
  static func file(_ name: String) -> URL { directory.appendingPathComponent(name) }
  static func read(_ name: String) throws -> Data? {
    let url = file(name)
    return FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
  }
  static func replace(_ name: String, _ data: Data?) throws {
    if let data { try data.write(to: file(name), options: .atomic) }
    else if FileManager.default.fileExists(atPath: file(name).path) {
      try FileManager.default.removeItem(at: file(name))
    }
  }
  static func encode(userID: String, managedSyncOrigin: String) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["userId":userID,"managedSyncOrigin":managedSyncOrigin], options:.sortedKeys)
  }
  static func load() throws -> [String: Any]? {
    try loadData().map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] }
  }
  static func loadData() throws -> Data? { try read("binding") }
  static func writeData(_ data: Data) throws {
    try replace("binding", data)
    if let gate = gate.withLock({ $0 }) {
      guard gate.wait(timeout:.now()+10) == .success else { throw CancellationError() }
    }
  }
  static func restoreData(_ data: Data?) throws {
    if FileManager.default.fileExists(atPath: file("locked").path) {
      throw JournalAccountIssue(kind:.secureStorageUnavailable,stage:.bindingWrite)
    }
    try replace("binding", data)
  }
  static func clear() throws { try replace("binding", nil) }
  static func loadRecoveryData() throws -> Data? { try read("recovery") }
  static func writeRecoveryData(_ data: Data) throws { try replace("recovery",data) }
  static func clearRecoveryData() throws { try replace("recovery",nil) }
}
@MainActor final class JournalCognitoSession: JournalAuthCapability {
  func currentUserID() async throws -> String? { "replacement-user" }
  func freshIDToken() async throws -> String { "synthetic-token" }
  func signOut() async throws { }
}
@MainActor enum JournalCognitoNative { static let shared = JournalCognitoSession() }

@main struct JournalAccountColdStartRecoveryTests {
  @MainActor static func main() async throws {
    let args=ProcessInfo.processInfo.arguments, phase=args[1], absent=args[3]=="absent"
    let origin="https://api.logseq.io"
    let original=try JournalLocalAccountBindingStore.encode(userID:"original-user",managedSyncOrigin:origin)
    let owner=JournalNativeServices.makePlatformServices()
    if phase=="stage" {
      try JournalLocalAccountBindingStore.replace("binding",absent ? nil : original)
      try Data().write(to:JournalLocalAccountBindingStore.file("locked"))
      _ = try await owner.response(for:.localAccount)
      let gate=DispatchSemaphore(value:0)
      JournalLocalAccountBindingStore.gate.withLock { $0=gate }
      let pending=Task { try await owner.explicitOnlineResponse(for:.authenticatedUser) }
      let replacement=try JournalLocalAccountBindingStore.encode(userID:"replacement-user",managedSyncOrigin:origin)
      let deadline=ContinuousClock.now + .seconds(3)
      while try JournalLocalAccountBindingStore.loadData() != replacement {
        precondition(ContinuousClock.now<deadline,"Deferred native save did not execute")
        try await Task.sleep(for:.milliseconds(1))
      }
      owner.cancelAuthenticationPreparation()
      JournalLocalAccountBindingStore.gate.withLock { $0=nil }
      gate.signal()
      do { _ = try await pending.value; preconditionFailure("Retired save published") }
      catch { }
      print("STAGED failed undo; process will exit")
    } else if phase=="locked" {
      do {
        _ = try await owner.response(for:.localAccount)
        print("FAIL cold locked access exposed unaccepted binding")
        exit(1)
      } catch let issue as JournalAccountIssue {
        precondition(issue.kind == .secureStorageUnavailable)
        print("PASS cold access fails closed while undo is unavailable")
      }
    } else {
      try JournalLocalAccountBindingStore.replace("locked",nil)
      let response=try await owner.response(for:.localAccount)
      let expected:JournalPlatformWire.Response = absent ? .noLocalAccount : .localAccount(userID:"original-user",origin:origin)
      guard response==expected else {
        print("FAIL cold access lost original account or absence")
        exit(1)
      }
      let bytes = try JournalLocalAccountBindingStore.loadData()
      precondition(bytes == (absent ? nil : original))
      print("PASS cold retry restores original bytes or original absence")
    }
  }
}

// The existing storage/undo scenarios exercise user-authorized online recovery.
@MainActor private extension JournalPlatformServices {
  func explicitOnlineResponse(for request:JournalPlatformWire.Request) async throws -> JournalPlatformWire.Response {
    _ = try await response(for:.onlineRequested)
    return try await response(for:request)
  }
}
