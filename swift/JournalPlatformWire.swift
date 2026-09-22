import Foundation

/// The application-owned protocol shared with Journal_platform in OCaml.
enum JournalPlatformWire {
  enum Failure: Error { case invalidPacket }
  enum Request: Equatable {
    case authenticatedUser, signOut, terminationReady, localAccount, timelinePresented
    case idToken(challengeID: String)
  }
  enum Response: Equatable {
    case authenticatedUser(String?)
    case idToken(challengeID: String, token: String)
    case signedOut, terminationReady, timelinePresented
    case localAccount(userID: String, origin: String)
    case noLocalAccount
  }
  enum Lifecycle: UInt16 { case backgrounded = 1, foregroundResumed = 2 }

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
      let fields = try object(payload)
      guard fields.count == 1, let challenge = fields["challengeId"] as? String else {
        throw Failure.invalidPacket
      }
      return .idToken(challengeID: challenge)
    default:
      throw Failure.invalidPacket
    }
  }

  static func encodeResponse(_ response: Response) throws -> Data {
    switch response {
    case .authenticatedUser(let user):
      if let user { try validate(user, maximum: 512) }
      return try json(tag: 7, ["userId": user as Any? ?? NSNull()])
    case .idToken(let challenge, let token):
      try validate(token, maximum: maximumPayload)
      return try json(tag: 9, ["challengeId": challenge, "token": token])
    case .signedOut:
      return try json(tag: 11, ["signedOut": true])
    case .terminationReady:
      return try json(tag: 14, ["ready": true])
    case .localAccount(let user, let origin):
      try validate(user, maximum: 512)
      guard origin.utf8.count <= 2048,
        let url = URLComponents(string: origin), url.scheme == "https", url.host != nil
      else { throw Failure.invalidPacket }
      return try json(tag: 21, ["userId": user, "managedSyncOrigin": origin])
    case .noLocalAccount:
      return try json(tag: 21, ["userId": NSNull(), "managedSyncOrigin": NSNull()])
    case .timelinePresented:
      return try json(tag: 23, ["presented": true])
    }
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

  private static func object(_ payload: Data) throws -> [String: Any] {
    guard String(data: payload, encoding: .utf8) != nil,
      let value = try? JSONSerialization.jsonObject(with: payload),
      let fields = value as? [String: Any]
    else { throw Failure.invalidPacket }
    return fields
  }

  private static func json(tag: UInt16, _ object: [String: Any]) throws -> Data {
    let payload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return try frame(tag: tag, payload: payload)
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
