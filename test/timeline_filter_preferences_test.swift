import Foundation

@main struct TimelineFilterPreferencesTest {
  static func main() throws {
    let suite = "journal.timeline-filter.test.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let graphA = "10000000-0000-4000-8000-000000000001"
    let graphB = "10000000-0000-4000-8000-000000000002"
    let preset = #"{"version":1,"tags":[],"statuses":[],"time":"past-7-days"}"#
    let custom = #"{"version":1,"tags":[],"statuses":[],"time":[7,"days"]}"#
    let preferences = JournalTimelineFilterPreferences(defaults: defaults)
    func commit(_ graph: String, _ criteria: String) {
      preferences.handleCommit(Data("journal.timeline-filter.commit\n\(graph)\n\(criteria)".utf8))
    }
    precondition(preferences.snapshot.isEmpty)
    commit(graphA, preset)
    commit(graphB, custom)
    let reopened = JournalTimelineFilterPreferences(defaults: UserDefaults(suiteName: suite)!)
    precondition(reopened.snapshot == [graphA: preset, graphB: custom])
    preferences.handleCommit(Data("journal.timeline-filter.draft\n\(graphA)\n".utf8))
    commit("not-a-uuid", custom)
    precondition(reopened.snapshot == [graphA: preset, graphB: custom])
    commit(graphA, "")
    precondition(reopened.snapshot == [graphB: custom])
    precondition(trySnapshot(reopened.wrapStartup(Data([0, 255]))) == [graphB: custom])
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
