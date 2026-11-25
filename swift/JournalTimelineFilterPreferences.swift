import Foundation

struct JournalTimelineFilterPreferences {
  let defaults: UserDefaults
  private static let keyPrefix = "journal.timeline-filter.graph."
  private static let commitPrefix = Data("journal.timeline-filter.commit\n".utf8)
  private static let recordLimit = 64 * 1024
  private static let graphLimit = 64

  private struct Record: Decodable {
    struct Definition: Decodable {
      let name: String
      let tags: [UUID]
      let statuses: [UUID]

      private enum CodingKeys: String, CodingKey { case name, tags, statuses, time }

      init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        name = try fields.decode(String.self, forKey: .name)
        tags = try fields.decode([UUID].self, forKey: .tags)
        statuses = try fields.decode([UUID].self, forKey: .statuses)
        if let preset = try? fields.decode(String.self, forKey: .time),
           ["any", "14-days", "3-months"].contains(preset) { return }
        var time = try fields.nestedUnkeyedContainer(forKey: .time)
        let count = try time.decode(Int.self)
        let unit = try time.decode(String.self)
        let ocamlMaxInt = Int.max / 2
        guard time.isAtEnd, count > 0,
              (unit == "days" && count <= ocamlMaxInt || unit == "weeks" && count <= ocamlMaxInt / 7) else {
          throw DecodingError.dataCorruptedError(forKey: .time, in: fields, debugDescription: "Invalid relative time")
        }
      }

      var trimmedName: Data {
        Data(name.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n\u{000C}")).utf8)
      }
    }

    let version: Int
    let definitions: [Definition]
    let selected: String?

    static func decode(_ text: String) -> Self? {
      guard text.utf8.prefix(JournalTimelineFilterPreferences.recordLimit + 1).count
              <= JournalTimelineFilterPreferences.recordLimit,
            let record = try? JSONDecoder().decode(Self.self, from: Data(text.utf8)),
            record.version == 2, record.definitions.count <= 5 else { return nil }
      var names: Set<Data> = []
      for definition in record.definitions {
        let name = definition.trimmedName
        guard (1...128).contains(name.count), names.insert(name).inserted,
              definition.tags.count <= 100, definition.statuses.count <= 100 else { return nil }
      }
      if let selected = record.selected, !names.contains(Data(selected.utf8)) { return nil }
      return record
    }
  }

  private static func graphID(forKey key: String) -> String? {
    guard key.hasPrefix(keyPrefix) else { return nil }
    let graph = key.dropFirst(keyPrefix.count)
    guard graph.utf8.prefix(37).count == 36 else { return nil }
    return UUID(uuidString: String(graph))?.uuidString.lowercased()
  }

  private static func storedRecord(for graph: String, keys: [String], in stored: [String: Any]) -> String? {
    let canonicalKey = keyPrefix + graph
    for key in [canonicalKey] + keys.filter({ $0 != canonicalKey }).sorted() {
      if let value = stored[key] as? String,
         let record = Record.decode(value), !record.definitions.isEmpty { return value }
    }
    return nil
  }

  private static func admittedRecords(in stored: [String: Any]) -> (records: [String: String], overflow: Bool) {
    let keysByGraph = Dictionary(grouping: stored.keys.compactMap { key in
      graphID(forKey: key).map { (graph: $0, key: key) }
    }, by: \.graph)
    var records: [String: String] = [:]
    for graph in keysByGraph.keys.sorted() {
      guard let value = storedRecord(for: graph, keys: keysByGraph[graph, default: []].map(\.key), in: stored)
      else { continue }
      guard records.count < graphLimit else { return (records, true) }
      records[graph] = value
    }
    return (records, false)
  }

  var snapshot: [String: String] {
    var (records, overflow) = Self.admittedRecords(in: defaults.dictionaryRepresentation())
    if overflow { records["overflow"] = "" }
    return records
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
          let id = UUID(uuidString: String(decoding: body.prefix(upTo: separator), as: UTF8.self)) else { return false }
    let mutation = body.suffix(from: separator + 1)
    guard let expectedEnd = mutation.firstIndex(of: 10),
          mutation.distance(from: mutation.startIndex, to: expectedEnd) <= 6 * Self.recordLimit + 2 else { return false }
    let expected: String?
    do {
      expected = try JSONDecoder().decode(String?.self, from: mutation.prefix(upTo: expectedEnd))
    } catch {
      return false
    }
    let replacement = mutation.suffix(from: expectedEnd + 1)
    guard replacement.count <= Self.recordLimit,
          let text = String(data: replacement, encoding: .utf8),
          let record = Record.decode(text) else { return false }
    let graph = id.uuidString.lowercased()
    let key = Self.keyPrefix + graph
    let stored = defaults.dictionaryRepresentation()
    let keys = stored.keys.filter { Self.graphID(forKey: $0) == graph }
    let current = Self.storedRecord(for: graph, keys: keys, in: stored)
    guard current.map({ Data($0.utf8) }) == expected.map({ Data($0.utf8) }) else { return false }
    if record.definitions.isEmpty {
      for key in keys {
        defaults.removeObject(forKey: key)
      }
      return true
    }
    let (admitted, _) = Self.admittedRecords(in: stored)
    guard admitted[graph] != nil || admitted.count < Self.graphLimit else { return false }
    defaults.set(text, forKey: key)
    return defaults.string(forKey: key) == text
  }
}
