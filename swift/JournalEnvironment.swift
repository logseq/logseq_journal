import SwiftUI

/// Product preferences pushed to OCaml as an LJP2 tag-24 event, matching
/// `Journal_environment.decode_json`. Native layout and accessibility behavior
/// remain owned by SwiftUI and the native controls.
struct JournalEnvironmentSample: Equatable {
  var brightness = "light"
  var platform = "ios"
  var accessibleNavigation = false
  var highContrast = false

  func jsonObject() -> [String: Any] {
    [
      "brightness": brightness,
      "platform": platform,
      "accessibleNavigation": accessibleNavigation,
      "highContrast": highContrast,
    ]
  }
}

/// Observes product preferences at the application boundary. The platform
/// deduplicates samples and pushes them through `journal_ocaml_platform_event`.
struct JournalEnvironmentObserver: View {
  let onSample: (JournalEnvironmentSample) -> Void
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
  @Environment(\.colorSchemeContrast) private var contrast

  private var sample: JournalEnvironmentSample {
    #if os(macOS)
      let platform = "macos"
    #else
      let platform = "ios"
    #endif
    return JournalEnvironmentSample(
      brightness: colorScheme == .dark ? "dark" : "light", platform: platform,
      accessibleNavigation: voiceOver, highContrast: contrast == .increased)
  }

  var body: some View {
    let value = sample
    Color.clear
      .onAppear { onSample(value) }
      .onChange(of: value) { _, value in onSample(value) }
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}
