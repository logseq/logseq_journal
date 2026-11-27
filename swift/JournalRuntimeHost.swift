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
  let prestarted: JournalRuntime?
  @State private var lifetime = JournalRuntimeLifetime()

  init(
    platform: JournalApplicationPlatform,
    payload: Data,
    extensions: LUIAppleExtensionRegistry,
    prestarted: JournalRuntime? = nil
  ) {
    self.platform = platform
    self.payload = payload
    self.extensions = extensions
    self.prestarted = prestarted
  }
  private var runtime: JournalRuntime? {
    get { lifetime.runtime }
    nonmutating set { lifetime.runtime = newValue }
  }
  private var startingRuntime: JournalRuntime? {
    get { lifetime.startingRuntime }
    nonmutating set { lifetime.startingRuntime = newValue }
  }
  @State private var graphScrollOffsets = JournalGraphScrollOffsets()
  @State private var failure: Error?
  @State private var startupRevision = 0

  private var displayRuntime: JournalRuntime? {
    #if os(iOS)
    runtime ?? (platform.startupClock.phase != .waitingBeforeDeadline ? startingRuntime : nil)
    #else
    runtime
    #endif
  }

  private var content: some SwiftUI.View {
    Group {
      if failure != nil || runtime?.failure != nil {
        ContentUnavailableView {
          Label("Unable to open journal", systemImage: "exclamationmark.folder")
        } description: {
          Text(runtime?.failureDescription ?? failure.map { JournalRuntime.safeDescription($0,operation:"runtime.start.failed") } ??
            "Journal could not start (runtime.start.failed).")
        }
      } else if let runtime = displayRuntime, let rootID = runtime.rootID {
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
          .environment(\.journalContainerBottomInset, container.safeAreaInsets.bottom)
          .environment(\.journalStartupContainerFrame, container.frame(in: .global))
      }
      #else
      content
      #endif
    }
    .environment(\.journalStartupClock, platform.startupClock)
    .environment(\.journalGraphScrollOffsets, graphScrollOffsets)
    .background(JournalEnvironmentObserver { platform.pushEnvironment($0) })
    .task(id: startupRevision) {
      if runtime == nil && startingRuntime == nil {
        let startupLogger = Logger(subsystem: "com.logseq.journal", category: "startup")
        let t0 = ProcessInfo.processInfo.systemUptime
        do {
          let next: JournalRuntime
          let alreadyStarted: Bool
          if startupRevision == 0, let prestarted, prestarted.failure == nil {
            next = prestarted
            alreadyStarted = true
          } else {
            next = try JournalRuntime(
              platform: platform,
              startupPayload: payload,
              extensionRegistry: extensions)
            alreadyStarted = false
          }
          let t1 = ProcessInfo.processInfo.systemUptime
          startupLogger.info("journal-startup stage=host.runtime.created elapsed_ms=\(Int(((t1 - t0) * 1000).rounded()), privacy: .public) since_start_ms=\(Int(((t1 - t0) * 1000).rounded()), privacy: .public) prestarted=\(alreadyStarted, privacy: .public)")
          startingRuntime = next
          do {
            if !alreadyStarted {
              try next.start()
            }
            let t2 = ProcessInfo.processInfo.systemUptime
            startupLogger.info("journal-startup stage=host.runtime.started elapsed_ms=\(Int(((t2 - t1) * 1000).rounded()), privacy: .public) since_start_ms=\(Int(((t2 - t0) * 1000).rounded()), privacy: .public)")
            try await next.waitForInitialPlatformRequests()
            let t3 = ProcessInfo.processInfo.systemUptime
            startupLogger.info("journal-startup stage=host.initial_platform_requests.done elapsed_ms=\(Int(((t3 - t2) * 1000).rounded()), privacy: .public) since_start_ms=\(Int(((t3 - t0) * 1000).rounded()), privacy: .public)")
            try await next.waitForStartupContent()
            try Task.checkCancellation()
            guard startingRuntime === next else { throw CancellationError() }
            runtime = next
            startingRuntime = nil
            let t4 = ProcessInfo.processInfo.systemUptime
            startupLogger.info("journal-startup stage=host.root.mounted elapsed_ms=\(Int(((t4 - t3) * 1000).rounded()), privacy: .public) since_start_ms=\(Int(((t4 - t0) * 1000).rounded()), privacy: .public)")
          } catch {
            if next.stop() {
              if startingRuntime === next {
                startingRuntime = nil
                if Task.isCancelled {
                  if let stoppedFailure = next.failure { failure = stoppedFailure }
                  else { startupRevision += 1 }
                }
              }
            } else if startingRuntime === next {
              failure = next.failure
            }
            throw error
          }
        } catch is CancellationError {
          // Cancellation retires only its own startup; a visible host retries.
        } catch {
          failure = error
          Logger(subsystem: "com.logseq.journal", category: "runtime")
            .error("Unable to start journal runtime (runtime.start.failed)")
        }
      }
    }
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
  var action: AnyView? = nil
  @Environment(\.journalStartupClock) private var clock
  private var visible: Bool {
    #if os(iOS)
    active && (initial && clock?.phase != .finished ? clock?.phase == .slow : loading)
    #else
    active && (loading || (initial && clock?.phase == .slow))
    #endif
  }
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
    .overlay(alignment: .bottom) {
      #if os(iOS)
      if active && initial && clock?.phase == .pickerRequested {
        Text("Opening graph picker…")
      } else if !initial || visible {
        if let action { action }
        else if initial, let clock {
          Button("Choose other graph") { clock.requestPicker() }
            .buttonStyle(.bordered).accessibilityIdentifier("graph-picker-choose")
        }
      }
      #else
      action
      #endif
    }
    .padding(24)
    .background(.background)
    .accessibilityIdentifier("journal-startup-waiting")
    .onAppear {
      #if os(macOS)
      clock?.begin(after: .milliseconds(100))
      #else
      clock?.begin()
      #endif
    }
  }
}

struct JournalRuntimeSetup {
  let payload: Data
  let extensions: LUIAppleExtensionRegistry
  var prestartedRuntime: JournalRuntime? = nil
}

/// Production account entry points with injectable native capabilities for QA.
struct JournalHost: View {
  let platform: JournalApplicationPlatform
  let prepare: @MainActor () async throws -> JournalRuntimeSetup
  let authentication: any JournalAuthenticationAPI
  @Environment(\.scenePhase) private var scenePhase
  @State private var setup: Result<JournalRuntimeSetup, Error>?
  @State private var signInPresented = false
  @State private var signInStartsImmediately = false

  init(
    platform: JournalApplicationPlatform,
    prepare: @escaping @MainActor () async throws -> JournalRuntimeSetup,
    authentication: any JournalAuthenticationAPI,
    initialSetup: Result<JournalRuntimeSetup, Error>? = nil
  ) {
    self.platform = platform
    self.prepare = prepare
    self.authentication = authentication
    _setup = State(initialValue: initialSetup)
  }

  var body: some View {
    Group {
      switch setup {
      case .none:
        JournalStartupLoadingSurface(loading: false, initial: true, active: scenePhase != .background)
      case .failure(let error):
        ContentUnavailableView {
          Label("Unable to open local application storage", systemImage: "exclamationmark.folder")
        } description: {
          Text(JournalRuntime.safeDescription(error,operation:"storage.setup.failed"))
        }
      case .success(let setup):
        VStack(spacing: 0) {
          if platform.authenticationRequired || platform.accountIssue != nil {
            JournalAccountRecoveryView(issue: platform.accountIssue,
              signInAvailable: platform.authenticationRequired || platform.accountIssue?.offersSignIn == true,
              signIn: { signInStartsImmediately = true; signInPresented = true },
              retry: platform.accountIssue?.stage == .bindingRead ? nil : { platform.retryOnline() })
          }
          JournalRuntimeHost(platform: platform, payload: setup.payload,
            extensions: setup.extensions, prestarted: setup.prestartedRuntime)
            .font(.body)
        }
      }
    }
    .environment(\.journalStartupClock, platform.startupClock)
    .task {
      guard setup == nil else { return }
      do { setup = .success(try await prepare()) }
      catch { if !Task.isCancelled { setup = .failure(error) } }
    }
    .onChange(of: scenePhase, initial: true) { _, phase in
      if phase == .background { lifecycle(backgrounded: true) }
      else if phase == .active { lifecycle(backgrounded: false) }
    }
    .onChange(of: platform.authenticationRequired, initial: true) { _, required in
      if required && platform.localAccountAvailable == false && !signInPresented {
        signInStartsImmediately = false; signInPresented = true
      }
      // The authentication owner closes its sheet after account preparation.
      // Closing on the intermediate native identity update can cancel that work.
    }
    .onChange(of: platform.localAccountAvailable, initial: true) { _, available in
      if available == false && platform.authenticationRequired && !signInPresented {
        signInStartsImmediately = false; signInPresented = true
      }
    }
    .sheet(isPresented: $signInPresented) {
      NavigationStack {
        JournalAuthenticationView(api: JournalPreparedAuthentication(api: authentication,
          prepare: { try await platform.prepareAccount() },
          authorize: { try await platform.beginOnline() },
          cancelPreparation: { platform.cancelAccountPreparation() },
          preparationMessage: {
            platform.accountIssue.map { ($0.errorDescription ?? "") + "\n" + $0.diagnostic }
          }), startsImmediately: signInStartsImmediately,
          cancelled: { signInPresented = false }) {
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
    catch {
      let diagnostic = JournalRuntime.safeDescription(error, operation: "lifecycle.enqueue")
      Logger(subsystem: "com.logseq.journal", category: "lifecycle").error("\(diagnostic, privacy: .public)")
    }
  }
}
