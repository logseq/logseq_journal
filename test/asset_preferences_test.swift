import Foundation

@main struct AssetPreferencesTest {
  static func main() {
    let name = "org.logseq.test.asset-preferences." + UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let preferences = JournalAssetPreferences(defaults: defaults)
    precondition(preferences.recentDays == 7, "Missing preference defaults to seven days")
    precondition(preferences.save(recentDays: 0))
    precondition(JournalAssetPreferences(defaults: defaults).recentDays == 0,
                 "Zero survives recreation and disables recent downloads")
    precondition(preferences.save(recentDays: 3660))
    precondition(JournalAssetPreferences(defaults: defaults).recentDays == 3660)
    precondition(!preferences.save(recentDays: -1))
    precondition(!preferences.save(recentDays: 3661))
    precondition(preferences.recentDays == 3660, "Invalid changes preserve the preference")
    defaults.set("broken", forKey: JournalAssetPreferences.recentDaysKey)
    precondition(preferences.recentDays == 7, "Malformed storage uses the documented default")
    defaults.set(3661, forKey: JournalAssetPreferences.recentDaysKey)
    precondition(preferences.recentDays == 7, "Out-of-range storage cannot expand demand")
    print("Asset preferences passed")
  }
}
