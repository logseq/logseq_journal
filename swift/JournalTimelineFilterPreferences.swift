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

  private struct LocalDay {
    let year: Int
    let month: Int
    let dayOfYear: Int

    static func sample() -> Self? {
      var now = time(nil)
      var local = tm()
      guard localtime_r(&now, &local) != nil else { return nil }
      let year = Int(local.tm_year) + 1900
      guard year >= 1 else { return nil }
      return Self(year: year, month: Int(local.tm_mon) + 1, dayOfYear: Int(local.tm_yday) + 1)
    }

    var daysSinceYearOne: Int {
      let precedingYears = year - 1
      return 365 * precedingYears + precedingYears / 4 - precedingYears / 100
        + precedingYears / 400 + dayOfYear - 1
    }
  }

  private enum Lookback {
    case days(Int), threeMonths

    func fits(_ today: LocalDay) -> Bool {
      switch self {
      case .days(let count): return count - 1 <= today.daysSinceYearOne
      case .threeMonths: return today.year > 1 || today.month >= 4
      }
    }
  }

  private struct Record: Decodable {
    private static func decodingData(_ text: String) -> Data? {
      let bytes = Array(text.utf8)
      var index = 0
      var copied = 0
      var result = Data()

      func peek() -> UInt8? { index < bytes.count ? bytes[index] : nil }
      func take(_ byte: UInt8) -> Bool {
        guard peek() == byte else { return false }
        index += 1
        return true
      }
      func whitespace() {
        while let byte = peek(), byte == 32 || byte == 9 || byte == 10 || byte == 13 { index += 1 }
      }
      func string() -> Bool {
        guard take(34) else { return false }
        while let byte = peek(), byte >= 32 {
          index += 1
          if byte == 34 { return true }
          if byte == 92 {
            guard let escape = peek() else { return false }
            index += 1
            switch escape {
            case 34, 47, 92, 98, 102, 110, 114, 116: break
            case 117:
              for _ in 0..<4 {
                guard let hex = peek(), (48...57).contains(hex) || (65...70).contains(hex)
                        || (97...102).contains(hex) else { return false }
                index += 1
              }
            default: return false
            }
          }
        }
        return false
      }
      func digits() -> Bool {
        let start = index
        while let byte = peek(), (48...57).contains(byte) { index += 1 }
        return index > start
      }
      func number() -> Bool {
        let start = index
        _ = take(45)
        guard take(48) || digits() else { return false }
        var isFloat = false
        if take(46) {
          guard digits() else { return false }
          isFloat = true
        }
        if take(101) || take(69) {
          _ = take(43) || take(45)
          guard digits() else { return false }
          isFloat = true
        }
        if isFloat {
          result.append(contentsOf: bytes[copied..<start])
          result.append(contentsOf: "false".utf8)
          copied = index
        }
        return true
      }
      func literal(_ token: String) -> Bool {
        for byte in token.utf8 where !take(byte) { return false }
        return true
      }
      func value(depth: Int) -> Bool {
        whitespace()
        switch peek() {
        case 123, 91:
          guard depth < 512 else { return false }
          let object = take(123)
          if !object { index += 1 }
          let end: UInt8 = object ? 125 : 93
          whitespace()
          if take(end) { return true }
          repeat {
            whitespace()
            if object {
              guard string() else { return false }
              whitespace()
              guard take(58) else { return false }
            }
            guard value(depth: depth + 1) else { return false }
            whitespace()
          } while take(44)
          return take(end)
        case 34: return string()
        case 116: return literal("true")
        case 102: return literal("false")
        case 110: return literal("null")
        default: return number()
        }
      }

      whitespace()
      guard peek() == 123, value(depth: 0) else { return nil }
      whitespace()
      guard index == bytes.count else { return nil }
      result.append(contentsOf: bytes[copied...])
      return result
    }
    struct Definition: Decodable {
      let name: String
      let tags: [UUID]
      let statuses: [UUID]
      let lookback: Lookback

      private enum CodingKeys: String, CodingKey { case name, tags, statuses, time }

      init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        name = try fields.decode(String.self, forKey: .name)
        tags = try fields.decode([UUID].self, forKey: .tags)
        statuses = try fields.decode([UUID].self, forKey: .statuses)
        if let preset = try? fields.decode(String.self, forKey: .time) {
          switch preset {
          case "14-days": lookback = .days(14); return
          case "any", "3-months": lookback = .threeMonths; return
          default: break
          }
        }
        var time = try fields.nestedUnkeyedContainer(forKey: .time)
        let count = try time.decode(Int.self)
        let unit = try time.decode(String.self)
        let ocamlMaxInt = Int.max / 2
        guard time.isAtEnd, count > 0,
              (unit == "days" && count <= ocamlMaxInt || unit == "weeks" && count <= ocamlMaxInt / 7) else {
          throw DecodingError.dataCorruptedError(forKey: .time, in: fields, debugDescription: "Invalid relative time")
        }
        lookback = .days(unit == "weeks" ? 7 * count : count)
      }

      var trimmedName: Data {
        Data(name.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n\u{000C}")).utf8)
      }
    }

    let version: Int
    let definitions: [Definition]
    let selected: String?

    private enum CodingKeys: String, CodingKey { case version, definitions, selected }

    init(from decoder: Decoder) throws {
      let fields = try decoder.container(keyedBy: CodingKeys.self)
      version = try fields.decode(Int.self, forKey: .version)
      if version == 1 {
        definitions = []
        selected = nil
      } else {
        definitions = try fields.decode([Definition].self, forKey: .definitions)
        selected = try fields.decodeIfPresent(String.self, forKey: .selected)
      }
    }

    static func decode(_ text: String, today: LocalDay?) -> Self? {
      guard text.utf8.prefix(JournalTimelineFilterPreferences.recordLimit + 1).count
              <= JournalTimelineFilterPreferences.recordLimit,
            let data = decodingData(text),
            let record = try? JSONDecoder().decode(Self.self, from: data),
            record.version == 1 || record.version == 2, record.definitions.count <= 5 else { return nil }
      var lookbacks: [Data: Lookback] = [:]
      for definition in record.definitions {
        let name = definition.trimmedName
        guard (1...128).contains(name.count), lookbacks[name] == nil,
              definition.tags.count <= 100, definition.statuses.count <= 100 else { return nil }
        lookbacks[name] = definition.lookback
      }
      let applied: Lookback
      if let selected = record.selected {
        guard let lookback = lookbacks[Data(selected.utf8)] else { return nil }
        applied = lookback
      } else {
        applied = .threeMonths
      }
      guard today.map(applied.fits) ?? true else { return nil }
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
    let text: String
    let hasDefinitions: Bool

    init?(_ value: Any, today: LocalDay?) {
      guard let text = value as? String, let record = Record.decode(text, today: today) else { return nil }
      hasDefinitions = !record.definitions.isEmpty
      self.text = text
    }
  }

  private struct Entry {
    let key: String
    let record: StoredRecord
  }

  var snapshot: [String: String] {
    let today = LocalDay.sample()
    var records: [String: Entry] = [:]
    for key in defaults.dictionaryRepresentation().keys {
      guard let graph = Self.graphID(forKey: key), let value = defaults.object(forKey: key) else { continue }
      guard let record = StoredRecord(value, today: today) else {
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
    let today = LocalDay.sample()
    guard replacement.count <= Self.recordLimit,
          !replacement.starts(with: [0xEF, 0xBB, 0xBF]),
          let text = String(data: replacement, encoding: .utf8),
          let record = Record.decode(text, today: today), record.version == 2 else { return false }
    let graph = id.uuidString.lowercased()
    let stored = defaults.dictionaryRepresentation()
    let keys = stored.keys.filter { Self.graphID(forKey: $0) == graph }
    guard keys.count <= 1 else { return false }
    let key = keys.first ?? Self.keyPrefix + graph
    let hasDefinitions: Bool
    if let value = stored[key] {
      guard let expected, let current = StoredRecord(value, today: today), current.text.utf8.elementsEqual(expected.utf8)
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
              StoredRecord(value, today: today)?.hasDefinitions == true else { continue }
        occupied.insert(storedGraph)
        if occupied.count == Self.graphLimit { return false }
      }
    }
    defaults.set(text, forKey: key)
    return true
  }
}
