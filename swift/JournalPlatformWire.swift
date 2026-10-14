import Foundation

/// The application-owned protocol shared with Journal_platform in OCaml.
enum JournalPlatformWire {
  enum Failure: Error { case invalidPacket }
  enum Request: Equatable {
    case authenticatedUser, signOut, terminationReady, localAccount, timelinePresented
    case idToken(challengeID: String)
    case showNotice(token: String, message: String, actionLabel: String?, durationMs: Int)
    case cancelNotice(token: String)
    case copyText(String)
  }
  enum Response: Equatable {
    case authenticatedUser(String?)
    case idToken(challengeID: String, token: String)
    case signedOut, terminationReady, timelinePresented
    case localAccount(userID: String, origin: String)
    case noLocalAccount
    case notice(token: String, result: String)
    case textCopied
  }
  enum NoticeResult: String {
    case action, dismiss, swipe, timeout
  }
  enum Lifecycle: UInt16 { case backgrounded = 1, foregroundResumed = 2 }

  // Absence is an explicit null; omitted account fields indicate an invalid packet.
  private struct Account: Encodable {
    let userId: String?; let managedSyncOrigin: String?
    private enum CodingKeys: String, CodingKey { case userId, managedSyncOrigin }
    func encode(to encoder: Encoder) throws {
      var fields = encoder.container(keyedBy: CodingKeys.self)
      try fields.encode(userId, forKey: .userId)
      try fields.encode(managedSyncOrigin, forKey: .managedSyncOrigin)
    }
  }
  private struct User: Encodable {
    let userId: String?
    private enum CodingKeys: String, CodingKey { case userId }
    func encode(to encoder: Encoder) throws {
      var fields = encoder.container(keyedBy: CodingKeys.self)
      try fields.encode(userId, forKey: .userId)
    }
  }
  private struct Challenge: Codable { let challengeId: String }
  private struct Token: Codable { let challengeId: String; let token: String }
  private struct SignedOut: Codable { let signedOut: Bool }
  private struct Ready: Codable { let ready: Bool }
  private struct Presented: Codable { let presented: Bool }
  private struct Notice: Codable { let token: Int64; let message: String; let actionLabel: String?; let durationMs: Int }
  private struct NoticeResponse: Codable { let token: Int64; let result: String }
  private struct Cancel: Codable { let token: Int64 }
  private struct Text: Codable { let text: String }
  private struct Copied: Codable { let copied: Bool }

  private static let headerSize = 32
  private static let maximumPayload = 256 * 1024

  static func decodeRequest(_ bytes: Data) throws -> Request {
    guard bytes.count >= headerSize, bytes.count <= headerSize + maximumPayload else {
      throw Failure.invalidPacket
    }
    let packet = Array(bytes)
    guard Array(packet[0..<4]) == Array("LJP2".utf8),
      integer(packet, at: 4, count: 2) == 2,
      packet[8..<24].allSatisfy({ $0 == 0 }),
      integer(packet, at: 24, count: 4) == UInt64(packet.count - headerSize),
      packet[28..<32].allSatisfy({ $0 == 0 })
    else { throw Failure.invalidPacket }
    let payload = Data(packet[headerSize...])
    let tag = integer(packet, at: 6, count: 2)
    switch tag {
    case 6, 10, 13, 20, 22:
      guard payload.isEmpty else { throw Failure.invalidPacket }
      switch tag {
      case 6: return .authenticatedUser
      case 10: return .signOut
      case 13: return .terminationReady
      case 20: return .localAccount
      default: return .timelinePresented
      }
    case 8:
      let value = try decode(Challenge.self, payload)
      return .idToken(challengeID: value.challengeId)
    case 25:
      let value = try decode(Notice.self, payload)
      guard value.durationMs > 0, value.actionLabel?.isEmpty != true else { throw Failure.invalidPacket }
      return .showNotice(token: String(value.token), message: value.message,
        actionLabel: value.actionLabel, durationMs: value.durationMs)
    case 28:
      return .copyText(try decode(Text.self, payload).text)
    case 27:
      return .cancelNotice(token: String(try decode(Cancel.self, payload).token))
    default:
      throw Failure.invalidPacket
    }
  }

  static func encodeResponse(_ response: Response) throws -> Data {
    switch response {
    case .authenticatedUser(let user):
      if let user { try validate(user, maximum: 512) }
      return try json(tag: 7, User(userId: user))
    case .idToken(let challenge, let token):
      try validate(token, maximum: maximumPayload)
      return try json(tag: 9, Token(challengeId: challenge, token: token))
    case .signedOut:
      return try json(tag: 11, SignedOut(signedOut: true))
    case .terminationReady:
      return try json(tag: 14, Ready(ready: true))
    case .localAccount(let user, let origin):
      try validate(user, maximum: 512)
      guard origin.utf8.count <= 2048,
        let url = URLComponents(string: origin), url.scheme == "https", url.host != nil
      else { throw Failure.invalidPacket }
      return try json(tag: 21, Account(userId: user, managedSyncOrigin: origin))
    case .noLocalAccount:
      return try json(tag: 21, Account(userId: nil, managedSyncOrigin: nil))
    case .timelinePresented:
      return try json(tag: 23, Presented(presented: true))
    case .textCopied:
      return try json(tag: 29, Copied(copied: true))
    case .notice(let token, let result):
      guard let token = Int64(token), NoticeResult(rawValue: result) != nil else { throw Failure.invalidPacket }
      return try json(tag: 26, NoticeResponse(token: token, result: result))
    }
  }

  /// Host -> OCaml environment snapshot (tag 24), mirroring
  /// Journal_environment.decode_json's required fields.
  static func environment<Value: Encodable>(_ sample: Value) throws -> Data {
    try json(tag: 24, sample)
  }

  static func prepareToTerminate() -> Data {
    // An empty payload always satisfies the application envelope bound.
    try! frame(tag: 12, payload: Data())
  }

  static func lifecycle(_ kind: Lifecycle, generation: Int64) throws -> Data {
    guard generation >= 0 else { throw Failure.invalidPacket }
    var payload = Data("LJP1".utf8)
    append(1, count: 2, to: &payload)
    append(UInt64(kind.rawValue), count: 2, to: &payload)
    append(UInt64(generation), count: 8, to: &payload)
    return try frame(tag: 15, payload: payload)
  }

  private static func validate(_ value: String, maximum: Int) throws {
    guard !value.isEmpty, value.utf8.count <= maximum, !value.utf8.contains(0) else {
      throw Failure.invalidPacket
    }
  }

  private static func decode<Value: Decodable>(_ type: Value.Type, _ payload: Data) throws -> Value {
    do { return try JournalInternalJSON.decode(type, from: payload) }
    catch { throw Failure.invalidPacket }
  }

  private static func json<Value: Encodable>(tag: UInt16, _ value: Value) throws -> Data {
    try frame(tag: tag, payload: JSONEncoder().encode(value))
  }

  private static func frame(tag: UInt16, payload: Data) throws -> Data {
    guard payload.count <= maximumPayload else { throw Failure.invalidPacket }
    var bytes = Data("LJP2".utf8)
    append(2, count: 2, to: &bytes)
    append(UInt64(tag), count: 2, to: &bytes)
    append(0, count: 8, to: &bytes)
    append(0, count: 8, to: &bytes)
    append(UInt64(payload.count), count: 4, to: &bytes)
    append(0, count: 4, to: &bytes)
    bytes.append(payload)
    return bytes
  }

  private static func integer(_ bytes: [UInt8], at offset: Int, count: Int) -> UInt64 {
    (0..<count).reduce(0) { $0 | (UInt64(bytes[offset + $1]) << ($1 * 8)) }
  }

  private static func append(_ value: UInt64, count: Int, to bytes: inout Data) {
    for offset in 0..<count { bytes.append(UInt8((value >> (offset * 8)) & 255)) }
  }
}
