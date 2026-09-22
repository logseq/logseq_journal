import BonsaiSwiftUI
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

  private struct ImportButton: View {
    let context: BonsaiNativeContext<Properties, Data, Selection>
    @State private var presented = false
    @State private var handled = false
    @State private var error: String?

    private func emitDismissed() {
      guard !handled,
        let data = try? JSONSerialization.data(withJSONObject: ["action": "dismissed"])
      else { return }
      handled = true
      _ = context.emit(data)
    }

    var body: some View {
      Button {
        guard context.canInteract() else { return }
        presented = true
      } label: {
        Label(context.resource.operation == nil ? "Attach file" : "Importing file", systemImage: "paperclip")
      }
      .disabled(!context.properties.enabled || !context.isPresented || context.resource.operation != nil)
      .accessibilityIdentifier("journal-asset-import")
      .fileImporter(isPresented: $presented, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
        guard context.canInteract() else { return }
        do {
          guard let source = try result.get().first else {
            if context.properties.replace != nil { emitDismissed() }
            return
          }
          handled = true
          let operation = UUID().uuidString.lowercased()
          context.resource.retain(source, operation: operation)
          let extensionName = source.pathExtension.lowercased()
          let payload = try JSONSerialization.data(withJSONObject: [
            "operation": operation, "asset": UUID().uuidString.lowercased(),
            "localMutation": UUID().uuidString.lowercased(), "metadataMutation": UUID().uuidString.lowercased(),
            "path": source.path(percentEncoded: false), "title": source.lastPathComponent,
            "replaceReference": context.properties.replace ?? NSNull(),
            "type": extensionName.isEmpty ? "bin" : extensionName,
          ] as [String: Any])
          if !context.emit(payload) {
            context.resource.release()
            error = "The destination is no longer available. Select the file again."
          }
        } catch {
          context.resource.release()
          if (error as NSError).code == NSUserCancelledError {
            if context.properties.replace != nil { emitDismissed() }
          } else {
            self.error = "Unable to access the selected file. Please try again."
          }
        }
      }
      .onChange(of: presented) { _, isPresented in
        if isPresented {
          handled = false
        } else if context.properties.replace != nil {
          // iOS never invokes the fileImporter completion on Cancel, so treat
          // closing an armed picker without a pick as a dismissal.
          emitDismissed()
        }
      }
      .onChange(of: context.properties.request) { _, _ in
        if context.properties.replace != nil { presented = true }
      }
      .onChange(of: context.properties.completion) { _, operation in
        guard let operation, operation == context.resource.operation else { return }
        context.resource.release()
        error = context.properties.error
      }
      .alert("Unable to import file", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
        Button("OK", role: .cancel) { error = nil }
      } message: { Text(error ?? "") }
    }
  }

  static func register(in registry: inout BonsaiNativeViews) throws {
    try registry.register(kind: 2104, version: 1, capabilities: [.stateful, .resource, .semantics],
      decode: { try JSONDecoder().decode(Properties.self, from: $0) },
      validateChildren: { _, count in
        guard count == 0 else { throw BonsaiNativeViewError.invalidRegistration }
      },
      encodeEvent: { (data: Data) in BonsaiNativeEvent(id: 1, payload: data) },
      makeResource: { Selection() }, dispose: { $0.release() },
      content: { context in ImportButton(context: context) })
  }
}
