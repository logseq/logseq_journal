import Foundation

/// Transient native feedback follows the gesture's scoped owners, not its name.
struct JournalGraphNameFeedback {
  enum Phase { case preview, waiting, confirmed }
  struct Presentation: Identifiable {
    var id = UUID()
    let source: String
    let target: String
    var name: String
    var phase = Phase.preview
  }
  private(set) var presentation: Presentation?

  mutating func show(source: String, target: String, name: String?) {
    presentation = name.flatMap { name in
      name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil
        : Presentation(source: source, target: target, name: name)
    }
  }
  mutating func commit(source: String, target: String) {
    guard presentation?.source == source, presentation?.target == target else { return }
    presentation?.phase = .waiting
  }
  mutating func focusChanged(_ page: String?) {
    guard var current = presentation else { return }
    if current.phase == .waiting, page == current.target {
      current.id = UUID()
      current.phase = .confirmed
      presentation = current
    } else if page != current.source || current.phase != .waiting {
      presentation = nil
    }
  }
  mutating func updateName(target: String?, name: String?) {
    guard presentation?.target == target else { return }
    guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      cancel(); return
    }
    presentation?.name = name
  }
  mutating func retain(_ pages: [String]) {
    if let current = presentation,
      !pages.contains(current.source) || !pages.contains(current.target) { cancel() }
  }
  mutating func dismiss(_ id: UUID) {
    if presentation?.id == id { cancel() }
  }
  mutating func cancel() { presentation = nil }
}
