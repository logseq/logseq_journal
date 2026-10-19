import LUIAppleBackend
import OSLog
import SwiftUI
import Observation
#if os(macOS)
import AppKit
#endif

/// Boots one `JournalRuntime` for the given startup payload and renders the
/// lui root with the environment plumbing attached. Shared by the app
/// scene (App.swift) and the apple-tests acceptance harnesses — it replaces
/// `BonsaiApplicationView(entrypoint:payload:nativeViews:applicationBridge:)`.
struct JournalRuntimeHost: View {
  let platform: JournalApplicationPlatform
  let payload: Data
  let extensions: LUIAppleExtensionRegistry
  @State private var runtime: JournalRuntime?
  @State private var fallbackClock = JournalStartupClock()
  @Environment(\.journalStartupClock) private var inheritedClock
  @State private var failure: Error?
  @State private var retry = 0
  private var clock: JournalStartupClock { inheritedClock ?? fallbackClock }

  private var content: some SwiftUI.View {
    Group {
      if failure != nil || runtime?.failure != nil {
        ContentUnavailableView {
          Label("Unable to open journal", systemImage: "exclamationmark.folder")
        } description: {
          Text(runtime?.failure?.errorDescription ??
            (failure as? JournalRuntime.Failure)?.errorDescription ??
            "Journal could not start (runtime.start.failed). Retry opening Journal.")
        } actions: {
          Button("Retry") { runtime?.stop(); runtime = nil; failure = nil; clock.restart(); retry += 1 }
            .accessibilityIdentifier("journal-runtime-retry")
        }
      } else if let runtime, let rootID = runtime.rootID {
        LUISwiftUIRoot(backend: runtime.backend, rootID: rootID)
      } else {
        JournalStartupLoadingSurface(loading: false, initial: true, active: true)
      }
    }
  }

  var body: some SwiftUI.View {
    Group {
      #if os(iOS)
      // Capture the container inset before the descendant NavigationStack
      // adds its navigation bar; floating pages retain their original layout.
      GeometryReader { container in
        content
          .environment(\.journalContainerTopInset, container.safeAreaInsets.top)
          .environment(\.journalStartupContainerFrame, container.frame(in: .global))
      }
      #else
      content
      #endif
    }
    .environment(\.journalStartupClock, clock)
    .background(JournalEnvironmentObserver { platform.pushEnvironment($0) })
    .task(id: retry) {
      if runtime == nil {
        do {
          let next = try JournalRuntime(
            platform: platform,
            startupPayload: payload,
            extensionRegistry: extensions)
          try next.start()
          runtime = next
        } catch {
          failure = error
          Logger(subsystem: "com.logseq.journal", category: "runtime")
            .error("Unable to start journal runtime (runtime.start.failed)")
        }
      }
    }
    .onDisappear { runtime?.stop() }
  }
}

@Observable @MainActor final class JournalStartupClock {
  private(set) var expired = false
  @ObservationIgnored private var started: TimeInterval?
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var revision = 0
  var elapsed: Bool {
    expired || started.map { ProcessInfo.processInfo.systemUptime - $0 >= 0.1 } == true
  }
  func begin() {
    guard started == nil else { return }
    started = ProcessInfo.processInfo.systemUptime
    let version = revision
    task = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(100)) }
      catch { return }
      guard let self, !Task.isCancelled, version == revision else { return }
      expired = true
    }
  }
  func restart() {
    revision += 1; task?.cancel(); task = nil; started = nil; expired = false
  }
}

private struct JournalStartupClockKey: EnvironmentKey {
  static let defaultValue: JournalStartupClock? = nil
}
extension EnvironmentValues {
  var journalStartupClock: JournalStartupClock? {
    get { self[JournalStartupClockKey.self] }
    set { self[JournalStartupClockKey.self] = newValue }
  }
}

struct JournalStartupLoadingSurface: View {
  let loading: Bool
  let initial: Bool
  let active: Bool
  var value: Double? = nil
  var message = ""
  var action = AnyView(EmptyView())
  @Environment(\.journalStartupClock) private var clock
  private var visible: Bool { active && (loading || (initial && clock?.elapsed == true)) }
  var body: some View {
    VStack(spacing: 12) {
      Group {
        if let value { ProgressView(value: value).frame(width: 160) }
        else { ProgressView() }
      }.frame(height: 24).accessibilityIdentifier("journal-startup-loading")
      Text("Loading journal")
      Text(message).font(.footnote).foregroundStyle(.secondary).frame(height: 20)
    }
    .opacity(visible ? 1 : 0)
    .accessibilityHidden(!visible)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    // Recovery actions do not change the centered waiting canvas.
    .overlay(alignment: .bottom) { action }
    .padding(24)
    .background(.background)
    .accessibilityIdentifier("journal-startup-waiting")
    .onAppear { clock?.begin() }
  }
}

struct JournalRuntimeSetup {
  let payload: Data
  let extensions: LUIAppleExtensionRegistry
}

/// Production account entry points with injectable native capabilities for QA.
struct JournalHost: View {
  let platform: JournalApplicationPlatform
  let prepare: @MainActor () async throws -> JournalRuntimeSetup
  let authentication: any JournalAuthenticationAPI
  @Environment(\.scenePhase) private var scenePhase
  @State private var setup: Result<JournalRuntimeSetup, Error>?
  @State private var retry = 0
  @State private var signInPresented = false
  @State private var clock = JournalStartupClock()

  var body: some View {
    Group {
      switch setup {
      case .none:
        JournalStartupLoadingSurface(loading: false, initial: true, active: scenePhase != .background)
      case .failure:
        ContentUnavailableView {
          Label("Unable to open local application storage", systemImage: "exclamationmark.folder")
        } description: {
          Text("Local storage setup could not finish (storage.setup.failed). Check available storage and retry.")
        } actions: {
          Button("Retry") { setup = nil; clock.restart(); retry += 1 }
            .accessibilityIdentifier("journal-storage-retry")
        }
      case .success(let setup):
        JournalRuntimeHost(platform: platform, payload: setup.payload, extensions: setup.extensions)
          .font(.body)
          .safeAreaInset(edge: .top, spacing: 0) {
            if platform.authenticationRequired || platform.accountIssue != nil {
              JournalAccountRecoveryView(issue: platform.accountIssue,
                signInAvailable: platform.authenticationRequired || platform.accountIssue?.offersSignIn == true,
                signIn: { signInPresented = true }, retry: { platform.refreshAuthentication() })
            }
          }
      }
    }
    .environment(\.journalStartupClock, clock)
    .task(id: retry) {
      guard setup == nil else { return }
      do { setup = .success(try await prepare()) }
      catch { if !Task.isCancelled { setup = .failure(error) } }
    }
    .onChange(of: scenePhase, initial: true) { _, phase in
      if phase == .background { lifecycle(backgrounded: true) }
      else if phase == .active { lifecycle(backgrounded: false) }
    }
    .onChange(of: platform.authenticationRequired) { _, required in
      if required && platform.localAccountAvailable == false { signInPresented = true }
      // The authentication owner closes its sheet after account preparation.
      // Closing on the intermediate native identity update can cancel that work.
    }
    .onChange(of: platform.localAccountAvailable) { _, available in
      if available == false && platform.authenticationRequired { signInPresented = true }
    }
    .sheet(isPresented: $signInPresented) {
      NavigationStack {
        JournalAuthenticationView(api: JournalPreparedAuthentication(api: authentication,
          prepare: { try await platform.prepareAccount() },
          cancelPreparation: { platform.cancelAccountPreparation() },
          preparationMessage: {
            platform.accountIssue.map { ($0.errorDescription ?? "") + "\n" + $0.diagnostic }
          })) {
          signInPresented = false
        }
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            JournalSheetDismissButton { signInPresented = false }
              .accessibilityIdentifier("authentication-close")
          }
        }
      }
      .onAppear { platform.setAccountAuthenticationPresented(true) }
      .onDisappear { platform.setAccountAuthenticationPresented(false) }
      .presentationSizing(.form).presentationDetents([.large]).frame(idealWidth: 480)
      #if os(macOS)
      .frame(minWidth: 320, minHeight: 360)
      #endif
    }
    #if os(macOS)
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didHideNotification)) { _ in lifecycle(backgrounded: true) }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in lifecycle(backgrounded: false) }
    #endif
  }
  private func lifecycle(backgrounded: Bool) {
    do { try platform.setBackgrounded(backgrounded) }
    catch { Logger(subsystem: "com.logseq.journal", category: "lifecycle").error("Unable to enqueue lifecycle event") }
  }
}
