import Foundation

struct JournalAssetPreferences {
  let defaults: UserDefaults
  static let recentDaysKey = "assetRecentDays"
  static let allowedDays = 0...3660
  var recentDays: Int {
    guard let value = defaults.object(forKey: Self.recentDaysKey) as? Int,
          Self.allowedDays.contains(value) else { return 7 }
    return value
  }
  func save(recentDays: Int) -> Bool {
    guard Self.allowedDays.contains(recentDays) else { return false }
    defaults.set(recentDays, forKey: Self.recentDaysKey)
    return true
  }
}
