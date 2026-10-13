import Foundation

/// Startup facts passed to the existing OCaml worker configuration decoder.
enum JournalStartupConfiguration {
  enum Failure: Error { case invalidConfiguration }

  private struct Target: Encodable {
    struct Payload: Encodable { let base_url: String }
    let payload: Payload
    func encode(to encoder: Encoder) throws {
      var values = encoder.unkeyedContainer()
      try values.encode("Managed_sync")
      try values.encode(payload)
    }
  }
  private struct Configuration: Encodable {
    let application_support_directory: String
    let target: Target
    let compatibility_profile: [String]
    let response_budget_bytes: Int
    let default_page_size: Int
  }

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
    let json = try JSONEncoder().encode(Configuration(
      application_support_directory: applicationSupportPath,
      target: Target(payload: .init(base_url: managedSyncOrigin)),
      compatibility_profile: ["Logseq_65_33_or_newer"],
      response_budget_bytes: 262144, default_page_size: 50))
    guard json.count + 8 <= 1024 * 1024 else { throw Failure.invalidConfiguration }
    var bytes = Data("LDB1".utf8)
    let count = UInt32(json.count)
    for offset in 0..<4 { bytes.append(UInt8((count >> (offset * 8)) & 255)) }
    bytes.append(json)
    return bytes
  }
}
