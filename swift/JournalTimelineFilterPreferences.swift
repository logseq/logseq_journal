import Foundation

struct JournalSavedFilterName: Identifiable {
  let name: String
  var id: Data { Data(name.utf8) }
}

@MainActor struct JournalTimelineFilterPreferences {
  let defaults: UserDefaults
  private static let keyPrefix = "journal.timeline-filter.graph."
  private static let commitPrefix = Data("journal.timeline-filter.commit\n".utf8)
  private nonisolated static let recordLimit = 64 * 1024
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

  private struct StoredRecord {
    private struct Version: Decodable { let version: Int }

    let text: String
    let hasDefinitions: Bool

    init?(_ value: Any) {
      guard let text = value as? String, text.utf8.prefix(recordLimit + 1).count <= recordLimit else { return nil }
      if let record = Record.decode(text) {
        hasDefinitions = !record.definitions.isEmpty
      } else if (try? JSONDecoder().decode(Version.self, from: Data(text.utf8)))?.version == 1 {
        hasDefinitions = false
      } else {
        return nil
      }
      self.text = text
    }
  }

  private struct Entry {
    let key: String
    let record: StoredRecord
  }

  var snapshot: [String: String] {
    var records: [String: Entry] = [:]
    for key in defaults.dictionaryRepresentation().keys {
      guard let graph = Self.graphID(forKey: key), let value = defaults.object(forKey: key) else { continue }
      guard let record = StoredRecord(value) else {
        defaults.removeObject(forKey: key)
        continue
      }
      if let existing = records[graph] {
        if existing.record.hasDefinitions != record.hasDefinitions {
          guard record.hasDefinitions else { continue }
        } else {
          guard key == Self.keyPrefix + graph ||
                  (existing.key != Self.keyPrefix + graph && key < existing.key) else { continue }
        }
      }
      records[graph] = Entry(key: key, record: record)
    }
    let graphs = records.keys.sorted {
      let left = records[$0]!.record.hasDefinitions
      let right = records[$1]!.record.hasDefinitions
      return left == right ? $0 < $1 : left
    }
    var snapshot = Dictionary(uniqueKeysWithValues: graphs.prefix(Self.graphLimit).map {
      ($0, records[$0]!.record.text)
    })
    if graphs.count > Self.graphLimit { snapshot["overflow"] = "" }
    return snapshot
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
    let stored = defaults.dictionaryRepresentation()
    let keys = stored.keys.filter { Self.graphID(forKey: $0) == graph }
    guard keys.count <= 1 else { return false }
    let key = keys.first ?? Self.keyPrefix + graph
    let hasDefinitions: Bool
    if let value = stored[key] {
      guard let expected, let current = StoredRecord(value), current.text.utf8.elementsEqual(expected.utf8)
      else { return false }
      hasDefinitions = current.hasDefinitions
    } else {
      guard expected == nil else { return false }
      hasDefinitions = false
    }
    if record.definitions.isEmpty {
      if !keys.isEmpty { defaults.removeObject(forKey: key) }
      return true
    }
    if !hasDefinitions {
      var occupied: Set<String> = []
      for (storedKey, value) in stored {
        guard let storedGraph = Self.graphID(forKey: storedKey), !occupied.contains(storedGraph),
              StoredRecord(value)?.hasDefinitions == true else { continue }
        occupied.insert(storedGraph)
        if occupied.count == Self.graphLimit { return false }
      }
    }
    defaults.set(text, forKey: key)
    return true
  }
}
