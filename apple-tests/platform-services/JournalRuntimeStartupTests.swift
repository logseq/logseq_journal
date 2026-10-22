import Foundation
import LUIAppleBackend

@_silgen_name("fixture_inside") func inside() -> Int32
@_silgen_name("fixture_calls") func calls() -> Int32
@_silgen_name("fixture_reentrant") func reentrant() -> Int32
@_silgen_name("fixture_mode") func mode(_ m: Int32)
@_silgen_name("fixture_emit") func emit()
let journalAppIcons: [String: String] = [:]
@MainActor enum JournalLUIEvents { static func dispatch(_ e: LUIEvent) -> Int32 { 1 } }
@MainActor final class JournalApplicationPlatform {
  var connected = false, hold = true
  var begins = 0
  var waiters: [CheckedContinuation<Data?, Never>] = []
  func connect(to runtime: JournalRuntime) { connected = true }
  func disconnect() { connected = false }
  func request(_ bytes: Data) async -> Data? {
    precondition(inside() == 0 && connected, "request before native start/connect finished")
    precondition(Array(bytes) == [1, 2], "C bytes must be owned after callback")
    begins += 1
    if hold { return await withCheckedContinuation { waiters.append($0) } }
    return bytes
  }
}
@MainActor @main struct Test {
  static func main() async throws {
    let scenario = CommandLine.arguments[1]
    mode(["rejected": 1, "patch-failure": 2, "worker": 3, "multiple": 4][scenario] ?? 0)
    let p = JournalApplicationPlatform()
    let r = try JournalRuntime(
      platform: p, startupPayload: Data(), extensionRegistry: LUIAppleExtensionRegistry())
    var published = false
    let boot = Task {
      try r.start()
      try await r.waitForInitialPlatformRequests()
      published = true
    }
    if scenario == "rejected" || scenario == "patch-failure" {
      do {
        try await boot.value
        preconditionFailure("rejected startup completed")
      } catch {}
      for _ in 0..<12 { await Task.yield() }
      precondition(!published && !p.connected && p.begins == 0 && calls() == 0)
    } else {
      if scenario == "repeated-start" { try r.start() }
      let count = scenario == "multiple" ? 2 : 1
      for _ in 0..<200 {
        if p.waiters.count == count { break }
        await Task.yield()
      }
      precondition(p.begins == count, "buffered requests were not delivered exactly once")
      precondition(!published, "root published before initial account request completed")
      precondition(calls() == 0 && reentrant() == 0)
      if scenario == "cancelled" {
        boot.cancel()
        for _ in 0..<100 {
          if !p.connected { break }
          await Task.yield()
        }
        precondition(!p.connected, "cancellation did not promptly stop the waiting runtime")
        p.waiters.removeFirst().resume(returning: Data([1, 2]))
        do {
          try await boot.value
          preconditionFailure("cancelled boot published")
        } catch is CancellationError {}
        precondition(calls() == 0 && !published)
      } else if scenario == "stopped" || scenario == "stale-cancel" {
        r.stop()
        if scenario == "stale-cancel" {
          try r.start()
          for _ in 0..<100 {
            if p.begins == 2 { break }
            await Task.yield()
          }
          boot.cancel()
          for _ in 0..<12 { await Task.yield() }
          precondition(p.connected, "old cancellation stopped the new runtime generation")
        }
        p.waiters.removeFirst().resume(returning: Data([1, 2]))
        do {
          try await boot.value
          preconditionFailure("stopped boot published")
        } catch is CancellationError {}
        precondition(calls() == 0 && !published)
        if scenario == "stale-cancel" {
          p.waiters.removeFirst().resume(returning: Data([1, 2]))
          try await r.waitForInitialPlatformRequests()
          precondition(calls() == 1 && p.connected)
          r.stop()
        }
      } else {
        for w in p.waiters { w.resume(returning: scenario == "nil-response" ? nil : Data([1, 2])) }
        p.waiters = []
        try await boot.value
        precondition(published && calls() == count && reentrant() == 0)
        r.stop()
      }
    }
    print("PASS barrier \(scenario)")
  }
}
