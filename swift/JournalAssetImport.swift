import CryptoKit
import LUIAppleBackend
import Observation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

private actor JournalAssetStaging {
  static let shared = JournalAssetStaging()

  func copy(_ source: URL) -> URL? {
    let scoped = source.startAccessingSecurityScopedResource()
    defer { if scoped { source.stopAccessingSecurityScopedResource() } }
    let ext = source.pathExtension.lowercased()
    let name = "journal-import-" + UUID().uuidString.lowercased() + (ext.isEmpty ? "" : "." + ext)
    let dest = FileManager.default.temporaryDirectory.appendingPathComponent(name)
    do { try FileManager.default.copyItem(at: source, to: dest); return dest }
    catch { try? FileManager.default.removeItem(at: dest); return nil }
  }

  func write(_ data: Data, ext: String) -> URL? {
    let dest = FileManager.default.temporaryDirectory.appendingPathComponent("journal-import-" + UUID().uuidString.lowercased() + "." + ext)
    do { try data.write(to: dest); return dest }
    catch { try? FileManager.default.removeItem(at: dest); return nil }
  }
}

@MainActor enum JournalAssetImport {
  struct Request: Decodable, Equatable {
    let id: Int
    let source: String?
    let staged: Bool?
    let maxSelections: Int?
  }

  struct PendingItem: Decodable, Identifiable {
    let token: String
    let path: String
    let title: String
    let type: String?
    let sourceIdentity: String?
    var id: String { token }
    var fileType: String { type ?? "bin" }
    var isImage: Bool { JournalImportThumbnail.imageTypes.contains(fileType) }
  }

  struct Properties: Decodable {
    let enabled: Bool
    let completion: String?
    let error: String?
    let request: Request?
    let pending: [PendingItem]?
  }

  @Observable final class Selection {
    var operation: String?
    private var source: URL?
    private var scoped = false

    func retain(_ url: URL, operation: String) {
      release()
      source = url
      scoped = url.startAccessingSecurityScopedResource()
      self.operation = operation
    }

    func release() {
      if scoped { source?.stopAccessingSecurityScopedResource() }
      source = nil
      scoped = false
      operation = nil
    }
  }

  #if os(iOS)
  private struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
      Coordinator(onImage: onImage, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
      let picker = UIImagePickerController()
      picker.sourceType = .camera
      picker.delegate = context.coordinator
      return picker
    }

    func updateUIViewController(_: UIImagePickerController, context _: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate,
      UINavigationControllerDelegate
    {
      let onImage: (UIImage) -> Void
      let onCancel: () -> Void

      init(onImage: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
        self.onImage = onImage
        self.onCancel = onCancel
      }

      func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
      ) {
        if let image = info[.originalImage] as? UIImage { onImage(image) }
        picker.dismiss(animated: true)
      }

      func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        onCancel()
        picker.dismiss(animated: true)
      }
    }
  }
  #endif

  struct View: SwiftUI.View {
    let context: LUIAppleExtensionViewContext
    @State private var selection = Selection()
    @State private var filePresented = false
    @State private var photosPresented = false
    @State private var cameraPresented = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var importTask: Task<Void, Never>?
    @State private var armedRequest: Request?
    @State private var epoch = 0
    @State private var handled = false
    @State private var lastRequest = 0
    @State private var error: String?

    private var properties: Properties? {
      JournalExtensions.decode(Properties.self, context: context)
    }

    private var request: Request? { properties?.request }

    private func emit(_ object: [String: Any]) -> Bool {
      guard let data = try? JSONSerialization.data(withJSONObject: object) else { return false }
      return JournalExtensions.emit(context: context, payload: data)
    }

    private func isCurrent(_ request: Request, epoch: Int) -> Bool {
      self.epoch == epoch && self.request?.id == request.id
        && context.isUserInteractionEnabled && properties?.enabled == true
    }

    private func emitDismissed() {
      guard !handled else { return }
      handled = true
      _ = emit(["action": "dismissed", "request": armedRequest?.id ?? 0])
    }

    private func emitUnavailable(_ reason: String, request: Request) {
      handled = true
      _ = emit(["action": "unavailable", "reason": reason, "request": request.id])
    }

    private func requestPayload(_ request: Request) -> [String: Any] {
      ["id": request.id, "source": request.source ?? "files", "staged": request.staged ?? false]
    }

    private func pick(path: String, title: String, type: String, identity: String) -> [String: Any] {
      ["operation": UUID().uuidString.lowercased(), "asset": UUID().uuidString.lowercased(),
       "localMutation": UUID().uuidString.lowercased(), "metadataMutation": UUID().uuidString.lowercased(),
       "path": path, "title": title, "type": type.isEmpty ? "bin" : type, "sourceIdentity": identity]
    }

    private func discard(_ items: [[String: Any]]) {
      for item in items {
        guard let path = item["path"] as? String else { continue }
        try? FileManager.default.removeItem(atPath: path)
      }
    }

    private func emitBatch(_ items: [[String: Any]], failures: Int, request: Request, epoch: Int) {
      guard !Task.isCancelled, isCurrent(request, epoch: epoch) else { discard(items); return }
      handled = true
      var payload: [String: Any] = ["action": "picked-batch", "request": requestPayload(request), "items": items]
      if failures > 0 { payload["error"] = "\(failures) selected item(s) could not be added. Your other attachments are kept." }
      if !emit(payload) {
        discard(items)
        error = "The destination is no longer available. Select the files again."
      }
    }

    private func handleFiles(_ sources: [URL], request: Request, epoch: Int) async {
      guard !Task.isCancelled, isCurrent(request, epoch: epoch) else { return }
      handled = true
      guard request.staged == true else {
        guard let source = sources.first else { return }
        var item = pick(path: source.path(percentEncoded: false), title: source.lastPathComponent,
                        type: source.pathExtension.lowercased(), identity: "files:" + source.standardizedFileURL.absoluteString)
        let operation = item["operation"] as! String
        selection.retain(source, operation: operation)
        item["request"] = requestPayload(request)
        if !emit(item) { selection.release(); error = "The destination is no longer available. Select the file again." }
        return
      }
      var items: [[String: Any]] = []
      var seen = Set((properties?.pending ?? []).compactMap(\.sourceIdentity))
      var failures = 0
      let remaining = max(0, request.maxSelections ?? sources.count)
      for source in sources {
        let identity = "files:" + source.standardizedFileURL.absoluteString
        guard seen.insert(identity).inserted else { continue }
        guard items.count < remaining else { failures += 1; continue }
        guard !Task.isCancelled, isCurrent(request, epoch: epoch) else { discard(items); return }
        guard let copy = await JournalAssetStaging.shared.copy(source) else { failures += 1; continue }
        guard !Task.isCancelled, isCurrent(request, epoch: epoch) else {
          try? FileManager.default.removeItem(at: copy); discard(items); return
        }
        items.append(pick(path: copy.path(percentEncoded: false), title: source.lastPathComponent,
                          type: source.pathExtension.lowercased(), identity: identity))
      }
      emitBatch(items, failures: failures, request: request, epoch: epoch)
    }

    private func stageData(_ data: Data, ext: String, title: String, identity: String) async -> [String: Any]? {
      guard let dest = await JournalAssetStaging.shared.write(data, ext: ext) else { return nil }
      return pick(path: dest.path(percentEncoded: false), title: title, type: ext, identity: identity)
    }

    private func importPhotos(_ selected: [PhotosPickerItem], request: Request, epoch: Int) async {
      var items: [[String: Any]] = []
      var seen = Set((properties?.pending ?? []).compactMap(\.sourceIdentity))
      var failures = 0
      let remaining = max(0, request.maxSelections ?? selected.count)
      for item in selected {
        guard !Task.isCancelled, isCurrent(request, epoch: epoch) else { discard(items); return }
        if let identifier = item.itemIdentifier, seen.contains("photos:" + identifier) { continue }
        guard items.count < remaining else { failures += 1; continue }
        guard let data = try? await item.loadTransferable(type: Data.self) else { failures += 1; continue }
        guard !Task.isCancelled, isCurrent(request, epoch: epoch) else { discard(items); return }
        let identity = "photos:" + (item.itemIdentifier ?? SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        guard seen.insert(identity).inserted else { continue }
        let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
        if let staged = await stageData(data, ext: ext, title: "photo." + ext, identity: identity) { items.append(staged) }
        else { failures += 1 }
      }
      emitBatch(items, failures: failures, request: request, epoch: epoch)
    }

    var body: some SwiftUI.View {
      let _ = context.revision
      // Composer owns the attachment cards; this extension only owns picking.
      VStack(spacing: 0) {
        context.content
        Color.clear.frame(width: 1, height: 1).allowsHitTesting(false)
      }
      .fileImporter(isPresented: $filePresented, allowedContentTypes: [.item], allowsMultipleSelection: armedRequest?.staged == true) { result in
        guard let request = armedRequest else { return }
        let epoch = self.epoch
        guard isCurrent(request, epoch: epoch) else { return }
        switch result {
        case .success(let sources):
          if sources.isEmpty { emitDismissed() }
          else {
            handled = true
            importTask?.cancel()
            importTask = Task { await handleFiles(sources, request: request, epoch: epoch) }
          }
        case .failure(let failure):
          selection.release()
          if (failure as NSError).code == NSUserCancelledError { emitDismissed() }
          else if isCurrent(request, epoch: epoch) { emitUnavailable("Unable to access the selected files. Please try again.", request: request) }
        }
      }
      .photosPicker(isPresented: $photosPresented, selection: $photoItems,
                    maxSelectionCount: max(1, armedRequest?.maxSelections ?? 1), selectionBehavior: .ordered, matching: .images)
      .sheet(isPresented: $cameraPresented) {
        #if os(iOS)
        CameraPicker(onImage: { image in
          guard let request = armedRequest, isCurrent(request, epoch: epoch) else { return }
          handled = true
          let epoch = self.epoch
          importTask?.cancel()
          importTask = Task {
            let item: [String: Any]?
            if let data = image.jpegData(compressionQuality: 0.9) {
              item = await stageData(data, ext: "jpg", title: "camera.jpg", identity: "camera:" + UUID().uuidString.lowercased())
            } else { item = nil }
            emitBatch(item.map { [$0] } ?? [], failures: item == nil ? 1 : 0, request: request, epoch: epoch)
          }
        }, onCancel: emitDismissed)
        #else
        EmptyView()
        #endif
      }
      .onChange(of: filePresented) { _, presented in if !presented { emitDismissed() } }
      .onChange(of: photosPresented) { _, presented in if !presented && photoItems.isEmpty { emitDismissed() } }
      .onChange(of: photoItems) { _, items in
        guard !items.isEmpty, let request = armedRequest else { return }
        guard isCurrent(request, epoch: epoch) else { return }
        handled = true
        photoItems = []
        importTask?.cancel()
        let epoch = self.epoch
        importTask = Task { await importPhotos(items, request: request, epoch: epoch) }
      }
      .onChange(of: request?.id, initial: true) { _, id in
        guard let id, id != lastRequest else { return }
        epoch += 1
        importTask?.cancel()
        let wasPresenting = filePresented || photosPresented || cameraPresented
        if id <= 0 || wasPresenting {
          handled = true
          filePresented = false; photosPresented = false; cameraPresented = false
          armedRequest = nil
          lastRequest = id
          return
        }
        guard context.isUserInteractionEnabled, properties?.enabled == true, selection.operation == nil, let request else { return }
        lastRequest = id
        armedRequest = request
        handled = false
        photoItems = []
        switch request.source ?? "files" {
        case "files": filePresented = true
        case "photos": photosPresented = true
        case "camera":
          #if os(iOS)
          if UIImagePickerController.isSourceTypeAvailable(.camera) { cameraPresented = true }
          else { emitUnavailable("The camera is not available on this device.", request: request) }
          #else
          emitUnavailable("Camera capture is not available on this platform.", request: request)
          #endif
        default: emitUnavailable("Unknown attachment source.", request: request)
        }
      }
      .onChange(of: properties?.completion) { _, operation in
        guard let operation, operation == selection.operation else { return }
        selection.release()
        error = properties?.error
      }
      .onDisappear {
        epoch += 1
        importTask?.cancel()
        selection.release()
      }
      .alert("Unable to import file", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
        Button("OK", role: .cancel) { error = nil }
      } message: { Text(error ?? "") }
    }
  }
}
