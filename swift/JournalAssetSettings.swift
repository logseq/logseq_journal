import LUIAppleBackend
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
  struct View: SwiftUI.View {
    let context: LUIAppleExtensionViewContext
    private let preferences = JournalAssetPreferences(defaults: .standard)
    @State private var days = JournalAssetPreferences(defaults: .standard).recentDays
    @State private var deliveredDays: Int?

    private var properties: Properties? {
      JournalExtensions.decode(Properties.self, context: context)
    }

    @discardableResult private func emit(_ value: String) -> Bool {
      JournalExtensions.emit(context: context, payload: Data(value.utf8))
    }
    private func deliver() {
      if deliveredDays != days && emit("days:\(days)") { deliveredDays = days }
    }
    var body: some SwiftUI.View {
      context.content
        .task { deliver() }
        .onChange(of: days) { _, value in
          if preferences.save(recentDays: value) { deliver() }
        }
        .sheet(isPresented: Binding(
          get: { properties?.presented == true },
          set: { if !$0 { emit("dismissed") } })) {
          NavigationStack {
            Form {
              Section("Offline attachments") {
                Stepper("Recent journal days: \(days)", value: $days, in: JournalAssetPreferences.allowedDays)
                VStack(alignment: .leading, spacing: 8) {
                  Text("Recent journals: " + (properties?.recent ?? ""))
                    .font(.footnote).fixedSize(horizontal: false, vertical: true)
                  Text("Favorites: " + (properties?.favorites ?? ""))
                    .font(.footnote).fixedSize(horizontal: false, vertical: true)
                  if let properties, !properties.uploads.isEmpty {
                    Text("Uploads").font(.headline)
                    ForEach(properties.uploads) { upload in
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
}
