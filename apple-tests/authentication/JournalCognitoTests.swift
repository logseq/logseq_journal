import Foundation
import Security

// Generates an independent RS256 issuer. All credentials below are synthetic.
@MainActor private final class Issuer {
  let key: SecKey
  let jwks: Data
  var now = Date(timeIntervalSince1970: 1_800_000_000)
  var stored: JournalCognitoTokens?
  var requests: [URLRequest] = []
  var authorization: URL?
  var callbackOverride: String?
  var browserError: Error?
  var tokenError: String?
  var status = 200
  var tokenHold: CheckedContinuation<Void, Never>?
  var holdTokens = false
  var browserHold: CheckedContinuation<URL, Error>?
  var holdBrowser = false
  var defect: String?
  var lifetime: Double = 3600
  var omitRefresh = false
  var cancellations = 0
  var saveHold: CheckedContinuation<Void, Never>?
  var holdSave = false
  let config = JournalCognitoConfiguration(domain: "auth.example.com", clientID: "public-client",
    userPoolID: "test-pool", region: "us-east-1", redirectURI: "logseqjournal://auth/callback")
  init() throws {
    key = SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, nil)!
    var bytes = Array(SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(key)!, nil)! as Data), index = 0
    func read() -> [UInt8] {
      index += 1; var count = Int(bytes[index]); index += 1
      if count > 127 {
        let width = count & 127; count = 0
        for _ in 0..<width { count = count * 256 + Int(bytes[index]); index += 1 }
      }
      let result = Array(bytes[index..<index+count]); index += count; return result
    }
    bytes = read(); index = 0
    var n = read(); let e = read(); if n.first == 0 { n.removeFirst() }
    jwks = try JSONSerialization.data(withJSONObject: ["keys": [["kty": "RSA", "kid": "test-key",
      "alg": "RS256", "use": "sig", "n": Self.url64(Data(n)), "e": Self.url64(Data(e))]]])
  }
  static func url64(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
  func query(_ url: URL) -> [String: String] {
    Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!
      .queryItems!.map { ($0.name, $0.value ?? "") })
  }
  func token(_ use: String) throws -> String {
    var claims: [String: Any] = ["iss": defect == "issuer" ? "https://evil.example" : config.issuer,
      "sub": "fixture-user", "exp": now.addingTimeInterval(lifetime).timeIntervalSince1970,
      "iat": now.timeIntervalSince1970, "token_use": use]
    if use == "id" {
      claims["aud"] = defect == "audience" ? "other" : config.clientID
      claims["nonce"] = defect == "nonce" ? "wrong" : query(authorization!)["nonce"]
    } else { claims["client_id"] = config.clientID }
    let input = Self.url64(try JSONSerialization.data(withJSONObject: ["alg": "RS256", "kid": "test-key"]))
      + "." + Self.url64(try JSONSerialization.data(withJSONObject: claims))
    var signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(input.utf8) as CFData, nil)! as Data
    if defect == "signature" { signature[0] ^= 1 }
    return input + "." + Self.url64(signature)
  }
  func callback() -> URL {
    URL(string: callbackOverride ?? "logseqjournal://auth/callback?state=\(query(authorization!)["state"]!)&code=synthetic-code")!
  }
  func session() -> JournalCognitoSession {
    JournalCognitoSession(configuration: config,
      storage: JournalCognitoStorage(load: { self.stored }, save: { value in
        if self.holdSave { await withCheckedContinuation { self.saveHold = $0 }; self.holdSave = false }
        self.stored = value
      }, clear: { self.stored = nil }),
      browser: JournalCognitoBrowser(authenticate: { url, _ in
        self.authorization = url
        if let error = self.browserError { throw error }
        if self.holdBrowser { return try await withCheckedThrowingContinuation { self.browserHold = $0 } }
        return self.callback()
      }, cancel: { self.cancellations += 1 }), transport: { request in
        self.requests.append(request)
        var data = Data()
        var status = 200
        if request.url!.path.hasSuffix("jwks.json") { data = self.jwks }
        else if request.url!.path == "/oauth2/token" {
          if self.holdTokens { await withCheckedContinuation { self.tokenHold = $0 } }
          status = self.status
          if let error = self.tokenError {
            data = try JSONSerialization.data(withJSONObject: ["error": error, "error_description": "never display server secrets"])
          } else {
            var object: [String: Any] = ["id_token": try self.token("id"), "access_token": try self.token("access"),
              "expires_in": Int(self.lifetime), "token_type": "Bearer"]
            if !self.omitRefresh { object["refresh_token"] = "synthetic-refresh+&=" }
            data = try JSONSerialization.data(withJSONObject: object)
          }
        }
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
      }, now: { self.now })
  }
  var tokenRequests: [URLRequest] { requests.filter { $0.url?.path == "/oauth2/token" } }
}
@main struct JournalCognitoTests {
  @MainActor static func rejects(_ operation: () async throws -> Void) async throws {
    do { try await operation(); throw NSError(domain: "Expected rejection", code: 99) }
    catch let error as NSError where error.domain == "Expected rejection" { throw error }
    catch { }
  }
  @MainActor static func main() async throws {
    let issuer = try Issuer(), session = issuer.session(); try await session.signIn()
    let q = issuer.query(issuer.authorization!)
    precondition(q["response_type"] == "code" && q["code_challenge_method"] == "S256" && q["scope"] == "openid")
    precondition(q["state"]!.count >= 32 && q["nonce"]!.count >= 32)
    let body = String(data: issuer.tokenRequests[0].httpBody!, encoding: .utf8)!
    precondition(body.contains("code_verifier=") && !body.contains("client_secret") && !body.contains("password"))
    let user = try await session.currentUserID(), id = try await session.freshIDToken()
    precondition(user == "fixture-user" && id == issuer.stored!.idToken && issuer.tokenRequests.count == 1)
    precondition(JournalCognitoOAuth.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    print("PASS code/PKCE/state/nonce, signed identity and cached ID token")
    for callback in ["other://auth/callback", "logseqjournal://other/callback", "logseqjournal://auth/wrong",
      "logseqjournal://auth/callback?state=wrong&code=x", "logseqjournal://auth/callback?code=x",
      "logseqjournal://auth/callback?state=x&state=x&code=y", "logseqjournal://auth/callback#code=x",
      "logseqjournal://user@auth/callback?code=x", "logseqjournal://auth:123/callback?code=x"] {
      let f = try Issuer(); f.callbackOverride = callback; let s = f.session()
      try await rejects { try await s.signIn() }; precondition(f.tokenRequests.isEmpty && f.stored == nil)
    }
    for mode in ["cancel", "error", "expire", "replay", "signout", "duplicate", "mixed"] {
      let f = try Issuer(); f.holdBrowser = true; let s = f.session()
      let old = Task { try await s.signIn() }; while f.browserHold == nil { await Task.yield() }
      let oldCallback = f.callback(), state = f.query(f.authorization!)["state"]!
      if mode == "cancel" || mode == "replay" { s.cancelSignIn() }
      if mode == "signout" { try await s.signOut() }
      if mode == "expire" { f.now = f.now.addingTimeInterval(301) }
      var callback = oldCallback
      if mode == "error" { callback = URL(string: "logseqjournal://auth/callback?state=\(state)&error=access_denied")! }
      if mode == "duplicate" { callback = URL(string: "logseqjournal://auth/callback?state=\(state)&code=x&code=y")! }
      if mode == "mixed" { callback = URL(string: "logseqjournal://auth/callback?state=\(state)&code=x&error=access_denied")! }
      f.browserHold!.resume(returning: callback); try await rejects { try await old.value }
      precondition(f.stored == nil && f.tokenRequests.isEmpty); f.holdBrowser = false
      if mode == "replay" { f.callbackOverride = oldCallback.absoluteString; try await rejects { try await s.signIn() } }
      else { try await s.signIn(); precondition(f.stored != nil) }
    }
    print("PASS callback mismatch, duplicate/mixed parameters, cancel/error/expiry/replay/sign-out and retry")
    for mode in ["nonce", "audience", "issuer", "signature", "expired", "refresh"] {
      let f = try Issuer(); f.defect = mode
      if mode == "expired" { f.lifetime = -1 }; if mode == "refresh" { f.omitRefresh = true }
      let s = f.session(); try await rejects { try await s.signIn() }; precondition(f.stored == nil)
    }
    print("PASS invalid signature/issuer/audience/nonce/expiry/incomplete tokens")
    let restored = issuer.session(); let restoredUser = try await restored.currentUserID(); precondition(restoredUser == user)
    issuer.now = issuer.now.addingTimeInterval(3550); issuer.holdTokens = true; issuer.omitRefresh = true
    let first = Task { try await restored.freshIDToken() }; while issuer.tokenHold == nil { await Task.yield() }
    let second = Task { try await restored.freshIDToken() }; for _ in 0..<10 { await Task.yield() }
    precondition(issuer.tokenRequests.count == 2); issuer.tokenHold!.resume()
    let a = try await first.value, b = try await second.value
    precondition(a == b && issuer.stored!.refreshToken == "synthetic-refresh+&=")
    precondition(String(data: issuer.tokenRequests.last!.httpBody!, encoding: .utf8)!.contains("%2B%26%3D"))
    print("PASS cold restore, singleflight concurrent refresh, retained token and form escaping")
    issuer.now = issuer.now.addingTimeInterval(3550); issuer.holdTokens = false
    issuer.status = 503; issuer.tokenError = "server_error"
    try await rejects { _ = try await restored.freshIDToken() }; precondition(issuer.stored != nil)
    issuer.status = 200; issuer.tokenError = nil; _ = try await restored.freshIDToken()
    issuer.now = issuer.now.addingTimeInterval(3550); issuer.status = 400; issuer.tokenError = "invalid_grant"
    try await rejects { _ = try await restored.freshIDToken() }; precondition(issuer.stored == nil)
    let expiredUser = try await restored.currentUserID(); precondition(expiredUser == nil)
    print("PASS transient refresh retry/preservation and invalid-grant expiry")
    let retired = try Issuer(), rs = retired.session(); try await rs.signIn()
    retired.now = retired.now.addingTimeInterval(3550); retired.holdTokens = true
    let late = Task { try await rs.freshIDToken() }; while retired.tokenHold == nil { await Task.yield() }
    try await rs.signOut(); retired.tokenHold!.resume(); try await rejects { _ = try await late.value }
    let signedOut = try await rs.currentUserID(); precondition(retired.stored == nil && signedOut == nil)
    print("PASS sign-out cleanup and late refresh isolation")
    let saving = try Issuer(), ss = saving.session(); try await ss.signIn()
    let previous = saving.stored!.idToken; saving.holdSave = true
    let cold = saving.session()
    let cancelledSave = Task { try await cold.signIn() }
    while saving.saveHold == nil { await Task.yield() }
    cold.cancelSignIn(); saving.saveHold!.resume()
    try await rejects { try await cancelledSave.value }
    precondition(saving.stored!.idToken == previous)
    print("PASS cancellation during secure save preserves previous account")
  }
}
