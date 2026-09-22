import Foundation

@main struct JournalPlatformEventsTests {
  static func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: message, code: 1) }
  }

  static func main() throws {
    let cases: [(String, () throws -> Void)] = [
      ("background and resume preserve one generation", {
        var events = JournalPlatformEvents()
        events.connect()
        try check(events.next == nil, "initial foreground fabricates a resume")
        try events.setBackgrounded(true)
        let background = try JournalPlatformWire.lifecycle(.backgrounded, generation: 1)
        try check(events.next == background, "missing first background")
        try events.setBackgrounded(true)
        try check(events.count == 1 && events.generation == 1, "duplicate background")
        events.accepted(background)
        try events.setBackgrounded(false)
        let foreground = try JournalPlatformWire.lifecycle(.foregroundResumed, generation: 1)
        try check(events.next == foreground, "resume lost matching generation")
        events.accepted(foreground)
        try events.setBackgrounded(false)
        try check(events.next == nil, "duplicate resume")
      }),
      ("backpressure retains latest cycle and current authentication", {
        var events = JournalPlatformEvents()
        events.connect()
        for _ in 0..<10_000 {
          try events.setBackgrounded(true)
          try events.setBackgrounded(false)
          events.authenticated(Data([1]))
          events.authenticated(Data([2]))
          try check(events.count <= 3, "unbounded event queue")
        }
        let background = try JournalPlatformWire.lifecycle(.backgrounded, generation: 10_000)
        let foreground = try JournalPlatformWire.lifecycle(.foregroundResumed, generation: 10_000)
        try check(events.next == background, "latest background barrier lost")
        events.accepted(Data([255]))
        try check(events.next == background, "unrelated acknowledgement removed event")
        events.accepted(background)
        try check(events.next == foreground, "matching resume lost")
        events.accepted(foreground)
        try check(events.next == Data([2]), "stale auth replayed")
        events.accepted(Data([2]))
        try check(events.count == 0, "accepted event retained")
      }),
      ("runtime replacement reports current background without old credentials", {
        var events = JournalPlatformEvents()
        try events.setBackgrounded(true)
        events.connect()
        try check(events.next == JournalPlatformWire.lifecycle(.backgrounded, generation: 1), "connection missed current background")
        events.authenticated(Data([7]))
        events.disconnect()
        try check(events.count == 0 && !events.connected, "retired events retained")
        events.connect()
        try check(events.next == JournalPlatformWire.lifecycle(.backgrounded, generation: 1), "replacement missed current background")
        try check(events.count == 1, "old authentication crossed runtime lifetime")
      }),
      ("sign-out drops authentication; shutdown stops ordinary delivery", {
        var events = JournalPlatformEvents()
        events.connect()
        events.authenticated(Data([3]))
        events.clearAuthentication()
        try check(events.count == 0, "sign-out retained old auth snapshot")
        try events.setBackgrounded(true)
        events.beginShutdown()
        try events.setBackgrounded(false)
        events.authenticated(Data([4]))
        try check(events.terminating && events.count == 0, "ordinary event admitted during shutdown")
        events.disconnect()
        events.connect()
        events.authenticated(Data([5]))
        try check(events.next == Data([5]), "replacement remained terminal")
      }),
    ]
    var failures: [String] = []
    for (name, run) in cases {
      do { try run(); print("PASS: \(name)") }
      catch { failures.append(name); print("FAIL: \(name): \(error)") }
    }
    if !failures.isEmpty { throw NSError(domain: failures.joined(separator: "; "), code: 1) }
  }
}
