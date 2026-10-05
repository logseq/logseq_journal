import Foundation

/// Owns one add-only save operation independently of the preview/graph lifetime.
@MainActor final class JournalPhotoSave {
  enum Authorization { case notDetermined, authorized, denied, restricted }
  enum Feedback: Equatable { case saved, denied, restricted, notImage, failed }
  enum StageError: Error { case notImage }

  final class FileLease {
    let url: URL
    private var release: (() -> Void)?
    init(url: URL, release: @escaping () -> Void) { self.url = url; self.release = release }
    func close() {
      let cleanup = release
      release = nil
      cleanup?()
    }
    deinit { release?() }
  }

  struct Dependencies {
    let authorization: () -> Authorization
    let requestAuthorization: (@escaping @MainActor (Authorization) -> Void) -> Void
    let stage: (URL) throws -> FileLease
    let write: (URL, @escaping @MainActor (Bool) -> Void) -> Void
    let feedback: (Feedback) -> Void
  }

  private final class Operation {
    let file: FileLease
    var writing = false
    init(file: FileLease) { self.file = file }
  }

  private let dependencies: Dependencies
  private var operation: Operation?
  private var closed = false
  var onBusyChanged: ((Bool) -> Void)?
  var busy: Bool { operation != nil }

  init(dependencies: Dependencies) { self.dependencies = dependencies }

  func save(_ selectedURL: URL) {
    guard !closed, operation == nil else { return }
    let authorization = dependencies.authorization()
    switch authorization {
    case .denied: dependencies.feedback(.denied); return
    case .restricted: dependencies.feedback(.restricted); return
    case .authorized, .notDetermined: break
    }
    let file: FileLease
    do { file = try dependencies.stage(selectedURL) }
    catch StageError.notImage { dependencies.feedback(.notImage); return }
    catch { dependencies.feedback(.failed); return }
    let current = Operation(file: file)
    operation = current
    onBusyChanged?(true)
    if authorization == .authorized {
      authorized(.authorized, operation: current)
    } else {
      dependencies.requestAuthorization { [self, current] result in
        authorized(result, operation: current)
      }
    }
  }

  private func authorized(_ result: Authorization, operation current: Operation) {
    guard operation === current, !closed, !current.writing else { return }
    switch result {
    case .authorized:
      current.writing = true
      // Completion retains this owner and file even if the UI disappears.
      dependencies.write(current.file.url) { [self, current] success in
        guard operation === current else { return }
        finish(current, feedback: success ? .saved : .failed)
      }
    case .denied, .notDetermined: finish(current, feedback: .denied)
    case .restricted: finish(current, feedback: .restricted)
    }
  }

  private func finish(_ current: Operation, feedback: Feedback?) {
    guard operation === current else { return }
    current.file.close()
    operation = nil
    onBusyChanged?(false)
    if !closed, let feedback { dependencies.feedback(feedback) }
  }

  func close() {
    closed = true
    // Photos cannot cancel an admitted transaction. Keep its input until the
    // completion; an outstanding permission request can safely be abandoned.
    if let current = operation, !current.writing { finish(current, feedback: nil) }
  }
}
