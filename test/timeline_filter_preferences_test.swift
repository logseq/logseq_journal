import Foundation

@main struct TimelineFilterPreferencesTest {
  static func main() throws {
    let suite = "journal.timeline-filter.test.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let graphA = "10000000-0000-4000-8000-000000000001"
    let graphB = "10000000-0000-4000-8000-000000000002"
    let preset = #"{"version":2,"definitions":[{"name":"Work","tags":[],"statuses":[],"time":"14-days"}],"selected":"Work"}"#
    let custom = #"{"version":2,"definitions":[{"name":"Other","tags":[],"statuses":[],"time":[7,"days"]}],"selected":"Other"}"#
    let preferences = JournalTimelineFilterPreferences(defaults: defaults)
    func commit(_ graph: String, _ criteria: String, expecting: String? = nil) -> Bool {
      let expected = String(decoding: try! JSONEncoder().encode(expecting), as: UTF8.self)
      return preferences.handleCommit(Data("journal.timeline-filter.commit\n\(graph)\n\(expected)\n\(criteria)".utf8))
    }
    precondition(preferences.snapshot.isEmpty)
    precondition(commit(graphA, preset))
    precondition(commit(graphB, custom))
    let reopened = JournalTimelineFilterPreferences(defaults: UserDefaults(suiteName: suite)!)
    precondition(reopened.snapshot == [graphA: preset, graphB: custom])
    preferences.handleCommit(Data("journal.timeline-filter.draft\n\(graphA)\n".utf8))
    precondition(!commit("not-a-uuid", custom))
    precondition(reopened.snapshot == [graphA: preset, graphB: custom])
    let noSelection = #"{"version":2,"definitions":[{"name":"Work","tags":[],"statuses":[],"time":"14-days"}],"selected":null}"#
    precondition(!commit(graphA, "", expecting: preset))
    precondition(!commit(graphA, String(repeating: "a", count: 512 * 1024 + 1), expecting: preset))
    precondition(reopened.snapshot == [graphA: preset, graphB: custom])
    precondition(commit(graphA, noSelection, expecting: preset))
    precondition(trySnapshot(reopened.wrapStartup(Data([0, 255]))) == [graphA: noSelection, graphB: custom])
    defaults.set(String(repeating: "\\", count: 512 * 1024 + 1),
                 forKey: "journal.timeline-filter.graph.\(graphA)")
    let keyPrefix = "journal.timeline-filter.graph."
    let keyA = keyPrefix + graphA
    defaults.set("unrelated", forKey: "journal.other-preference")
    precondition(!commit(graphA, preset), "An invalid record inserted after startup is not absence")
    precondition(!commit(graphA, #"{"version":2,"definitions":[]}"#))
    let bounded = reopened.wrapStartup(Data([0, 255]))
    precondition(bounded.count < 1024)
    precondition(trySnapshot(bounded) == [graphB: custom])
    precondition(defaults.object(forKey: keyA) == nil, "Startup must delete the oversized record")
    precondition(defaults.string(forKey: "journal.other-preference") == "unrelated")
    precondition(!commit(graphA, custom, expecting: noSelection), "Old snapshot must not resurrect a deleted record")
    precondition(reopened.snapshot == [graphB: custom])
    let equivalentNames = #"{"version":2,"definitions":[{"name":"\u00e9","tags":[],"statuses":[],"time":"any"},{"name":"e\u0301","tags":[],"statuses":[],"time":"14-days"}],"selected":"e\u0301"}"#
    let composed = JournalSavedFilterName(name: "\u{00e9}")
    let decomposed = JournalSavedFilterName(name: "e\u{0301}")
    precondition(composed.name == decomposed.name)
    precondition(composed.id == Data([0xc3, 0xa9]))
    precondition(decomposed.id == Data([0x65, 0xcc, 0x81]))
    precondition(Set([composed.id, decomposed.id]).count == 2)
    let remainingName = #"{"version":2,"definitions":[{"name":"e\u0301","tags":[],"statuses":[],"time":"14-days"}],"selected":"e\u0301"}"#
    precondition(commit(graphA, equivalentNames))
    precondition(reopened.snapshot[graphA] == equivalentNames)
    precondition(commit(graphA, remainingName, expecting: equivalentNames))
    precondition(reopened.snapshot[graphA] == remainingName)
    precondition(commit(graphA, #"{"version":2,"definitions":[]}"#, expecting: remainingName))
    func graph(_ index: Int) -> String {
      String(format: "10000000-0000-4000-8000-%012d", index)
    }
    for (index, legacy) in [#"{"version":1}"#, #"{"version":3,"definitions":[]}"#,
                            #"{"version":2,"definitions":[],"selected":null}"#,
                            #"{"version":2,"definitions":[{"name":"Broken"}],"selected":null}"#,
                            preset.replacingOccurrences(of: "\"selected\":\"Work\"", with: "\"selected\":\"Missing\""),
                            "not json"].enumerated() {
      defaults.set(legacy, forKey: "journal.timeline-filter.graph.\(graph(index + 3))")
    }
    let nonStringKey = keyPrefix + graph(9)
    defaults.set(["version": 2], forKey: nonStringKey)
    let legacyKey = keyPrefix + graph(3)
    let emptyKey = keyPrefix + graph(5)
    let startupAfterCleanup = reopened.snapshot
    precondition(defaults.string(forKey: legacyKey) == #"{"version":1}"#)
    precondition(defaults.string(forKey: emptyKey) == #"{"version":2,"definitions":[],"selected":null}"#)
    for index in [4, 6, 7, 8, 9] {
      precondition(defaults.object(forKey: keyPrefix + graph(index)) == nil, "Invalid record \(index) survived startup")
    }
    precondition(!commit(graph(4), custom, expecting: #"{"version":3,"definitions":[]}"#))
    precondition(commit(graph(4), custom, expecting: startupAfterCleanup[graph(4)]))
    precondition(commit(graph(4), #"{"version":2,"definitions":[]}"#, expecting: custom))
    defaults.set(custom, forKey: keyA)
    precondition(!commit(graphA, preset, expecting: startupAfterCleanup[graphA]))
    precondition(defaults.string(forKey: keyA) == custom)
    precondition(commit(graphA, #"{"version":2,"definitions":[]}"#, expecting: custom))
    let aliasGraph = "a0000000-0000-4000-8000-000000000000"
    let aliasKey = keyPrefix + aliasGraph.uppercased()
    defaults.set(custom, forKey: aliasKey)
    defaults.set("broken", forKey: keyPrefix + aliasGraph)
    precondition(reopened.snapshot[aliasGraph] == custom)
    precondition(defaults.object(forKey: keyPrefix + aliasGraph) == nil)
    defaults.set(preset, forKey: keyPrefix + aliasGraph)
    precondition(!commit(aliasGraph, #"{"version":2,"definitions":[]}"#, expecting: custom))
    precondition(defaults.string(forKey: aliasKey) == custom)
    precondition(defaults.string(forKey: keyPrefix + aliasGraph) == preset)
    defaults.removeObject(forKey: keyPrefix + aliasGraph)
    precondition(commit(aliasGraph, #"{"version":2,"definitions":[]}"#, expecting: custom))
    precondition(reopened.snapshot[aliasGraph] == nil, "An alias must not reappear after deletion")
    precondition(!commit(graph(3), preset), "An unobserved legacy value is not absence")
    precondition(commit(graph(3), preset, expecting: startupAfterCleanup[graph(3)]))
    precondition(commit(graph(3), #"{"version":2,"definitions":[]}"#, expecting: preset))
    precondition(commit(graph(5), #"{"version":2,"definitions":[]}"#, expecting: startupAfterCleanup[graph(5)]))
    let invalidRecords = [
      #"{"version":2.0,"definitions":[],"selected":null}"#,
      #"{"version":1e0}"#,
      #"{"version":2,"definitions":[{"name":"Float","tags":[],"statuses":[],"time":[7.0,"days"]}],"selected":null}"#,
      #"{"version":2,"definitions":[{"name":"Float","tags":[],"statuses":[],"time":[7e0,"weeks"]}],"selected":"Float"}"#,
      #"{"version":2,"definitions":[{"name":"Too far","tags":[],"statuses":[],"time":[1000000,"weeks"]}],"selected":"Too far"}"#,
    ]
    let validRecords = [
      #"{"version":1,"ignored":2.0}"#,
      #"{"version":2,"definitions":[{"name":"7.0 days","tags":[],"statuses":[],"time":[7,"days"],"ignored":2.0}],"selected":"7.0 days"}"#,
      #"{"version":2,"definitions":[{"name":"Too far","tags":[],"statuses":[],"time":[1000000,"weeks"]}],"selected":null}"#,
    ]
    for (index, text) in (invalidRecords + validRecords).enumerated() {
      defaults.set(text, forKey: keyPrefix + graph(index + 100))
    }
    let cleaned = trySnapshot(reopened.wrapStartup(Data([0, 255])))
    for (index, text) in invalidRecords.enumerated() {
      let id = graph(index + 100)
      precondition(cleaned[id] == nil && defaults.object(forKey: keyPrefix + id) == nil,
                   "Invalid persisted record survived startup: \(text)")
      precondition(!commit(id, text), "Commit accepted an invalid replacement: \(text)")
    }
    for (index, text) in validRecords.enumerated() {
      let id = graph(index + 100 + invalidRecords.count)
      precondition(cleaned[id] == text && defaults.string(forKey: keyPrefix + id) == text)
      defaults.removeObject(forKey: keyPrefix + id)
    }
    var expected = [graphB: custom]
    for index in 10...72 {
      precondition(commit(graph(index), preset))
      expected[graph(index)] = preset
    }
    precondition(!commit(graph(0), preset), "A write must not displace an existing graph")
    precondition(!commit(graph(73), preset), "A write must not succeed and disappear on restart")
    precondition(trySnapshot(reopened.wrapStartup(Data([0, 255]))) == expected)
    precondition(commit(graph(72), noSelection, expecting: preset))
    expected[graph(72)] = noSelection
    precondition(trySnapshot(reopened.wrapStartup(Data([0, 255]))) == expected)
    let empty = #"{"version":2,"definitions":[],"selected":null}"#
    precondition(commit(graphB, empty, expecting: custom))
    expected.removeValue(forKey: graphB)
    precondition(commit(graph(73), preset))
    expected[graph(73)] = preset
    precondition(trySnapshot(reopened.wrapStartup(Data([0, 255]))) == expected)
    defaults.set(preset, forKey: "journal.timeline-filter.graph.\(graph(74))")
    expected["overflow"] = ""
    precondition(trySnapshot(reopened.wrapStartup(Data([0, 255]))) == expected)
    let overflowKey = "journal.timeline-filter.graph.\(graph(74))"
    let startup = reopened.snapshot
    precondition(startup[graph(74)] == nil)
    precondition(commit(graph(10), empty, expecting: startup[graph(10)]))
    precondition(reopened.snapshot[graph(74)] == preset)
    precondition(!commit(graph(74), custom), "An unseen record must not be overwritten after admission")
    precondition(!commit(graph(74), empty), "An unseen record must not be deleted after admission")
    precondition(defaults.string(forKey: overflowKey) == preset)
    precondition(commit(graph(74), custom, expecting: reopened.snapshot[graph(74)]))
    precondition(defaults.string(forKey: overflowKey) == custom)
  }

  static func trySnapshot(_ data: Data) -> [String: String] {
    let prefix = Data("JTF1".utf8)
    precondition(data.starts(with: prefix))
    let framed = data.dropFirst(prefix.count)
    let separator = framed.firstIndex(of: 10)!
    precondition(framed.suffix(from: separator + 1) == Data([0, 255]))
    return try! JSONDecoder().decode([String: String].self, from: framed.prefix(upTo: separator))
  }
}
