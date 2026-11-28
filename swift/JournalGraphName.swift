import Foundation

/// Transient native feedback follows the gesture's scoped owners, not its name.
struct JournalGraphNameFeedback {
  enum Phase { case preview, waiting, confirmed }
  struct Presentation: Identifiable {
    var id = UUID()
    let source: String
    let target: String
    let sourceName: String?
    var name: String
    var phase = Phase.preview
  }
  private(set) var presentation: Presentation?

  private func visibleName(_ name: String?) -> String? {
    guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return name
  }

  mutating func show(source: String, target: String, sourceName: String? = nil, name: String?) {
    presentation = visibleName(name).map {
      Presentation(source: source, target: target, sourceName: visibleName(sourceName), name: $0)
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
    guard let name = visibleName(name) else {
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
