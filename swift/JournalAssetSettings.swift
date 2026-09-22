import BonsaiSwiftUI
import SwiftUI

@MainActor enum JournalAssetSettings {
  struct Upload: Decodable, Identifiable {
    let id: String
    let title: String
    let message: String
    let busy: Bool
    let retry: Bool
  }
  struct Properties: Decodable {
    let presented: Bool
    let recent: String
    let favorites: String
    let uploads: [Upload]
  }
  private struct SettingsHost: View {
    let context: BonsaiNativeContext<Properties, Data, Void>
    private let preferences = JournalAssetPreferences(defaults: .standard)
    @State private var days = JournalAssetPreferences(defaults: .standard).recentDays
    @State private var deliveredDays: Int?

    @discardableResult private func emit(_ value: String) -> Bool {
      guard context.canInteract() else { return false }
      return context.emit(Data(value.utf8))
    }
    private func deliver() {
      if deliveredDays != days && emit("days:\(days)") { deliveredDays = days }
    }
    var body: some View {
      context.children[0]
        .task(id: context.isPresented) { if context.isPresented { deliver() } }
        .onChange(of: days) { _, value in
          if preferences.save(recentDays: value) { deliver() }
        }
        .sheet(isPresented: Binding(
          get: { context.properties.presented },
          set: { if !$0 { emit("dismissed") } })) {
          NavigationStack {
            Form {
              Section("Offline attachments") {
                Stepper("Recent journal days: \(days)", value: $days, in: JournalAssetPreferences.allowedDays)
                VStack(alignment: .leading, spacing: 8) {
                  Text("Recent journals: " + context.properties.recent)
                    .font(.footnote).fixedSize(horizontal: false, vertical: true)
                  Text("Favorites: " + context.properties.favorites)
                    .font(.footnote).fixedSize(horizontal: false, vertical: true)
                  if !context.properties.uploads.isEmpty {
                    Text("Uploads").font(.headline)
                    ForEach(context.properties.uploads) { upload in
                      HStack(alignment: .top, spacing: 12) {
                        if upload.busy { ProgressView().controlSize(.small).accessibilityLabel(upload.message) }
                        VStack(alignment: .leading, spacing: 4) {
                          Text(upload.title).font(.body).lineLimit(2)
                          Text(upload.message).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        if upload.retry {
                          Button("Retry") { emit("retry:" + upload.id) }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Retry upload: " + upload.title)
                            .accessibilityIdentifier("journal-upload-retry:" + upload.id)
                        }
                      }
                      .accessibilityIdentifier("journal-upload:" + upload.id)
                    }
                  }
                  Text("Downloads attachments from today and the preceding days. Set to 0 to disable recent-journal downloads.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                  Text("Favorites include their complete subtrees, regardless of this setting.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
              }
            }
            .formStyle(.grouped)
            .navigationTitle("Attachment settings")
            .toolbar {
              ToolbarItem(placement: .confirmationAction) {
                Button("Done") { emit("dismissed") }
              }
            }
          }
          .presentationSizing(.form)
          .presentationDetents([.medium, .large])
          .frame(minWidth: 360, idealWidth: 440, minHeight: 280)
        }
    }
  }
  static func register(in registry: inout BonsaiNativeViews) throws {
    try registry.register(kind: 2106, version: 1, capabilities: [.stateful, .semantics],
      decode: { try JSONDecoder().decode(Properties.self, from: $0) },
      validateChildren: { properties, count in
        guard count == 1, properties.uploads.count <= 32 else { throw BonsaiNativeViewError.invalidRegistration }
      }, encodeEvent: { (data: Data) in BonsaiNativeEvent(id: 1, payload: data) },
      makeResource: { () }, dispose: { _ in }, content: { context in SettingsHost(context: context) })
  }
}
