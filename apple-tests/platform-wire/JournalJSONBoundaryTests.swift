import Foundation

@main @MainActor struct JournalJSONBoundaryTests {
  private struct Child: Decodable { let name: String; let note: String? }
  private struct Internal: Decodable { let children: [Child]; let named: [String: Child] }
  private enum Choice: Decodable { case value(Child) }
  private struct FoundationValues: Codable {
    let data: Data; let date: Date; let url: URL; let decimal: Decimal
  }
  private static var failures = 0

  private static func check(_ name: String, _ action: () throws -> Bool) {
    do {
      if try action() { print("PASS \(name)") }
      else { failures += 1; print("FAIL \(name)") }
    } catch { failures += 1; print("FAIL \(name): \(type(of: error))") }
  }
  private static func rejected(_ action: () throws -> Void) -> Bool {
    do { try action(); return false } catch { return true }
  }
  private static func packet(_ payload: String) -> Data {
    var bytes = Data([76,74,80,50,2,0,8,0] + Array(repeating: UInt8(0), count:24))
    let data = Data(payload.utf8)
    for n in 0..<4 { bytes[24+n] = UInt8((data.count >> (8*n)) & 255) }
    bytes.append(data)
    return bytes
  }

  static func main() throws {
    check("public native wire rejects extra internal fields") {
      rejected { _ = try JournalPlatformWire.decodeRequest(packet(#"{"challengeId":"synthetic","future":true}"#)) }
    }
    check("public native wire retains required and type validation") {
      [#"{"future":true}"#, #"{"challengeId":null}"#, #"{"challengeId":1}"#].allSatisfy {
        input in rejected { _ = try JournalPlatformWire.decodeRequest(packet(input)) }
      }
    }
    check("public account binding rejects extra internal fields") {
      rejected { _ = try JournalLocalAccountBindingStore.decode(Data(#"{"version":2,"userId":"synthetic","managedSyncOrigin":"https://example.invalid","future":true}"#.utf8)) }
    }
    check("recursive internal decoder rejects root nested array and dictionary extensions") {
      [#"{"children":[],"named":{},"future":true}"#,
       #"{"children":[{"name":"synthetic","future":true}],"named":{}}"#,
       #"{"children":[],"named":{"dynamic-key":{"name":"synthetic","future":true}}}"#].allSatisfy {
        input in rejected { _ = try JournalInternalJSON.decode(Internal.self, from: Data(input.utf8)) }
      }
    }
    check("closed native decoder preserves option null and dynamic dictionaries") {
      let value = try JournalInternalJSON.decode(Internal.self, from:
        Data(#"{"children":[{"name":"synthetic","note":null}],"named":{"dynamic-key":{"name":"synthetic"}}}"#.utf8))
      return value.children.first?.note == nil && value.named["dynamic-key"]?.name == "synthetic"
    }
    check("closed native decoder preserves required and scalar type constraints") {
      [#"{"children":[],"named":{"dynamic-key":{}}}"#,
       #"{"children":[{"name":null}],"named":{}}"#,
       #"{"children":[{"name":1}],"named":{}}"#].allSatisfy {
        input in rejected { _ = try JournalInternalJSON.decode(Internal.self, from: Data(input.utf8)) }
      }
    }
    check("closed enum containers reject extra cases") {
      rejected { _ = try JournalInternalJSON.decode(Choice.self, from:
        Data(#"{"value":{"_0":{"name":"synthetic"}},"future":{}}"#.utf8)) }
    }
    check("closed field errors do not emit unknown field names or values") {
      do {
        _ = try JournalInternalJSON.decode(Internal.self, from:
          Data(#"{"children":[],"named":{},"CANARY_FIELD_NAME":"CANARY_PRIVATE_VALUE"}"#.utf8))
        return false
      } catch { return !String(describing:error).contains("CANARY") }
    }
    check("external Cognito response keeps open semantics") {
      let response = try JSONDecoder().decode(JournalCognitoTokenResponse.self, from:
        Data(#"{"id_token":"synthetic","access_token":"synthetic","expires_in":3600,"token_type":"Bearer","future":{"nested":true}}"#.utf8))
      return response.expires_in == 3600 && response.refresh_token == nil
    }
    check("closed decoder preserves Foundation scalar roots and nested values") {
      let encoder = JSONEncoder()
      let bytes = Data([1, 2, 3])
      let root = try JournalInternalJSON.decode(Data.self, from: encoder.encode(bytes))
      let number = try JournalInternalJSON.decode(Decimal.self, from: encoder.encode(Decimal(12)))
      let value = FoundationValues(data: bytes, date: Date(timeIntervalSinceReferenceDate: 1),
        url: URL(string: "https://example.invalid")!, decimal: Decimal(12))
      let decoded = try JournalInternalJSON.decode(FoundationValues.self, from: encoder.encode(value))
      let array = try JournalInternalJSON.decode([Data].self, from: encoder.encode([bytes]))
      return root == bytes && number == 12 && decoded.data == bytes && decoded.date == value.date
        && decoded.url == value.url && decoded.decimal == value.decimal && array == [bytes]
    }
    if failures > 0 { exit(1) }
  }
}
