import Foundation

struct JournalTimelineFilterPreferences {
  let defaults: UserDefaults
  private static let keyPrefix = "journal.timeline-filter.graph."
  private static let commitPrefix = Data("journal.timeline-filter.commit\n".utf8)
  private static let recordLimit = 64 * 1024
  private static let graphLimit = 64

  var snapshot: [String: String] {
    var values: [String: String] = [:]
    let stored = defaults.dictionaryRepresentation()
    for key in stored.keys.sorted() where key.hasPrefix(Self.keyPrefix) {
      let graph = key.dropFirst(Self.keyPrefix.count)
      guard graph.utf8.prefix(37).count == 36,
            let id = UUID(uuidString: String(graph)) else { continue }
      let canonical = id.uuidString.lowercased()
      guard values[canonical] == nil else { continue }
      guard values.count < Self.graphLimit else {
        values["overflow"] = ""
        break
      }
      if let value = (stored[Self.keyPrefix + canonical] ?? stored[key]) as? String,
         value.utf8.prefix(Self.recordLimit + 1).count <= Self.recordLimit {
        values[canonical] = value
      } else {
        values[canonical] = ""
      }
    }
    return values
  }

  func wrapStartup(_ payload: Data) -> Data {
    guard let encoded = try? JSONEncoder().encode(snapshot) else { return payload }
    return Data("JTF1".utf8) + encoded + Data([10]) + payload
  }

  @discardableResult
  func handleCommit(_ request: Data) -> Bool {
    guard request.starts(with: Self.commitPrefix) else { return false }
    let body = request.dropFirst(Self.commitPrefix.count)
    guard let separator = body.firstIndex(of: 10),
          let id = UUID(uuidString: String(decoding: body.prefix(upTo: separator), as: UTF8.self)),
          body.count - body.distance(from: body.startIndex, to: separator) - 1 <= Self.recordLimit,
          let record = String(data: body.suffix(from: separator + 1), encoding: .utf8),
          !record.isEmpty else { return false }
    let key = Self.keyPrefix + id.uuidString.lowercased()
    defaults.set(record, forKey: key)
    return defaults.string(forKey: key) == record
  }
}
