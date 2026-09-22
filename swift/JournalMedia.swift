import BonsaiSwiftUI
import ImageIO
import QuickLook
import SwiftUI

private actor JournalMediaDecoder {
  static let shared = JournalMediaDecoder()
  private let cache = NSCache<NSString, CGImage>()
  init() { cache.totalCostLimit = 32 * 1024 * 1024; cache.countLimit = 32 }
  func clear() { cache.removeAllObjects() }
  func load(_ path: String) -> CGImage? {
    guard !Task.isCancelled else { return nil }
    if let image = cache.object(forKey: path as NSString) { return image }
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL,
      [kCGImageSourceShouldCache: false] as CFDictionary),
      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: 1024,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
      ] as CFDictionary), !Task.isCancelled else { return nil }
    cache.setObject(image, forKey: path as NSString, cost: image.bytesPerRow * image.height)
    return image
  }
}

@MainActor enum JournalMedia {
  struct Item: Decodable, Identifiable {
    let id: String
    let kind: String
    let value: String
    let type: String
    let width: Int
    let height: Int
    var isImage: Bool { ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "avif"].contains(type) }
  }
  struct Picker: Decodable {
    let items: [Item]
    let more: Bool
    let busy: Bool
  }
  struct Properties: Decodable {
    let root: String
    let items: [Item]
    let more: Bool
    let editable: Bool
    let picker: Picker?
    let error: String?
  }
  private struct MediaItem: View {
    let item: Item
    let emit: (String, String, Bool) -> Void
    @State private var image: CGImage?
    @State private var preview: URL?
    @State private var decodeFailed = false
    @ViewBuilder private var content: some View {
      Group {
        if item.kind == "file" && item.isImage {
          Group {
            if let image {
              Image(decorative: image, scale: 1).resizable().scaledToFit()
            } else if decodeFailed {
              Button("Open image") { preview = URL(fileURLWithPath: item.value) }
            } else { ProgressView("Opening image") }
          }
          .contentShape(Rectangle())
          .onTapGesture { preview = URL(fileURLWithPath: item.value) }
          .task(id: item.value) {
            image = nil; decodeFailed = false
            let decoded = await JournalMediaDecoder.shared.load(item.value)
            guard !Task.isCancelled else { return }
            image = decoded; decodeFailed = decoded == nil
          }
        } else if item.kind == "file" {
          Button { preview = URL(fileURLWithPath: item.value) } label: { Label("Open attachment", systemImage: "doc") }
        } else if item.kind == "external", let url = URL(string: item.value), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
          Link(destination: url) { Label("Open external attachment", systemImage: "arrow.up.right.square") }
        } else {
          VStack(spacing: 8) {
            Label(item.value, systemImage: "photo")
              .font(.caption).foregroundStyle(.secondary)
            Button("Retry") { emit("retry", item.id, true) }.font(.caption)
          }
          .frame(maxWidth: .infinity)
          .frame(maxHeight: .infinity)
          .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
      }
    }
    var body: some View {
      Group {
        if item.isImage {
          Color.clear
            .aspectRatio(CGFloat(max(item.width, 1)) / CGFloat(max(item.height, 1)), contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: 240)
            .overlay { content }
        } else { content.frame(minHeight: 48) }
      }
      .quickLookPreview($preview)
      .onDisappear { image = nil }
      .accessibilityIdentifier("journal-media:" + item.id)
    }
  }
  private struct MediaGroup: View {
    let context: BonsaiNativeContext<Properties, Data, Void>
    private func emit(_ action: String, _ asset: String = "", _ visible: Bool = true) {
      guard context.canInteract(), let data = try? JSONSerialization.data(withJSONObject: [
        "action": action, "root": context.properties.root, "asset": asset, "visible": visible,
      ]) else { return }
      _ = context.emit(data)
    }
    var body: some View {
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .top) {
          context.children[0]
          Spacer(minLength: 8)
          if context.properties.editable {
            Menu {
              Button("Replace file\u{2026}") { emit("replace") }
              Button("Reuse existing\u{2026}") { emit("reuse") }
            } label: {
              Label("Attachment actions", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
            }
            .menuIndicator(.hidden)
            .accessibilityIdentifier("journal-media-actions")
          }
        }
        ForEach(context.properties.items) { item in MediaItem(item: item, emit: emit) }
        if let picker = context.properties.picker {
          if picker.busy, picker.items.isEmpty {
            ProgressView("Loading attachments").font(.caption)
          }
          ForEach(picker.items) { item in
            Button { emit("reuse-select", item.id) } label: {
              Label(item.type.isEmpty ? "file" : item.type, systemImage: "doc")
            }
            .disabled(picker.busy)
            .accessibilityIdentifier("journal-media-candidate:" + item.id)
          }
          if picker.more {
            Button("More attachments") { emit("reuse-next") }
              .disabled(picker.busy)
          }
          Button("Cancel", role: .cancel) { emit("reuse-cancel") }
            .font(.caption)
        }
        if let error = context.properties.error {
          Text(error).font(.caption).foregroundStyle(.secondary)
          Button("Retry attachments") { emit("retry") }
        }
        if context.properties.more { Button("Next attachments") { emit("next") } }
      }
      .buttonStyle(.borderless)
      .onDisappear { Task { await JournalMediaDecoder.shared.clear() } }
    }
  }
  static func register(in registry: inout BonsaiNativeViews) throws {
    try registry.register(kind: 2105, version: 1, capabilities: [.stateful, .semantics],
      decode: { try JSONDecoder().decode(Properties.self, from: $0) },
      validateChildren: { properties, count in
        guard count == 1, properties.items.count <= 32 else { throw BonsaiNativeViewError.invalidRegistration }
      }, encodeEvent: { (data: Data) in BonsaiNativeEvent(id: 1, payload: data) },
      makeResource: { () }, dispose: { _ in }, content: { context in MediaGroup(context: context) })
  }
}
