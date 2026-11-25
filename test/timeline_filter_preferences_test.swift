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
    let bounded = reopened.wrapStartup(Data([0, 255]))
    precondition(bounded.count < 1024)
    precondition(trySnapshot(bounded)[graphB] == custom)
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
