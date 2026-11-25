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

  private static func admittedRecords(in stored: [String: Any]) -> (records: [String: String], overflow: Bool) {
    let keysByGraph = Dictionary(grouping: stored.keys.compactMap { key in
      graphID(forKey: key).map { (graph: $0, key: key) }
    }, by: \.graph)
    var records: [String: String] = [:]
    for graph in keysByGraph.keys.sorted() {
      let canonicalKey = keyPrefix + graph
      let keys = [canonicalKey] + keysByGraph[graph, default: []].map(\.key).filter { $0 != canonicalKey }.sorted()
      for key in keys {
        guard let value = stored[key] as? String,
              let record = Record.decode(value), !record.definitions.isEmpty else { continue }
        guard records.count < graphLimit else { return (records, true) }
        records[graph] = value
        break
      }
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
          let id = UUID(uuidString: String(decoding: body.prefix(upTo: separator), as: UTF8.self)),
          body.count - body.distance(from: body.startIndex, to: separator) - 1 <= Self.recordLimit,
          let text = String(data: body.suffix(from: separator + 1), encoding: .utf8),
          let record = Record.decode(text) else { return false }
    let graph = id.uuidString.lowercased()
    let key = Self.keyPrefix + graph
    let stored = defaults.dictionaryRepresentation()
    if record.definitions.isEmpty {
      for key in stored.keys where Self.graphID(forKey: key) == graph {
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
