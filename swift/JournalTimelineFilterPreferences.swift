import Foundation

struct JournalTimelineFilterPreferences {
  let defaults: UserDefaults
  private static let keyPrefix = "journal.timeline-filter.graph."
  private static let commitPrefix = Data("journal.timeline-filter.commit\n".utf8)

  var snapshot: [String: String] {
    var values: [String: String] = [:]
    for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(Self.keyPrefix) {
      let graph = String(key.dropFirst(Self.keyPrefix.count))
      if let value = value as? String, UUID(uuidString: graph) != nil {
        values[graph] = value
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
          body.count - body.distance(from: body.startIndex, to: separator) - 1 <= 512 * 1024,
          let record = String(data: body.suffix(from: separator + 1), encoding: .utf8),
          !record.isEmpty else { return false }
    let key = Self.keyPrefix + id.uuidString.lowercased()
    defaults.set(record, forKey: key)
    return defaults.string(forKey: key) == record
  }
}
