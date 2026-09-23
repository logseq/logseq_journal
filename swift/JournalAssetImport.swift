import LUIAppleBackend
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor enum JournalAssetImport {
  struct Properties: Decodable {
    let enabled: Bool
    let completion: String?
    let error: String?
    let replace: String?
    let request: Int
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

  struct View: SwiftUI.View {
    let context: LUIAppleExtensionViewContext
    @State private var selection = Selection()
    @State private var presented = false
    @State private var handled = false
    @State private var error: String?

    private var properties: Properties? {
      JournalExtensions.decode(Properties.self, context: context)
    }

    private func emitDismissed() {
      guard !handled,
        let data = try? JSONSerialization.data(withJSONObject: ["action": "dismissed"])
      else { return }
      handled = true
      JournalExtensions.emit(context: context, payload: data)
    }

    var body: some SwiftUI.View {
      Button {
        guard context.isUserInteractionEnabled else { return }
        presented = true
      } label: {
        Label(selection.operation == nil ? "Attach file" : "Importing file", systemImage: "paperclip")
          .labelStyle(.iconOnly)
      }
      .disabled(properties?.enabled == false || selection.operation != nil)
      .accessibilityIdentifier("journal-asset-import")
      .fileImporter(isPresented: $presented, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
        guard context.isUserInteractionEnabled else { return }
        do {
          guard let source = try result.get().first else {
            if properties?.replace != nil { emitDismissed() }
            return
          }
          handled = true
          let operation = UUID().uuidString.lowercased()
          selection.retain(source, operation: operation)
          let extensionName = source.pathExtension.lowercased()
          let payload = try JSONSerialization.data(withJSONObject: [
            "operation": operation, "asset": UUID().uuidString.lowercased(),
            "localMutation": UUID().uuidString.lowercased(), "metadataMutation": UUID().uuidString.lowercased(),
            "path": source.path(percentEncoded: false), "title": source.lastPathComponent,
            "replaceReference": properties?.replace ?? NSNull(),
            "type": extensionName.isEmpty ? "bin" : extensionName,
          ] as [String: Any])
          if !JournalExtensions.emit(context: context, payload: payload) {
            selection.release()
            error = "The destination is no longer available. Select the file again."
          }
        } catch {
          selection.release()
          if (error as NSError).code == NSUserCancelledError {
            if properties?.replace != nil { emitDismissed() }
          } else {
            self.error = "Unable to access the selected file. Please try again."
          }
        }
      }
      .onChange(of: presented) { _, isPresented in
        if isPresented {
          handled = false
        } else if properties?.replace != nil {
          // iOS never invokes the fileImporter completion on Cancel, so treat
          // closing an armed picker without a pick as a dismissal.
          emitDismissed()
        }
      }
      .onChange(of: properties?.request) { _, _ in
        if properties?.replace != nil { presented = true }
      }
      .onChange(of: properties?.completion) { _, operation in
        guard let operation, operation == selection.operation else { return }
        selection.release()
        error = properties?.error
      }
      .onDisappear { selection.release() }
      .alert("Unable to import file", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
        Button("OK", role: .cancel) { error = nil }
      } message: { Text(error ?? "") }
    }
  }
}
