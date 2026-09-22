import Foundation

/// Startup facts passed to the existing OCaml worker configuration decoder.
enum JournalStartupConfiguration {
  enum Failure: Error { case invalidConfiguration }

  static func encode(applicationSupportPath: String, managedSyncOrigin: String) throws -> Data {
    let components = applicationSupportPath.split(separator: "/", omittingEmptySubsequences: false)
    guard applicationSupportPath.hasPrefix("/"), applicationSupportPath.utf8.count <= 4096,
      !applicationSupportPath.contains("\\"), !applicationSupportPath.utf8.contains(0),
      components.count > 1,
      components.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
      let origin = URLComponents(string: managedSyncOrigin), origin.scheme == "https",
      let host = origin.host, !host.isEmpty, origin.user == nil, origin.password == nil,
      origin.path.isEmpty || origin.path == "/", origin.query == nil, origin.fragment == nil
    else { throw Failure.invalidConfiguration }
    let json = try JSONSerialization.data(
      withJSONObject: [
        "applicationSupportDirectory": applicationSupportPath,
        "target": ["kind": "managedSync", "baseUrl": managedSyncOrigin],
        "compatibilityProfile": "logseq-65.33-or-newer",
        "responseBudgetBytes": 262144,
        "defaultPageSize": 50,
      ], options: [.sortedKeys])
    guard json.count + 8 <= 1024 * 1024 else { throw Failure.invalidConfiguration }
    var bytes = Data("LDB1".utf8)
    let count = UInt32(json.count)
    for offset in 0..<4 { bytes.append(UInt8((count >> (offset * 8)) & 255)) }
    bytes.append(json)
    return bytes
  }
}
