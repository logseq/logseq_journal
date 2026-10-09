import CryptoKit
import Foundation
import Security

struct JournalCognitoConfiguration: Sendable {
  let domain: String
  let clientID: String
  let userPoolID: String
  let region: String
  let redirectURI: String
  var issuer: String { "https://cognito-idp.\(region).amazonaws.com/\(userPoolID)" }
  static let production = Self(domain: "logseq-prod.auth.us-east-1.amazoncognito.com",
    clientID: "69cs1lgme7p8kbgld8n5kseii6", userPoolID: "us-east-1_dtagLnju8",
    region: "us-east-1", redirectURI: "logseqjournal://auth/callback")
}

enum JournalCognitoError: Error, LocalizedError {
  case configuration, callback, expired, invalidToken, storage, unavailable, request, invalidGrant
  var errorDescription: String? {
    switch self {
    case .configuration: "Web sign-in is not configured."
    case .callback: "The sign-in response could not be verified. Please try again."
    case .expired: "Sign-in timed out. Please try again."
    case .invalidToken: "The account session could not be verified. Please sign in again."
    case .storage: "Unable to save the account session securely. Please try again."
    case .unavailable: "Unable to open the sign-in page. Please try again."
    case .request: "Unable to connect to sign-in. Please try again."
    case .invalidGrant: "Your account session expired. Please sign in again."
    }
  }
}

enum JournalCognitoOAuth {
  static func url64(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
  static func data64(_ value: String) throws -> Data {
    guard !value.isEmpty, value.utf8.allSatisfy({
      (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
    }) else { throw JournalCognitoError.invalidToken }
    let base = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    guard let data = Data(base64Encoded: base + String(repeating: "=", count: (4 - base.count % 4) % 4))
    else { throw JournalCognitoError.invalidToken }
    return data
  }
  static func random() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess
    else { throw JournalCognitoError.unavailable }
    return url64(Data(bytes))
  }
  static func challenge(_ verifier: String) -> String { url64(Data(SHA256.hash(data: Data(verifier.utf8)))) }
  static func form(_ values: [String: String]) -> Data {
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return Data(values.sorted { $0.key < $1.key }.map {
      $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "="
        + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
    }.joined(separator: "&").utf8)
  }
  static func authorization(_ configuration: JournalCognitoConfiguration, state: String,
                            verifier: String, nonce: String) throws -> URL {
    guard !configuration.clientID.isEmpty, !configuration.region.isEmpty, !configuration.userPoolID.isEmpty,
      let redirect = URLComponents(string: configuration.redirectURI), redirect.scheme == "logseqjournal",
      redirect.host == "auth", redirect.path == "/callback", redirect.query == nil, redirect.fragment == nil,
      redirect.user == nil, redirect.password == nil, redirect.port == nil,
      configuration.domain.utf8.allSatisfy({ (45...57).contains($0) || (97...122).contains($0) }),
      configuration.domain.contains(".") else { throw JournalCognitoError.configuration }
    var url = URLComponents()
    url.scheme = "https"; url.host = configuration.domain; url.path = "/oauth2/authorize"
    url.queryItems = ["response_type": "code", "client_id": configuration.clientID,
      "redirect_uri": configuration.redirectURI, "scope": "openid", "state": state,
      "code_challenge": challenge(verifier), "code_challenge_method": "S256", "nonce": nonce]
      .map { URLQueryItem(name: $0.key, value: $0.value) }
    guard let result = url.url else { throw JournalCognitoError.configuration }
    return result
  }
  static func code(_ callback: URL, configuration: JournalCognitoConfiguration, state: String) throws -> String {
    guard let actual = URLComponents(url: callback, resolvingAgainstBaseURL: false),
      let expected = URLComponents(string: configuration.redirectURI),
      actual.scheme == expected.scheme, actual.host == expected.host,
      actual.percentEncodedPath == expected.percentEncodedPath,
      actual.port == nil, actual.user == nil, actual.password == nil, actual.fragment == nil
    else { throw JournalCognitoError.callback }
    var values: [String: String] = [:]
    for item in actual.queryItems ?? [] {
      guard values[item.name] == nil, let value = item.value else { throw JournalCognitoError.callback }
      values[item.name] = value
    }
    guard values["state"] == state, values["error"] == nil,
      let code = values["code"], !code.isEmpty, code.utf8.count <= 8192 else { throw JournalCognitoError.callback }
    return code
  }
}

struct JournalCognitoTokens: Codable, Sendable {
  let idToken: String
  let accessToken: String
  let refreshToken: String
  let userID: String
  let issuer: String
  let clientID: String
  let expiresAt: Date
}

struct JournalCognitoTokenResponse: Decodable {
  let id_token: String
  let access_token: String
  let refresh_token: String?
  let expires_in: Int
  let token_type: String
}

/// Verify both signatures against keys from the fixed user-pool issuer, never a JWT URL.
struct JournalCognitoTokenValidator {
  struct Key: Decodable {
    let kty: String; let kid: String; let alg: String?; let use: String?; let n: String; let e: String
  }
  struct Keys: Decodable { let keys: [Key] }
  let keys: Keys
  init(jwks: Data) throws {
    guard jwks.count <= 262144 else { throw JournalCognitoError.invalidToken }
    keys = try JSONDecoder().decode(Keys.self, from: jwks)
  }
  private func claims(_ token: String) throws -> [String: Any] {
    guard token.utf8.count <= 32768 else { throw JournalCognitoError.invalidToken }
    let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 3,
      let header = try JSONSerialization.jsonObject(with: JournalCognitoOAuth.data64(parts[0])) as? [String: Any],
      header["alg"] as? String == "RS256", header["crit"] == nil,
      let kid = header["kid"] as? String,
      keys.keys.filter({ $0.kid == kid }).count == 1,
      let key = keys.keys.first(where: { $0.kid == kid }), key.kty == "RSA",
      key.alg == nil || key.alg == "RS256", key.use == nil || key.use == "sig"
    else { throw JournalCognitoError.invalidToken }
    let n = try JournalCognitoOAuth.data64(key.n), e = try JournalCognitoOAuth.data64(key.e)
    guard (256...1024).contains(n.count), (1...8).contains(e.count) else { throw JournalCognitoError.invalidToken }
    func tlv(_ tag: UInt8, _ data: Data) -> Data {
      let count = data.count
      var length = Data()
      if count < 128 { length.append(UInt8(count)) }
      else {
        var size = count, bytes: [UInt8] = []
        while size > 0 { bytes.insert(UInt8(size & 255), at: 0); size >>= 8 }
        length.append(UInt8(128 + bytes.count)); length.append(contentsOf: bytes)
      }
      return Data([tag]) + length + data
    }
    func integer(_ data: Data) -> Data {
      tlv(2, (data.first! >= 128 ? Data([0]) : Data()) + data)
    }
    let der = tlv(48, integer(n) + integer(e))
    guard let publicKey = SecKeyCreateWithData(der as CFData,
      [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, nil),
      SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256,
        Data((parts[0] + "." + parts[1]).utf8) as CFData,
        try JournalCognitoOAuth.data64(parts[2]) as CFData, nil),
      let result = try JSONSerialization.jsonObject(with: JournalCognitoOAuth.data64(parts[1])) as? [String: Any]
    else { throw JournalCognitoError.invalidToken }
    return result
  }
  func validate(_ response: JournalCognitoTokenResponse, configuration: JournalCognitoConfiguration,
                nonce: String?, previous: JournalCognitoTokens?, now: Date) throws -> JournalCognitoTokens {
    let id = try claims(response.id_token), access = try claims(response.access_token)
    func expiry(_ claims: [String: Any], use: String) throws -> Date {
      guard claims["iss"] as? String == configuration.issuer, claims["token_use"] as? String == use,
        let exp = claims["exp"] as? Double, exp.isFinite, exp > now.timeIntervalSince1970,
        let iat = claims["iat"] as? Double, iat <= now.timeIntervalSince1970 + 60
      else { throw JournalCognitoError.invalidToken }
      return Date(timeIntervalSince1970: exp)
    }
    let expiryID = try expiry(id, use: "id"), expiryAccess = try expiry(access, use: "access")
    guard id["aud"] as? String == configuration.clientID,
      access["client_id"] as? String == configuration.clientID,
      let user = id["sub"] as? String, !user.isEmpty, user.utf8.count <= 512,
      access["sub"] as? String == user, previous == nil || previous?.userID == user,
      nonce == nil || id["nonce"] as? String == nonce,
      response.token_type.lowercased() == "bearer", response.expires_in > 0,
      let refresh = response.refresh_token ?? previous?.refreshToken, !refresh.isEmpty,
      refresh.utf8.count <= 32768 else { throw JournalCognitoError.invalidToken }
    return JournalCognitoTokens(idToken: response.id_token, accessToken: response.access_token,
      refreshToken: refresh, userID: user, issuer: configuration.issuer, clientID: configuration.clientID,
      expiresAt: min(expiryID, expiryAccess, now.addingTimeInterval(TimeInterval(response.expires_in))))
  }
}
