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

enum JournalCognitoOAuth {
  static func url64(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
  static func data64(_ value: String) throws -> Data {
    guard !value.isEmpty, value.utf8.allSatisfy({
      (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
    }) else { throw JournalCognitoTokenValidator.failure(.base64Invalid) }
    let base = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    guard let data = Data(base64Encoded: base + String(repeating: "=", count: (4 - base.count % 4) % 4))
    else { throw JournalCognitoTokenValidator.failure(.base64Invalid) }
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
  static func failure(_ reason: JournalAccountDiagnostic.Reason) -> JournalCognitoFailure {
    JournalCognitoFailure(category: .invalidToken, detail: .init(source: .tokenValidation, reason: reason))
  }
  struct Key: Decodable {
    let kty: String; let kid: String; let alg: String?; let use: String?; let n: String; let e: String
  }
  struct Keys: Decodable { let keys: [Key] }
  let keys: Keys
  init(jwks: Data) throws {
    guard jwks.count <= 262144 else { throw Self.failure(.responseTooLarge) }
    keys = try JSONDecoder().decode(Keys.self, from: jwks)
  }
  private struct Header: Decodable {
    struct Fields: Decodable { let alg: String; let kid: String }
    private enum Keys: String, CodingKey { case crit }
    let fields: Fields
    init(from decoder: Decoder) throws {
      // Reject the presence of an unsupported critical extension, including null.
      guard !(try decoder.container(keyedBy: Keys.self)).contains(.crit) else {
        throw JournalCognitoTokenValidator.failure(.criticalHeaderUnsupported)
      }
      fields = try Fields(from: decoder)
    }
  }
  private struct Claims: Decodable {
    let iss: String; let token_use: String; let exp: Double; let iat: Double; let sub: String
    let aud: String?; let client_id: String?; let nonce: String?
  }

  private func claims(_ token: String) throws -> Claims {
    guard token.utf8.count <= 32768 else { throw Self.failure(.tokenTooLarge) }
    let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 3 else { throw Self.failure(.tokenSegmentsInvalid) }
    let header: Header
    do { header = try JSONDecoder().decode(Header.self, from: JournalCognitoOAuth.data64(parts[0])) }
    catch {
      if let failure = error as? JournalCognitoFailure { throw failure }
      throw JournalCognitoFailure(category: .invalidToken, detail: .init(source: .tokenHeader, reason: .responseShape,
        causes: JournalAccountDiagnostic.Cause.chain(error)))
    }
    guard header.fields.alg == "RS256" else { throw Self.failure(.algorithmUnsupported) }
    let matches = keys.keys.filter { $0.kid == header.fields.kid }
    guard !matches.isEmpty else { throw Self.failure(.signingKeyMissing) }
    guard matches.count == 1 else { throw Self.failure(.signingKeyAmbiguous) }
    let key = matches[0]
    guard key.kty == "RSA" else { throw Self.failure(.signingKeyTypeInvalid) }
    guard key.alg == nil || key.alg == "RS256" else { throw Self.failure(.signingKeyAlgorithmInvalid) }
    guard key.use == nil || key.use == "sig" else { throw Self.failure(.signingKeyUseInvalid) }
    let n = try JournalCognitoOAuth.data64(key.n), e = try JournalCognitoOAuth.data64(key.e)
    guard (256...1024).contains(n.count), (1...8).contains(e.count) else { throw Self.failure(.signingKeySizeInvalid) }
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
    var importError: Unmanaged<CFError>?
    guard let publicKey = SecKeyCreateWithData(der as CFData,
      [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, &importError)
    else {
      throw JournalCognitoFailure(category: .invalidToken,
        detail: .init(source: .tokenValidation, reason: .signingKeyImportFailed,
          causes: importError.map { JournalAccountDiagnostic.Cause.chain($0.takeRetainedValue() as Error) } ?? []))
    }
    var signatureError: Unmanaged<CFError>?
    guard SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256,
        Data((parts[0] + "." + parts[1]).utf8) as CFData,
        try JournalCognitoOAuth.data64(parts[2]) as CFData, &signatureError)
    else {
      throw JournalCognitoFailure(category: .invalidToken,
        detail: .init(source: .tokenValidation, reason: .signatureInvalid,
          causes: signatureError.map { JournalAccountDiagnostic.Cause.chain($0.takeRetainedValue() as Error) } ?? []))
    }
    do { return try JSONDecoder().decode(Claims.self, from: JournalCognitoOAuth.data64(parts[1])) }
    catch {
      if let failure = error as? JournalCognitoFailure { throw failure }
      throw JournalCognitoFailure(category: .invalidToken, detail: .init(source: .tokenClaims, reason: .responseShape,
        causes: JournalAccountDiagnostic.Cause.chain(error)))
    }
  }
  func validate(_ response: JournalCognitoTokenResponse, configuration: JournalCognitoConfiguration,
                nonce: String?, previous: JournalCognitoTokens?, now: Date) throws -> JournalCognitoTokens {
    let id = try claims(response.id_token), access = try claims(response.access_token)
    func expiry(_ claims: Claims, use: String) throws -> Date {
      guard claims.iss == configuration.issuer else {
        throw JournalCognitoFailure(category: .invalidToken, detail: .init(source: .tokenValidation, reason: .issuerMismatch))
      }
      guard claims.exp.isFinite, claims.exp > now.timeIntervalSince1970 else {
        throw JournalCognitoFailure(category: .invalidToken, detail: .init(source: .tokenValidation, reason: .tokenExpired))
      }
      guard claims.token_use == use else { throw Self.failure(.tokenUseMismatch) }
      guard claims.iat.isFinite, claims.iat <= now.timeIntervalSince1970 + 60
      else { throw Self.failure(.issuedAtInvalid) }
      return Date(timeIntervalSince1970: claims.exp)
    }
    let expiryID = try expiry(id, use: "id"), expiryAccess = try expiry(access, use: "access")
    guard id.aud == configuration.clientID, access.client_id == configuration.clientID else {
      throw JournalCognitoFailure(category: .invalidToken, detail: .init(source: .tokenValidation, reason: .audienceMismatch))
    }
    guard nonce == nil || id.nonce == nonce else {
      throw JournalCognitoFailure(category: .invalidToken, detail: .init(source: .tokenValidation, reason: .nonceMismatch))
    }
    guard let refresh = response.refresh_token ?? previous?.refreshToken, !refresh.isEmpty else {
      throw JournalCognitoFailure(category: .invalidToken, detail: .init(source: .tokenValidation, reason: .refreshTokenMissing))
    }
    guard !id.sub.isEmpty, id.sub.utf8.count <= 512 else { throw Self.failure(.subjectInvalid) }
    guard access.sub == id.sub else { throw Self.failure(.subjectMismatch) }
    guard previous == nil || previous?.userID == id.sub else { throw Self.failure(.accountMismatch) }
    guard response.token_type.lowercased() == "bearer" else { throw Self.failure(.tokenTypeInvalid) }
    guard response.expires_in > 0 else { throw Self.failure(.expiresInInvalid) }
    guard refresh.utf8.count <= 32768 else { throw Self.failure(.refreshTokenTooLarge) }
    return JournalCognitoTokens(idToken: response.id_token, accessToken: response.access_token,
      refreshToken: refresh, userID: id.sub, issuer: configuration.issuer, clientID: configuration.clientID,
      expiresAt: min(expiryID, expiryAccess, now.addingTimeInterval(TimeInterval(response.expires_in))))
  }
}
