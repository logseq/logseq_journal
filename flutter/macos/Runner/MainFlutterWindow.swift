import Cocoa
import FlutterMacOS

enum JournalPlatformEnvironment {
  private static var generation: Int64 = 0

  static func snapshot(
    applicationSupportPath: String,
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
    return snapshot(
      applicationSupportPath: canonicalPath,
      now: Date(),
      locale: Locale.current,
      timeZone: TimeZone.current,
      calendar: Calendar.current,
      generation: generation
    )
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
