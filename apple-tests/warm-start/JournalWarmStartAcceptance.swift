import LUIAppleBackend
import Foundation
import Observation
import SwiftUI
#if os(iOS)
import UIKit
#endif
#if os(macOS)
import AppKit

@MainActor private final class AcceptanceDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApplication.shared.activate()
    NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
  }
}
#else
import UIKit
#endif

private struct WarmFixture: Decodable {
  struct Graph: Decodable {
    let graphId: String
    let graphDir: String
    let expectedTimelineText: String
  }
  let formatVersion: Int
  let supportRoot: String
  let baseUrl: String
  let userId: String
  let graphs: [Graph]

  func identity(_ graph: Graph) -> [String: Any] {
    ["origin": baseUrl, "userId": userId, "graphId": graph.graphId]
  }

  func relocated(to support: URL) -> Self {
    Self(formatVersion: formatVersion, supportRoot: support.path,
      baseUrl: baseUrl, userId: userId, graphs: graphs.map { graph in
        Graph(graphId: graph.graphId,
          graphDir: support.appendingPathComponent("logseq-db-worker/synced-graphs/" + graph.graphId).path,
          expectedTimelineText: graph.expectedTimelineText)
      })
  }
}

@MainActor private final class OfflineAuth: JournalAuthCapability {
  let userID: String
  var isTimelinePresented: () -> Bool = { false }
  var tokenRequests = 0
  var requestedBeforeTimeline = false
  init(_ userID: String) { self.userID = userID }
  func currentUserID() async throws -> String? { userID }
  func freshIDToken() async throws -> String {
    tokenRequests += 1
    requestedBeforeTimeline = requestedBeforeTimeline || !isTimelinePresented()
    if ProcessInfo.processInfo.arguments.contains("--auth-failure") {
      throw JournalPlatformServices.Failure.unavailable
    }
    try await Task.sleep(for: .seconds(3600))
    throw CancellationError()
  }
  func signOut() async throws { throw JournalPlatformServices.Failure.unavailable }
}

@Observable @MainActor private final class WarmProbe {
  var status = "Opening encrypted offline graph"
  var presented = false
  var recoveryObserved = false
  var ready = false
  var disconnected = 0
  var payload = Data()
  let missing: Bool
  let fixture: WarmFixture
  let auth: OfflineAuth
  let services: JournalPlatformServices
  let reportURL: URL
  let platform: JournalApplicationPlatform

  init(fixture: WarmFixture, missing: Bool, report: URL) throws {
    self.fixture = fixture
    self.missing = missing
    self.reportURL = report
    self.auth = OfflineAuth(fixture.userId)
    services = JournalPlatformServices(auth: auth,
      account: JournalAccountStore(
        load: { JournalLocalAccount(userID: fixture.userId, managedSyncOrigin: fixture.baseUrl) },
        save: { _ in }, clear: { throw JournalPlatformServices.Failure.unavailable }),
      managedSyncOrigin: fixture.baseUrl)
    platform = JournalApplicationPlatform(services: services)
    auth.isTimelinePresented = { [weak services] in services?.timelinePresented == true }
    payload = try JournalStartupConfiguration.encode(
      applicationSupportPath: fixture.supportRoot, managedSyncOrigin: fixture.baseUrl)
    guard fixture.formatVersion == 2, let first = fixture.graphs.first,
      fixture.graphs.count <= 4,
      Set(fixture.graphs.map(\.graphId)).count == fixture.graphs.count
    else { throw JournalPlatformServices.Failure.unavailable }
    var request = fixture.identity(first)
    request["operation"] = "installTestWrappedGraphKeyFixture"
    let installed = try JournalE2EECrypto.handle(request)
    for graph in fixture.graphs.dropFirst() {
      var additional = fixture.identity(graph)
      additional["operation"] = "verifyAndSaveWrappedGraphKey"
      additional["encryptedGraphKey"] = installed["encryptedGraphKey"]
      _ = try JournalE2EECrypto.handle(additional)
    }
    if missing {
      request["operation"] = "deleteWrappedGraphKey"
      _ = try JournalE2EECrypto.handle(request)
    }
  }

  /// Mirrors the old bridge callbacks through the platform's observation
  /// hooks: `request` runs inside JournalApplicationPlatform, and connect /
  /// disconnect transitions come from the runtime's attach/detach.
  func observePlatform() {
    platform.requestObserver = { [self] request in
      if request == .timelinePresented {
        presented = true
        // Startup allows network overlap, but blocked authentication must not
        // prevent the local timeline from being presented.
        let passed = (!missing || recoveryObserved) && services.timelinePresented
        status = passed ? "PASS encrypted local timeline with authentication blocked" : "FAIL warm-start presentation"
        record("timeline-presented")
      }
    }
    platform.connectionObserver = { [self] connected in
      if connected {
        ready = true
        record("connected")
      } else {
        ready = false
        disconnected += 1
        services.invalidateConnection()
        record("disconnected")
      }
    }
  }

  func checkRecovery() {
    recoveryObserved = missing && !presented
    status = recoveryObserved
      ? "PASS explicit recovery with authentication blocked" : "FAIL unexpected local presentation"
    record("recovery-observation")
  }

  /// Inspects the public runtime surface (JournalRuntime + the journal pump)
  /// directly — the counterpart of the old NativeRuntime.open pump loop.
  func inspectFirstFrame() async {
    do {
      let headless = JournalApplicationPlatform(services: services)
      let runtime = try JournalRuntime(
        platform: headless, startupPayload: payload,
        extensionRegistry: try JournalExtensions.registry())
      runtime.start()
      for index in 0..<5 {
        runtime.pump()
        try await Task.sleep(for: .milliseconds(50))
        status = "Native frame \(index): root=\(runtime.rootID.map(String.init) ?? "pending") applied=\(runtime.appliedPatches)"
        record("native-frame")
      }
      runtime.stop()
    } catch { status = "FAIL first frame: \(error)"; record("first-frame-error") }
  }

  func shutdown() async {
    guard let exchange = platform.beginShutdown() else { return }
    let outcome = await exchange.result
    status = outcome == .completed && disconnected == 1
      ? "PASS real Journal cooperative shutdown" : "FAIL shutdown: \(outcome)"
    record("shutdown-\(outcome)")
  }

  private func record(_ event: String) {
    #if os(macOS)
    let active = NSApp.isActive
    let hidden = NSApp.isHidden
    #else
    let active = UIApplication.shared.applicationState == .active
    let hidden = UIApplication.shared.applicationState == .background
    #endif
    let value: [String: Any] = ["event": event, "status": status, "missingWrappedKey": missing,
      "timelinePresented": presented, "tokenRequests": auth.tokenRequests,
      "recoveryObserved": recoveryObserved,
      "requestedBeforeTimeline": auth.requestedBeforeTimeline, "disconnects": disconnected,
      "active": active, "hidden": hidden]
    do {
      let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) + Data([10])
      if !FileManager.default.fileExists(atPath: reportURL.path) {
        FileManager.default.createFile(atPath: reportURL.path, contents: nil)
      }
      let output = try FileHandle(forWritingTo: reportURL)
      try output.seekToEnd()
      try output.write(contentsOf: data)
      try output.close()
    } catch { status = "FAIL writing acceptance observations" }
  }
}

@main struct JournalWarmStartAcceptance: App {
  @Environment(\.scenePhase) private var systemScenePhase
  #if os(macOS)
  @NSApplicationDelegateAdaptor(AcceptanceDelegate.self) private var delegate
  #endif
  @State private var probe: WarmProbe
  @State private var activeScene = true
  private let registry: LUIAppleExtensionRegistry

  init() {
    // This executable is test-only; never access the user's native secrets.
    precondition(JournalE2EECrypto.testFixtureStorageIsIsolated(
      environment: ProcessInfo.processInfo.environment), "Memory-only secret stores are required")
    do {
      let arguments = ProcessInfo.processInfo.arguments
      guard let index = arguments.firstIndex(of: "--fixture"), index + 1 < arguments.count else {
        fatalError("--fixture FILE is required")
      }
      func fixturePath(_ value: String) throws -> URL {
        #if os(iOS)
        guard !value.hasPrefix("/"), !value.split(separator: "/").contains("..") else {
          throw JournalPlatformServices.Failure.unavailable
        }
        return try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
          appropriateFor: nil, create: true).appendingPathComponent(value)
        #else
        return URL(fileURLWithPath: value)
        #endif
      }
      let path = try fixturePath(arguments[index + 1])
      var fixture = try JSONDecoder().decode(WarmFixture.self, from: Data(contentsOf: path))
      if let supportIndex = arguments.firstIndex(of: "--support-root"), supportIndex + 1 < arguments.count {
        fixture = fixture.relocated(to: try fixturePath(arguments[supportIndex + 1]))
      }
      #if os(iOS)
      guard arguments.contains("--support-root") else {
        fatalError("--support-root relative Documents path is required on iPhone")
      }
      #endif
      let probe = try WarmProbe(fixture: fixture,
        missing: arguments.contains("--missing-key"), report: path.appendingPathExtension("observations.jsonl"))
      probe.observePlatform()
      _probe = State(initialValue: probe)
      self.registry = try JournalExtensions.registry()
    } catch { fatalError("Fixture setup failed: \(error)") }
  }

  var body: some Scene {
    #if os(macOS)
    Window("Journal warm-start acceptance", id: "warm-start") {
      content.frame(minWidth: 650, minHeight: 650)
    }
    #else
    WindowGroup("Journal warm-start acceptance") {
      if ProcessInfo.processInfo.arguments.contains("--accessibility-size") {
        content.background(AcceptanceWindowTraits())
      } else {
        content
      }
    }
    #endif
  }

  private var content: some View {
    VStack(spacing: 0) {
      if !ProcessInfo.processInfo.arguments.contains("--application-only") {
      #if os(macOS)
        Text(probe.status).accessibilityIdentifier("warm-start-status").padding()
        HStack {
          if probe.missing { Button("Check recovery admission") { probe.checkRecovery() } }
          Button("Shutdown real Journal") { Task { await probe.shutdown() } }.disabled(!probe.ready)
          Toggle("Active scene", isOn: $activeScene)
        }.padding(8)
      #else
        if ProcessInfo.processInfo.arguments.contains("--accessibility-size") {
          AcceptanceTypeReadout()
        }
        HStack {
          Text(probe.status).font(.caption).lineLimit(2)
            .accessibilityIdentifier("warm-start-status")
            .accessibilityValue(systemScenePhase == .active ? "Active" : "Inactive")
          Spacer()
          Menu("Test controls") {
            if probe.missing { Button("Check recovery admission") { probe.checkRecovery() } }
            Button("Shutdown real Journal") { Task { await probe.shutdown() } }.disabled(!probe.ready)
          }
        }.padding(8).dynamicTypeSize(.large)
      #endif
      }
        if ProcessInfo.processInfo.arguments.contains("--pump-only") {
          Text("Inspecting the public native runtime").task { await probe.inspectFirstFrame() }
        } else {
          JournalRuntimeHost(platform: probe.platform, payload: probe.payload,
            extensions: registry)
            .font(.body)
            .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("--dark-appearance") ? .dark :
              ProcessInfo.processInfo.arguments.contains("--light-appearance") ? .light : nil)
            // The previous integration harness explicitly supplied the resumed phase.
            // This fixture controls that input; production activation is tested separately.
            #if os(macOS)
            .environment(\.scenePhase, activeScene ? .active : .inactive)
            #endif
        }
    }
  }
}

#if os(iOS)
private struct AcceptanceWindowTraits: UIViewRepresentable {
  final class TraitView: UIView {
    override func didMoveToWindow() {
      super.didMoveToWindow()
      window?.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
    }
  }

  func makeUIView(context: Context) -> TraitView { TraitView() }
  func updateUIView(_ view: TraitView, context: Context) {}
}

private struct AcceptanceTypeReadout: View {
  @Environment(\.dynamicTypeSize) private var size

  var body: some View {
    Text("Test Dynamic Type")
      .font(.system(size: 9))
      .accessibilityIdentifier("acceptance-dynamic-type")
      .accessibilityValue(String(describing: size))
  }
}
#endif
