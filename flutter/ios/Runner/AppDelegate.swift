import Flutter
import UIKit

enum JournalPlatformEnvironment {
  static func current() throws -> [String: Any] {
    let supportURL = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let canonicalPath = supportURL.resolvingSymlinksInPath().standardizedFileURL.path
    var result: [String: Any] = [
      "applicationSupportPath": canonicalPath,
      "platform": "ios",
      "applicationDataPath": canonicalPath,
      "graphName": "logseq_journal",
    ]
    result["typographyPreset"] = UserDefaults.standard.string(forKey: "typographyPreset")
    do {
      if let binding = try JournalLocalAccountBindingStore.load() {
        result["localAccountBinding"] = binding
      }
    } catch {
      result.removeValue(forKey: "localAccountBinding")
    }
    return result
  }

}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var journalPlatformChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(
      name: "logseq_journal/platform",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      do {
        switch call.method {
        case "getStartupEnvironment":
          result(try JournalPlatformEnvironment.current())
        case "getPreference":
          guard
            let arguments = call.arguments as? [String: Any],
            arguments.count == 1,
            arguments["key"] as? String == "typographyPreset"
          else {
            throw CocoaError(.validationMissingMandatoryProperty)
          }
          result(UserDefaults.standard.string(forKey: "typographyPreset"))
        case "setPreference":
          guard
            let arguments = call.arguments as? [String: Any],
            arguments.count == 2,
            arguments["key"] as? String == "typographyPreset",
            let value = arguments["value"] as? String,
            ["dense", "balanced", "comfortable"].contains(value)
          else {
            throw CocoaError(.validationMissingMandatoryProperty)
          }
          UserDefaults.standard.set(value, forKey: "typographyPreset")
          result(nil)
        case "setLocalAccountBinding":
          try JournalLocalAccountBindingStore.save(arguments: call.arguments)
          result(nil)
        case "clearLocalAccountBinding":
          try JournalLocalAccountBindingStore.clear()
          result(nil)
        case "e2eeCrypto":
          guard let request = call.arguments as? [String: Any] else {
            throw JournalE2EECryptoError.invalidRequest
          }
          result(try JournalE2EECrypto.handle(request))
        default:
          result(FlutterMethodNotImplemented)
        }
      } catch {
        result(
          FlutterError(
            code: "journal_platform",
            message: "Unable to service the journal platform request.",
            details: nil
          )
        )
      }
    }
    journalPlatformChannel = channel
  }
}
