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
    func commit(_ graph: String, _ criteria: String) -> Bool {
      preferences.handleCommit(Data("journal.timeline-filter.commit\n\(graph)\n\(criteria)".utf8))
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
    precondition(!commit(graphA, ""))
    precondition(!commit(graphA, String(repeating: "a", count: 512 * 1024 + 1)))
    precondition(reopened.snapshot == [graphA: preset, graphB: custom])
    precondition(commit(graphA, noSelection))
    precondition(trySnapshot(reopened.wrapStartup(Data([0, 255]))) == [graphA: noSelection, graphB: custom])
    defaults.set(String(repeating: "\\", count: 512 * 1024 + 1),
                 forKey: "journal.timeline-filter.graph.\(graphA)")
    let bounded = reopened.wrapStartup(Data([0, 255]))
    precondition(bounded.count < 1024)
    precondition(trySnapshot(bounded)[graphB] == custom)
    precondition(trySnapshot(bounded)[graphA] == "")
    for index in 3...65 {
      let graph = String(format: "10000000-0000-4000-8000-%012d", index)
      precondition(commit(graph, preset))
    }
    let capped = trySnapshot(reopened.wrapStartup(Data([0, 255])))
    precondition(capped.count == 65 && capped["overflow"] == "")
    precondition(capped[graphB] == custom)
    precondition(capped["10000000-0000-4000-8000-000000000064"] == preset)
    precondition(capped["10000000-0000-4000-8000-000000000065"] == nil)
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
