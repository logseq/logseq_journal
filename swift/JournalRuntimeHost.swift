import LUIAppleBackend
import OSLog
import SwiftUI

/// Boots one `JournalRuntime` for the given startup payload and renders the
/// lui root with the environment/notice plumbing attached. Shared by the app
/// scene (App.swift) and the apple-tests acceptance harnesses — it replaces
/// `BonsaiApplicationView(entrypoint:payload:nativeViews:applicationBridge:)`.
struct JournalRuntimeHost: View {
  let platform: JournalApplicationPlatform
  let payload: Data
  let extensions: LUIAppleExtensionRegistry
  @State private var runtime: JournalRuntime?

  var body: some SwiftUI.View {
    Group {
      if let runtime, let rootID = runtime.rootID {
        LUISwiftUIRoot(backend: runtime.backend, rootID: rootID)
      } else {
        ProgressView("Opening journal")
      }
    }
    .modifier(JournalNoticePresenter(controller: platform.notices))
    .background(JournalEnvironmentObserver { platform.pushEnvironment($0) })
    .task {
      if runtime == nil {
        do {
          let next = try JournalRuntime(
            platform: platform,
            startupPayload: payload,
            extensionRegistry: extensions)
          next.start()
          runtime = next
        } catch {
          Logger(subsystem: "com.logseq.journal", category: "runtime")
            .error("Unable to start journal runtime: \(error)")
        }
      }
    }
    .onDisappear { runtime?.stop() }
  }
}
