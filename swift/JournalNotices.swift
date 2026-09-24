import Foundation
import Observation
import SwiftUI

/// One OCaml notice request (LJP2 tag 25) being presented to the user. The
/// request resolves when the notice closes, producing the tag-26 response.
struct JournalNoticePresentation: Equatable, Identifiable {
  enum Close {
    case action, dismiss, swipe, timeout
    var result: JournalPlatformWire.NoticeResult {
      switch self {
      case .action: .action
      case .dismiss: .dismiss
      case .swipe: .swipe
      case .timeout: .timeout
      }
    }
  }
  let id: UUID
  let token: String
  let message: String
  let actionLabel: String?
  let durationMilliseconds: Int
}

/// FIFO notice queue; at most one notice presents at a time. Ported from the
/// bonsai `NativeNotices` controller with the response wired to the LJP2
/// platform-response channel instead of a request callback.
@MainActor @Observable final class JournalNotices {
  private final class Entry {
    let presentation: JournalNoticePresentation
    let continuation: CheckedContinuation<JournalNoticePresentation.Close, Never>
    var remaining: Duration
    var presented = false
    var announced = false
    init(
      presentation: JournalNoticePresentation,
      continuation: CheckedContinuation<JournalNoticePresentation.Close, Never>
    ) {
      self.presentation = presentation
      self.continuation = continuation
      remaining = .milliseconds(Int64(presentation.durationMilliseconds))
    }
  }

  private(set) var presentation: JournalNoticePresentation?
  private(set) var active = false
  @ObservationIgnored private var entries: [Entry] = []
  @ObservationIgnored private var timer: Task<Void, Never>?
  @ObservationIgnored private var timerStarted: ContinuousClock.Instant?
  @ObservationIgnored private var voiceOver = false
  private let clock = ContinuousClock()

  func setActive(_ value: Bool) {
    guard active != value else { return }
    active = value
    reconcileTimer()
  }
  func setVoiceOver(_ value: Bool) {
    guard voiceOver != value else { return }
    voiceOver = value
    reconcileTimer()
  }

  func shown(_ id: UUID) {
    guard let first = entries.first, first.presentation.id == id else { return }
    first.presented = true
    if !first.announced {
      first.announced = true
      AccessibilityNotification.Announcement(first.presentation.message).post()
    }
    reconcileTimer()
  }
  func hidden(_ id: UUID) {
    guard let first = entries.first, first.presentation.id == id else { return }
    first.presented = false
    reconcileTimer()
  }
  func close(_ id: UUID, reason: JournalNoticePresentation.Close) {
    guard active, let first = entries.first, first.presented,
      first.presentation.id == id,
      reason != .action || first.presentation.actionLabel != nil
    else { return }
    finish(id, close: reason)
  }

  /// Awaits the close reason for one notice request.
  func show(token: String, message: String, actionLabel: String?, durationMs: Int)
    async -> JournalNoticePresentation.Close
  {
    guard entries.count < 256 else { return .dismiss }
    let id = UUID()
    return await withCheckedContinuation { continuation in
      entries.append(
        Entry(
          presentation: JournalNoticePresentation(
            id: id, token: token, message: message,
            actionLabel: actionLabel, durationMilliseconds: durationMs),
          continuation: continuation))
      if entries.count == 1 { presentation = entries[0].presentation }
    }
  }

  /// Handles LJP2 tag 27. A notice cancelled before it was ever presented is
  /// dropped silently; one already shown resolves as a host dismiss (the
  /// tag-26 response still rides back on the original tag-25 request).
  func cancel(token: String) {
    guard let index = entries.firstIndex(where: { $0.presentation.token == token })
    else { return }
    finish(entries[index].presentation.id, close: .dismiss)
  }

  private func stopTimer() {
    if let started = timerStarted, let first = entries.first {
      first.remaining = max(.zero, first.remaining - started.duration(to: clock.now))
    }
    timerStarted = nil
    timer?.cancel()
    timer = nil
  }
  private func reconcileTimer() {
    guard active, let first = entries.first, first.presented,
      !(voiceOver && first.presentation.actionLabel != nil)
    else {
      stopTimer()
      return
    }
    guard timer == nil else { return }
    timerStarted = clock.now
    let id = first.presentation.id
    let delay = first.remaining
    timer = Task { [weak self] in
      do { try await ContinuousClock().sleep(for: delay) } catch { return }
      guard let self, !Task.isCancelled, entries.first?.presentation.id == id,
        active, entries.first?.presented == true
      else { return }
      finish(id, close: .timeout)
    }
  }
  private func finish(_ id: UUID, close: JournalNoticePresentation.Close) {
    guard let index = entries.firstIndex(where: { $0.presentation.id == id })
    else { return }
    if index == 0 { stopTimer() }
    let entry = entries.remove(at: index)
    if index == 0 { presentation = entries.first?.presentation }
    entry.continuation.resume(returning: close)
  }
  func cancelAll() {
    stopTimer()
    let pending = entries
    entries = []
    presentation = nil
    for entry in pending { entry.continuation.resume(returning: .dismiss) }
  }
}

/// Presents the head notice as a bottom safe-area banner; ported from the
/// bonsai `NativeNoticePresenter` (same layout, gesture, VoiceOver gating).
struct JournalNoticePresenter: ViewModifier {
  let controller: JournalNotices
  @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

  private func notice(_ presentation: JournalNoticePresentation) -> some View {
    let message = Text(presentation.message)
      .lineLimit(5).fixedSize(horizontal: false, vertical: true)
    let buttons = HStack(spacing: 10) {
      if let action = presentation.actionLabel {
        Button(action) {
          controller.close(presentation.id, reason: .action)
        }
        .buttonStyle(.bordered)
      }
      Button {
        controller.close(presentation.id, reason: .dismiss)
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(.borderless).accessibilityLabel("Dismiss notification")
    }
    return ViewThatFits(in: .horizontal) {
      HStack(alignment: .center, spacing: 16) {
        message
        buttons
      }
      VStack(alignment: .leading, spacing: 10) {
        message
        buttons.frame(maxWidth: .infinity, alignment: .trailing)
      }
    }
    .padding(12)
    .frame(maxWidth: 560)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    .contentShape(RoundedRectangle(cornerRadius: 12))
    .accessibilityElement(children: .contain)
    .disabled(!controller.active)
    .simultaneousGesture(
      DragGesture(minimumDistance: 12).onEnded { value in
        if value.translation.height > 40, abs(value.translation.width) < value.translation.height {
          controller.close(presentation.id, reason: .swipe)
        }
      }
    )
    .padding(.horizontal, 12).padding(.vertical, 8)
    .onAppear { controller.shown(presentation.id) }
    .onDisappear { controller.hidden(presentation.id) }
    .id(presentation.id)
  }

  func body(content: Content) -> some View {
    content
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if let presentation = controller.presentation { notice(presentation) }
      }
      .onAppear { controller.setVoiceOver(voiceOver) }
      .onChange(of: voiceOver) { _, value in controller.setVoiceOver(value) }
  }
}
