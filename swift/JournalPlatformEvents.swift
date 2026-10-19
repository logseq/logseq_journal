import Foundation

/// Bounded native event ownership for one runtime connection.
struct JournalPlatformEvents {
  private(set) var backgrounded = false
  private(set) var generation: Int64 = 0
  private var lifecycle: [Data] = []
  private var authentication: Data?
  private var online: Data?
  private var revokedOnlineScope: JournalPlatformWire.StartupScope?
  private(set) var connected = false
  private(set) var terminating = false

  var next: Data? { lifecycle.first ?? online ?? authentication }
  var count: Int { lifecycle.count + (online == nil ? 0 : 1) + (authentication == nil ? 0 : 1) }

  mutating func connect() {
    lifecycle.removeAll(keepingCapacity: true)
    authentication = nil
    online = nil
    revokedOnlineScope = nil
    generation = 0
    connected = true
    terminating = false
    if backgrounded { try! enqueueBackground() }
  }

  mutating func disconnect() {
    connected = false
    lifecycle.removeAll(keepingCapacity: true)
    authentication = nil
    online = nil
  }

  mutating func setBackgrounded(_ value: Bool) throws {
    guard value != backgrounded else { return }
    backgrounded = value
    guard connected, !terminating else { return }
    if value { try enqueueBackground() }
    else {
      lifecycle.append(try JournalPlatformWire.lifecycle(.foregroundResumed, generation: generation))
    }
  }

  private mutating func enqueueBackground() throws {
    guard generation < Int64.max else { throw JournalPlatformWire.Failure.invalidPacket }
    generation += 1
    // Supersede older unsent cycles, retaining the barrier required by this resume.
    lifecycle = [try JournalPlatformWire.lifecycle(.backgrounded, generation: generation)]
  }

  mutating func authenticated(_ payload: Data) {
    guard connected, !terminating else { return }
    authentication = payload
  }

  mutating func requestOnline(_ payload:Data) {
    guard connected, !terminating else {return}
    guard let scope = try? JournalPlatformWire.startupScope(payload) else {return}
    let tag = UInt16(payload[6]) | UInt16(payload[7]) << 8
    if tag == 35 {
      if revokedOnlineScope == nil || scope > revokedOnlineScope! { revokedOnlineScope = scope }
    } else if tag == 34 {
      guard acceptsOnlinePermission(scope) else {return}
    } else {return}
    online=payload
  }

  func acceptsOnlinePermission(_ scope: JournalPlatformWire.StartupScope) -> Bool {
    revokedOnlineScope.map { scope > $0 } ?? true
  }

  mutating func clearAuthentication() { authentication = nil }

  mutating func accepted(_ payload: Data) {
    if lifecycle.first == payload { lifecycle.removeFirst() }
    else if online == payload {online=nil}
    else if authentication == payload { authentication = nil }
  }

  mutating func beginShutdown() {
    terminating = true
    lifecycle.removeAll(keepingCapacity: true)
    authentication = nil
    online = nil
  }
}
