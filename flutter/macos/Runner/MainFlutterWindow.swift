import Cocoa
import Darwin
import FlutterMacOS
import Security

enum JournalLocalAccountBindingStore {
  private static let maximumBytes = 4_096

  static func query() -> [CFString: Any] {
    [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: "com.logseq.journal.local-account-binding",
      kSecAttrAccount: "current-managed-sync-account",
      kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      kSecAttrSynchronizable: kCFBooleanFalse as Any,
    ]
  }

  static func encode(userID: String, managedSyncOrigin: String) throws -> Data {
    guard
      !userID.isEmpty,
      userID.utf8.count <= 512,
      !userID.contains("\0"),
      managedSyncOrigin.utf8.count <= 2_048,
      let origin = URL(string: managedSyncOrigin),
      origin.scheme == "https",
      origin.host != nil
    else { throw CocoaError(.validationMissingMandatoryProperty) }
    let data = try JSONSerialization.data(
      withJSONObject: [
        "version": 1,
        "userId": userID,
        "managedSyncOrigin": managedSyncOrigin,
      ],
      options: [.sortedKeys]
    )
    guard data.count <= maximumBytes else { throw CocoaError(.fileWriteUnknown) }
    return data
  }

  static func decode(_ data: Data) throws -> [String: Any] {
    guard data.count <= maximumBytes,
      let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      value.count == 3,
      value["version"] as? Int == 1,
      let userID = value["userId"] as? String,
      let origin = value["managedSyncOrigin"] as? String
    else { throw CocoaError(.fileReadCorruptFile) }
    _ = try encode(userID: userID, managedSyncOrigin: origin)
    return value
  }

  static func load() throws -> [String: Any]? {
    var lookup = query()
    lookup[kSecReturnData] = kCFBooleanTrue
    lookup[kSecMatchLimit] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(lookup as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = item as? Data else {
      throw CocoaError(.fileReadUnknown)
    }
    return try decode(data)
  }

  static func save(arguments: Any?) throws {
    guard
      let value = arguments as? [String: Any],
      value.count == 3,
      value["version"] as? Int == 1,
      let userID = value["userId"] as? String,
      let origin = value["managedSyncOrigin"] as? String
    else { throw CocoaError(.validationMissingMandatoryProperty) }
    let data = try encode(userID: userID, managedSyncOrigin: origin)
    SecItemDelete(query() as CFDictionary)
    var addition = query()
    addition[kSecValueData] = data
    guard SecItemAdd(addition as CFDictionary, nil) == errSecSuccess else {
      throw CocoaError(.fileWriteUnknown)
    }
  }

  static func clear() throws {
    let status = SecItemDelete(query() as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw CocoaError(.fileWriteUnknown)
    }
  }
}

enum JournalPlatformEnvironment {
  private static var generation: Int64 = 0

  static func snapshot(
    applicationSupportPath: String,
    homeDirectoryPath: String,
    graphName: String = "logseq_journal",
    now: Date,
    locale: Locale,
    timeZone: TimeZone,
    calendar: Calendar,
    generation: Int64 = 1
  ) -> [String: Any] {
    var localCalendar = calendar
    localCalendar.locale = locale
    localCalendar.timeZone = timeZone
    let components = localCalendar.dateComponents([.year, .month, .day], from: now)
    let localDay =
      (components.year ?? 0) * 10_000
      + (components.month ?? 0) * 100
      + (components.day ?? 0)
    return [
      "applicationSupportPath": applicationSupportPath,
      "platform": "desktop",
      "homeDirectoryPath": homeDirectoryPath,
      "graphName": graphName,
      "instantUnixMilliseconds": Int64(now.timeIntervalSince1970 * 1_000),
      "localDay": localDay,
      "locale": locale.identifier,
      "timeZoneId": timeZone.identifier,
      "utcOffsetSeconds": timeZone.secondsFromGMT(for: now),
      "generation": generation,
    ]
  }

  static func current() throws -> [String: Any] {
    generation += 1
    let supportURL = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let canonicalPath = supportURL.resolvingSymlinksInPath().standardizedFileURL.path
    guard
      let account = getpwuid(getuid()),
      let homeDirectory = account.pointee.pw_dir
    else {
      throw CocoaError(.fileReadUnknown)
    }
    let accountHomePath = String(cString: homeDirectory)
    guard accountHomePath.hasPrefix("/") else {
      throw CocoaError(.fileReadInvalidFileName)
    }
    let homePath = URL(fileURLWithPath: accountHomePath, isDirectory: true)
      .resolvingSymlinksInPath().standardizedFileURL.path
    var result = snapshot(
      applicationSupportPath: canonicalPath,
      homeDirectoryPath: homePath,
      now: Date(),
      locale: Locale.current,
      timeZone: TimeZone.current,
      calendar: Calendar.current,
      generation: generation
    )
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

  static func formatJournalDays(arguments: Any?) throws -> [[String: Any]] {
    guard
      let arguments = arguments as? [String: Any],
      let days = arguments["days"] as? [Int],
      let localeIdentifier = arguments["locale"] as? String,
      let timeZoneIdentifier = arguments["timeZoneId"] as? String,
      !days.isEmpty,
      days.count <= 64,
      Set(days).count == days.count,
      let timeZone = TimeZone(identifier: timeZoneIdentifier)
    else {
      throw CocoaError(.validationMissingMandatoryProperty)
    }
    let locale = Locale(identifier: localeIdentifier)
    var identityCalendar = Calendar(identifier: .gregorian)
    identityCalendar.locale = locale
    identityCalendar.timeZone = timeZone
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.timeZone = timeZone
    var displayCalendar = Calendar.current
    displayCalendar.locale = locale
    displayCalendar.timeZone = timeZone
    formatter.calendar = displayCalendar
    formatter.setLocalizedDateFormatFromTemplate("EEE MMM d")
    return try days.map { day in
      let components = DateComponents(
        calendar: identityCalendar,
        timeZone: timeZone,
        year: day / 10_000,
        month: (day / 100) % 100,
        day: day % 100,
        hour: 12
      )
      guard
        let date = identityCalendar.date(from: components),
        identityCalendar.dateComponents([.year, .month, .day], from: date).year
          == components.year,
        identityCalendar.dateComponents([.year, .month, .day], from: date).month
          == components.month,
        identityCalendar.dateComponents([.year, .month, .day], from: date).day
          == components.day
      else {
        throw CocoaError(.validationMissingMandatoryProperty)
      }
      return ["day": day, "heading": formatter.string(from: date)]
    }
  }
}

class MainFlutterWindow: NSWindow {
  private var journalPlatformChannel: FlutterMethodChannel?
  private var calendarObservers: [NSObjectProtocol] = []

  func prepareToTerminate(completion: @escaping () -> Void) {
    guard let channel = journalPlatformChannel else {
      completion()
      return
    }
    channel.invokeMethod("prepareToTerminate", arguments: nil) { _ in
      completion()
    }
  }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let channel = FlutterMethodChannel(
      name: "logseq_journal/platform",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    channel.setMethodCallHandler { call, result in
      do {
        switch call.method {
        case "getStartupEnvironment":
          result(try JournalPlatformEnvironment.current())
        case "formatJournalDays":
          result(try JournalPlatformEnvironment.formatJournalDays(arguments: call.arguments))
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
    let center = NotificationCenter.default
    for (name, reason) in [
      (Notification.Name.NSSystemTimeZoneDidChange, 3),
      (NSLocale.currentLocaleDidChangeNotification, 4),
      (Notification.Name.NSCalendarDayChanged, 2),
    ] {
      calendarObservers.append(
        center.addObserver(forName: name, object: nil, queue: .main) { [weak channel] _ in
          channel?.invokeMethod("calendarChanged", arguments: reason)
        }
      )
    }

    super.awakeFromNib()
  }

  deinit {
    for observer in calendarObservers {
      NotificationCenter.default.removeObserver(observer)
    }
  }
}
