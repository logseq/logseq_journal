import Foundation

/// Bounded native event ownership for one runtime connection.
struct JournalPlatformEvents {
  private(set) var backgrounded = false
  private(set) var generation: Int64 = 0
  private var lifecycle: [Data] = []
  private var authentication: Data?
  private(set) var connected = false
  private(set) var terminating = false

  var next: Data? { lifecycle.first ?? authentication }
  var count: Int { lifecycle.count + (authentication == nil ? 0 : 1) }

  mutating func connect() {
    lifecycle.removeAll(keepingCapacity: true)
    authentication = nil
    generation = 0
    connected = true
    terminating = false
    if backgrounded { try! enqueueBackground() }
  }

  mutating func disconnect() {
    connected = false
    lifecycle.removeAll(keepingCapacity: true)
    authentication = nil
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

  mutating func clearAuthentication() { authentication = nil }

  mutating func accepted(_ payload: Data) {
    if lifecycle.first == payload { lifecycle.removeFirst() }
    else if authentication == payload { authentication = nil }
  }

  mutating func beginShutdown() {
    terminating = true
    lifecycle.removeAll(keepingCapacity: true)
    authentication = nil
  }
}
