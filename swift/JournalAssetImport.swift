import LUIAppleBackend
import Observation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

@MainActor enum JournalAssetImport {
  struct Request: Decodable {
    let id: Int
    let source: String?
    let staged: Bool?
  }

  struct PendingItem: Decodable, Identifiable {
    let token: String
    let path: String
    let title: String
    let type: String?
    var id: String { token }
    var fileType: String { type ?? "bin" }
    var isImage: Bool { JournalMedia.imageTypes.contains(fileType) }
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

  /// One pending-attachment chip: thumbnail (images only) over a file icon,
  /// with a remove affordance that emits the extension's `remove` event.
  private struct PendingCell: SwiftUI.View {
    let item: PendingItem
    let onRemove: () -> Void
    @State private var image: CGImage?
    @State private var decodeFailed = false

    var body: some SwiftUI.View {
      VStack(spacing: 2) {
        Group {
          if let image {
            Image(decorative: image, scale: 1).resizable().scaledToFill()
          } else {
            Image(systemName: item.isImage && !decodeFailed ? "photo" : "doc")
              .font(.title3)
              .foregroundStyle(.secondary)
          }
        }
        .frame(width: 48, height: 48)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        Text(item.title)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .frame(width: 56)
      }
      .overlay(alignment: .topTrailing) {
        Button(action: onRemove) {
          Image(systemName: "xmark.circle.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .padding(2)
        .accessibilityIdentifier("journal-asset-remove:" + item.token)
      }
      .task(id: item.path) {
        guard item.isImage else { return }
        image = nil
        decodeFailed = false
        let decoded = await JournalMediaDecoder.shared.load(item.path)
        guard !Task.isCancelled else { return }
        image = decoded
        decodeFailed = decoded == nil
      }
      .accessibilityIdentifier("journal-asset-pending:" + item.token)
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
    @State private var photoItem: PhotosPickerItem?
    @State private var handled = false
    @State private var lastRequest = 0
    @State private var error: String?

    private var properties: Properties? {
      JournalExtensions.decode(Properties.self, context: context)
    }

    private var request: Request? { properties?.request }

    private func emit(_ object: [String: Any]) -> Bool {
      guard let data = try? JSONSerialization.data(withJSONObject: object)
      else { return false }
      return JournalExtensions.emit(context: context, payload: data)
    }

    private func emitDismissed() {
      guard !handled else { return }
      handled = true
      _ = emit(["action": "dismissed"])
    }

    private func emitUnavailable(_ reason: String) {
      handled = true
      _ = emit([
        "action": "unavailable",
        "reason": reason,
        "request": request?.id ?? 0,
      ])
    }

    private func emitRemove(_ token: String) {
      _ = emit(["action": "remove", "token": token])
    }

    private func emitPick(path: String, title: String, type: String, retained: URL?) {
      handled = true
      let operation = UUID().uuidString.lowercased()
      if let retained { selection.retain(retained, operation: operation) }
      let ok = emit([
        "operation": operation,
        "asset": UUID().uuidString.lowercased(),
        "localMutation": UUID().uuidString.lowercased(),
        "metadataMutation": UUID().uuidString.lowercased(),
        "path": path,
        "title": title,
        "type": type.isEmpty ? "bin" : type,
        "request": [
          "id": request?.id ?? 0,
          "source": request?.source ?? "files",
          "staged": request?.staged ?? false,
        ],
      ] as [String: Any])
      if !ok {
        selection.release()
        error = "The destination is no longer available. Select the file again."
      }
    }

    /// Staged requests copy the pick into a temp file so the path stays valid
    /// after the picker's security scope is released (attach-on-save).
    private func stagedCopy(of url: URL, title: String) -> (path: String, title: String)? {
      let ext = url.pathExtension.lowercased()
      let name =
        "journal-import-" + UUID().uuidString.lowercased()
        + (ext.isEmpty ? "" : "." + ext)
      let dest = FileManager.default.temporaryDirectory.appendingPathComponent(name)
      try? FileManager.default.removeItem(at: dest)
      do {
        try FileManager.default.copyItem(at: url, to: dest)
        return (dest.path(percentEncoded: false), title)
      } catch {
        return nil
      }
    }

    private func stageData(_ data: Data, ext: String, title: String) {
      let dest = FileManager.default.temporaryDirectory
        .appendingPathComponent("journal-import-" + UUID().uuidString.lowercased() + "." + ext)
      do {
        try data.write(to: dest)
        emitPick(path: dest.path(percentEncoded: false), title: title, type: ext, retained: nil)
      } catch {
        self.error = "Unable to save the image. Please try again."
      }
    }

    private func handleFilePick(_ source: URL) {
      let title = source.lastPathComponent
      let type = source.pathExtension.lowercased()
      if request?.staged == true {
        selection.retain(source, operation: UUID().uuidString.lowercased())
        let staged = stagedCopy(of: source, title: title)
        selection.release()
        guard let staged else {
          self.error = "Unable to access the selected file. Please try again."
          return
        }
        emitPick(path: staged.path, title: staged.title, type: type, retained: nil)
      } else {
        emitPick(
          path: source.path(percentEncoded: false), title: title, type: type,
          retained: source)
      }
    }

    private func importPhoto(_ item: PhotosPickerItem) async {
      photoItem = nil
      guard let data = try? await item.loadTransferable(type: Data.self)
      else {
        self.error = "Unable to read the selected photo. Please try again."
        return
      }
      let ext =
        item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
      stageData(data, ext: ext, title: "photo." + ext)
    }

    var body: some SwiftUI.View {
      VStack(spacing: 8) {
        if let pending = properties?.pending, !pending.isEmpty {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
              ForEach(pending) { item in
                PendingCell(item: item) { emitRemove(item.token) }
              }
            }
            .padding(.horizontal, 4)
          }
          .frame(height: 72)
        }
        context.content
      }
      .fileImporter(
        isPresented: $filePresented, allowedContentTypes: [.item],
        allowsMultipleSelection: false
      ) { result in
        guard context.isUserInteractionEnabled else { return }
        do {
          guard let source = try result.get().first else {
            emitDismissed()
            return
          }
          handleFilePick(source)
        } catch {
          selection.release()
          if (error as NSError).code == NSUserCancelledError {
            emitDismissed()
          } else {
            self.error = "Unable to access the selected file. Please try again."
          }
        }
      }
      .photosPicker(
        isPresented: $photosPresented, selection: $photoItem, matching: .images
      )
      .sheet(isPresented: $cameraPresented) {
        #if os(iOS)
        CameraPicker(
          onImage: { image in
            if let data = image.jpegData(compressionQuality: 0.9) {
              stageData(data, ext: "jpg", title: "camera.jpg")
            } else {
              self.error = "Unable to save the image. Please try again."
            }
          },
          onCancel: emitDismissed)
        #else
        EmptyView()
        #endif
      }
      .onChange(of: filePresented) { _, isPresented in
        if isPresented {
          handled = false
        }
      }
      .onChange(of: photosPresented) { _, isPresented in
        if isPresented { handled = false }
      }
      .onChange(of: photoItem) { _, item in
        guard let item else { return }
        Task { await importPhoto(item) }
      }
      .onChange(of: request?.id) { _, id in
        guard let id, id != lastRequest, context.isUserInteractionEnabled,
          properties?.enabled == true, selection.operation == nil
        else { return }
        lastRequest = id
        handled = false
        switch request?.source ?? "files" {
        case "files":
          filePresented = true
        case "photos":
          photosPresented = true
        case "camera":
          #if os(iOS)
          if UIImagePickerController.isSourceTypeAvailable(.camera) {
            cameraPresented = true
          } else {
            emitUnavailable("The camera is not available on this device.")
          }
          #else
          emitUnavailable("Camera capture is not available on this platform.")
          #endif
        default:
          emitUnavailable("Unknown attachment source.")
        }
      }
      .onChange(of: properties?.completion) { _, operation in
        guard let operation, operation == selection.operation else { return }
        selection.release()
        error = properties?.error
      }
      .onDisappear { selection.release() }
      .alert(
        "Unable to import file",
        isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
      ) {
        Button("OK", role: .cancel) { error = nil }
      } message: { Text(error ?? "") }
    }
  }
}
