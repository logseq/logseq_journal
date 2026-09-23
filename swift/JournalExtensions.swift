import Foundation
import SwiftUI
import LUIAppleBackend

/// Reproduces `Lui_extension.fingerprint` in OCaml (src/lui_extension.ml):
/// the backend rejects `create-extension` ops whose fingerprint does not
/// match the registered schema byte-for-byte.
enum JournalExtensionFingerprint {
  struct Property {
    let name: String
    let kind: String
    let required: Bool
    let defaultValue: String?
  }
  struct Event {
    let name: String
    let fields: [(name: String, kind: String, required: Bool)]
  }

  static func make(
    identifier: String,
    profiles: [String],
    standardChildren: Bool,
    children: [String],
    properties: [Property],
    events: [Event]
  ) -> String {
    func token(_ value: String) -> String {
      "\(value.utf8.count):\(value)"
    }
    func propertyToken(_ property: Property) -> String {
      let fallback = property.defaultValue.map { "some:s\(token($0))" } ?? "none"
      return token(property.name) + ":" + property.kind + ":"
        + (property.required ? "required" : "optional") + ":" + fallback
    }
    func eventToken(_ event: Event) -> String {
      let fields = event.fields
        .map { token($0.name) + ":" + $0.kind + ":"
               + ($0.required ? "required" : "optional") }
        .sorted()
        .joined(separator: ",")
      return token(event.name) + "[" + fields + "]"
    }
    return "lui-extension-v1|" + token(identifier)
      + "|profiles:" + profiles.sorted().joined(separator: ",")
      + "|standard-children:" + (standardChildren ? "1" : "0")
      + "|children:" + children.map(token).sorted().joined(separator: ",")
      + "|properties:" + properties.map(propertyToken).sorted().joined(separator: ",")
      + "|events:" + events.map(eventToken).sorted().joined(separator: ",")
  }
}

@MainActor enum JournalExtensions {
  private static let appleProfiles = ["macos/swiftui", "ios/swiftui"]
  private static let allHostProfiles =
    appleProfiles + ["macos/flutter", "ios/flutter", "android/flutter"]
  private static let payloadProperty =
    JournalExtensionFingerprint.Property(
      name: "payload", kind: "string", required: true, defaultValue: nil)
  private static let event =
    JournalExtensionFingerprint.Event(
      name: "event",
      fields: [(name: "id", kind: "int", required: true),
               (name: "payload", kind: "string", required: true)])

  private static func fingerprint(
    identifier: String, profiles: [String], standardChildren: Bool, events: Bool
  ) -> String {
    JournalExtensionFingerprint.make(
      identifier: identifier, profiles: profiles,
      standardChildren: standardChildren, children: [],
      properties: [payloadProperty],
      events: events ? [event] : [])
  }

  private static let eventSchema = LUIExtensionEvent(
    name: "event",
    fields: [
      .init(name: "id", kind: .int, isRequired: true),
      .init(name: "payload", kind: .string, isRequired: true),
    ])

  /// Decodes the required `payload` string property into the same Codable
  /// `Properties` structs the bonsai native views decoded.
  static func decode<Properties: Decodable>(
    _ type: Properties.Type, context: LUIAppleExtensionViewContext
  ) -> Properties? {
    guard case let .string(json) = context.property("payload"),
      let value = try? JSONDecoder().decode(type, from: Data(json.utf8))
    else { return nil }
    return value
  }

  /// Forwards one journal event on the `"event"` schema, matching the old
  /// `BonsaiNativeEvent(id, payload)` contract. Returns delivery success.
  @discardableResult
  static func emit(
    context: LUIAppleExtensionViewContext, id: Int = 1, payload: Data
  ) -> Bool {
    guard context.isUserInteractionEnabled else { return false }
    return (try? context.emit(
      name: "event",
      values: [
        "id": .int(id),
        "payload": .string(String(decoding: payload, as: UTF8.self)),
      ])) != nil
  }

  private static func journalExtension(
    identifier: String, profiles: [String], standardChildren: Bool, events: Bool,
    viewFactory: @escaping LUIAppleExtension.ViewFactory
  ) -> LUIAppleExtension {
    LUIAppleExtension(
      identifier: identifier,
      fingerprint: fingerprint(
        identifier: identifier, profiles: profiles,
        standardChildren: standardChildren, events: events),
      acceptsStandardChildren: standardChildren,
      properties: [.init(name: "payload", kind: .string, isRequired: true)],
      events: events ? [eventSchema] : [],
      viewFactory: viewFactory)
  }

  static func chromeExtension() -> LUIAppleExtension {
    journalExtension(identifier: "journal-chrome", profiles: appleProfiles,
      standardChildren: true, events: false) { context in
      AnyView(JournalChrome.View(context: context))
    }
  }

  static func assetImportExtension() -> LUIAppleExtension {
    journalExtension(identifier: "journal-asset-import", profiles: allHostProfiles,
      standardChildren: false, events: true) { context in
      AnyView(JournalAssetImport.View(context: context))
    }
  }

  static func mediaExtension() -> LUIAppleExtension {
    journalExtension(identifier: "journal-media", profiles: allHostProfiles,
      standardChildren: false, events: true) { context in
      AnyView(JournalMedia.View(context: context))
    }
  }

  static func assetSettingsExtension() -> LUIAppleExtension {
    journalExtension(identifier: "journal-asset-settings", profiles: allHostProfiles,
      standardChildren: true, events: true) { context in
      AnyView(JournalAssetSettings.View(context: context))
    }
  }

  static func listExtension() -> LUIAppleExtension {
    journalExtension(identifier: "journal-list", profiles: allHostProfiles,
      standardChildren: false, events: true) { context in
      AnyView(JournalList.View(context: context))
    }
  }

  static func registry() throws -> LUIAppleExtensionRegistry {
    let registry = LUIAppleExtensionRegistry()
    for journalExtension in [
      chromeExtension(),
      assetImportExtension(),
      mediaExtension(),
      assetSettingsExtension(),
      listExtension(),
    ] {
      try registry.register(journalExtension)
    }
    return registry
  }
}
