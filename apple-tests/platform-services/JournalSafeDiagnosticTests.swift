import Foundation

@main struct JournalSafeDiagnosticTests {
  struct Value: Decodable { let count: Int }
  static func main() throws {
    let cases = [("{\"count\":\"SECRET-token\"}", "typeMismatch"), ("{}", "keyNotFound"),
      ("{\"count\":null}", "valueNotFound"), ("SECRET /private/body", "dataCorrupted")]
    for (source, expected) in cases {
      do { let _:Value = try JournalSafeDiagnostic.decode(Value.self, from: Data(source.utf8)); fatalError("expected decode failure") }
      catch let reason as JournalSafeDiagnostic {
        precondition(reason.rawValue == expected)
        precondition(!reason.localizedDescription.contains("SECRET") && !reason.localizedDescription.contains("private"))
      }
    }
    precondition(JournalSafeDiagnostic.classify(NSError(domain:"SECRET",code:99,
      userInfo:[NSLocalizedDescriptionKey:"token /private/body"])) == .unknown)
    precondition(JournalSafeDiagnostic.backendBatch("unsupported property") == .backendUnsupportedProperty)
    precondition(JournalSafeDiagnostic.backendBatch("SECRET custom graph content") == .backendInvalidBatch)
    precondition(JournalSafeDiagnostic.classify(CocoaError(.fileWriteOutOfSpace)) == .noSpace)
    precondition(JournalSafeDiagnostic.classify(CocoaError(.fileReadNoPermission)) == .permissionDenied)
    print("PASS bounded native decoder/backend/storage reasons exclude arbitrary payloads")
  }
}
