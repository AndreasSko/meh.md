import CryptoKit
import Foundation
import Security
import Synchronization
import Testing
@testable import AssistantCore

@Suite(.serialized)
struct ChatGPTAuthenticationTests {
    private let redirect = URL(string: "http://127.0.0.1:54321/auth/callback")!

    @Test func authorizationUsesPublicRegistrationAndPersistentDeviceID() async throws {
        let store = MemoryCredentials()
        let auth = ChatGPTAuthentication(store: store, session: mockSession())
        let first = try await auth.beginSignIn(redirectURI: redirect)
        let second = try await ChatGPTAuthentication(store: store, session: mockSession())
            .beginSignIn(redirectURI: redirect)
        let query = parameters(first.authorizationURL)
        #expect(query["client_id"] == "dynamic_agent_client")
        #expect(query["agent_name_hint"] == "meh.md")
        #expect(query["resource"] == "https://api.openai.com/v1")
        #expect(query["redirect_uri"] == redirect.absoluteString)
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["code_challenge"] == ChatGPTIDTokenValidator.encode(
            Data(SHA256.hash(data: Data(first.verifier.utf8)))
        ))
        #expect(query["ext_agent_host_id"] == parameters(second.authorizationURL)["ext_agent_host_id"])
        #expect(query["ext_agent_host_id"]?.hasPrefix("urn:uuid:") == true)
        #expect(first.state != second.state)
        #expect(first.nonce != second.nonce)
        #expect(first.verifier.utf8.count >= 43)
    }

    @Test func staleCancellationDoesNotInvalidateReplacementSignIn() async throws {
        let auth = ChatGPTAuthentication(store: MemoryCredentials(), session: mockSession())
        let oldAttempt = try await auth.beginSignIn(redirectURI: redirect)
        let replacement = try await auth.beginSignIn(redirectURI: redirect)
        let fixture = try IdentityFixture(nonce: replacement.nonce)
        MockOAuthProtocol.handler.withLock { handler in
            handler = { request in
                request.url?.path == "/.well-known/jwks.json" ?
                    .init(data: fixture.jwks) : fixture.tokens()
            }
        }
        await auth.cancelSignIn(attempt: oldAttempt)
        await #expect(throws: ChatGPTAuthenticationError.cancelled) {
            try await auth.completeSignIn(callbackURL: callback(oldAttempt), attempt: oldAttempt)
        }
        #expect(try await auth.completeSignIn(callbackURL: callback(replacement),
                                             attempt: replacement).id == "fictional-account")
        let current = try await auth.beginSignIn(redirectURI: redirect)
        await auth.cancelSignIn(attempt: current)
        await #expect(throws: ChatGPTAuthenticationError.cancelled) {
            try await auth.completeSignIn(callbackURL: callback(current), attempt: current)
        }
    }

    @Test func scopedCancellationInvalidatesItsSuspendedExchange() async throws {
        let auth = ChatGPTAuthentication(store: MemoryCredentials(), session: mockSession())
        let attempt = try await auth.beginSignIn(redirectURI: redirect)
        let fixture = try IdentityFixture(nonce: attempt.nonce)
        let entered = Mutex(false)
        MockOAuthProtocol.handler.withLock { handler in
            handler = { request in
                if request.url?.path == "/.well-known/jwks.json" { return .init(data: fixture.jwks) }
                entered.withLock { $0 = true }
                return fixture.tokens(delay: 0.08)
            }
        }
        let exchange = Task { try await auth.completeSignIn(callbackURL: callback(attempt), attempt: attempt) }
        let deadline = Date().addingTimeInterval(5)
        while !entered.withLock({ $0 }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(entered.withLock { $0 })
        await auth.cancelSignIn(attempt: attempt)
        await #expect(throws: ChatGPTAuthenticationError.cancelled) { try await exchange.value }
        #expect(try await auth.account() == nil)
    }

    @Test func callbackValidationPreventsAnyTokenExchange() async throws {
        let calls = Mutex(0)
        MockOAuthProtocol.handler.withLock { handler in
            handler = { _ in calls.withLock { $0 += 1 }; return MockResponse(status: 500) }
        }
        for badRedirect in ["http://localhost:54321/auth/callback", "meh://auth/callback",
                            "http://127.0.0.1:54321/callback"] {
            let auth = ChatGPTAuthentication(store: MemoryCredentials(), session: mockSession())
            await #expect(throws: ChatGPTAuthenticationError.invalidRedirect) {
                try await auth.beginSignIn(redirectURI: URL(string: badRedirect)!)
            }
        }
        for mutation in ["state", "path", "duplicate", "port", "fragment"] {
            let auth = ChatGPTAuthentication(store: MemoryCredentials(), session: mockSession())
            let attempt = try await auth.beginSignIn(redirectURI: redirect)
            var url = URLComponents(url: callback(attempt), resolvingAgainstBaseURL: false)!
            switch mutation {
            case "state": url.queryItems?[0].value = "unrelated"
            case "path": url.path = "/callback"
            case "port": url.port = 54322
            case "fragment": url.fragment = "injected"
            default: url.queryItems?.append(.init(name: "code", value: "duplicate"))
            }
            await #expect(throws: ChatGPTAuthenticationError.invalidCallback) {
                try await auth.completeSignIn(callbackURL: url.url!, attempt: attempt)
            }
        }
        #expect(calls.withLock { $0 } == 0)
    }

    @Test func signedIdentityAndIssuedClientSurviveRestartAndSignOut() async throws {
        let store = MemoryCredentials()
        let auth = ChatGPTAuthentication(store: store, session: mockSession())
        let attempt = try await auth.beginSignIn(redirectURI: redirect)
        let fixture = try IdentityFixture(nonce: attempt.nonce)
        let exchanged = Mutex<[String: String]>([:])
        MockOAuthProtocol.handler.withLock { handler in
            handler = { request in
                if request.url?.path == "/api/accounts/oauth/token" {
                    exchanged.withLock { $0 = form(request) }
                    return fixture.tokens()
                }
                if request.url?.path == "/.well-known/jwks.json" { return .init(data: fixture.jwks) }
                if request.url?.path == "/.well-known/openid-configuration" {
                    return .init(data: Data(#"{"revocation_endpoint":"https://auth.openai.com/revoke"}"#.utf8))
                }
                return .init(status: 200)
            }
        }
        let account = try await auth.completeSignIn(callbackURL: callback(attempt), attempt: attempt)
        #expect(account.id == "fictional-account")
        #expect(account.displayName == "Fictional User")
        #expect(exchanged.withLock { $0["client_id"] } == "oaiapp_fixture")
        #expect(exchanged.withLock { $0["code_verifier"] } == attempt.verifier)
        #expect(exchanged.withLock { $0["redirect_uri"] } == redirect.absoluteString)
        let restarted = ChatGPTAuthentication(store: store, session: mockSession())
        #expect(try await restarted.account() == account)
        let returning = try await restarted.beginSignIn(redirectURI: redirect)
        #expect(parameters(returning.authorizationURL)["client_id"] == "oaiapp_fixture")
        #expect(parameters(returning.authorizationURL)["agent_name_hint"] == nil)
        #expect(parameters(returning.authorizationURL)["id_token_hint"] == fixture.token)
        try await restarted.signOut()
        #expect(try await restarted.account() == nil)
        let afterSignOut = try await restarted.beginSignIn(redirectURI: redirect)
        #expect(parameters(afterSignOut.authorizationURL)["client_id"] == "oaiapp_fixture")
        #expect(parameters(afterSignOut.authorizationURL)["id_token_hint"] == nil)
        await #expect(throws: ChatGPTAuthenticationError.cancelled) {
            try await auth.completeSignIn(callbackURL: callback(attempt), attempt: attempt)
        }
    }

    @Test func tokenValidatorRejectsSignatureIssuerAudienceExpiryAndNonce() throws {
        let valid = try IdentityFixture(nonce: "nonce")
        #expect(try ChatGPTIDTokenValidator.validate(valid.token, clientID: "oaiapp_fixture",
            nonce: "nonce", jwks: valid.jwks).subject == "fictional-account")
        let invalidClaims: [[String: any Sendable]] = [
            ["iss": "https://untrusted.example"], ["aud": "other-client"], ["nonce": "different"],
            ["azp": "other-client"], ["nbf": "malformed"],
            ["nbf": Date().addingTimeInterval(3600).timeIntervalSince1970],
        ]
        for changes in invalidClaims {
            let fixture = try IdentityFixture(nonce: "nonce", overrides: changes)
            #expect(throws: ChatGPTAuthenticationError.invalidIDToken) {
                try ChatGPTIDTokenValidator.validate(fixture.token, clientID: "oaiapp_fixture",
                    nonce: "nonce", jwks: fixture.jwks)
            }
        }
        #expect(throws: ChatGPTAuthenticationError.invalidIDToken) {
            try ChatGPTIDTokenValidator.validate(valid.token, clientID: "oaiapp_fixture",
                nonce: "nonce", jwks: valid.jwks, now: Date().addingTimeInterval(7200))
        }
        let other = try IdentityFixture(nonce: "nonce")
        #expect(throws: ChatGPTAuthenticationError.invalidIDToken) {
            try ChatGPTIDTokenValidator.validate(valid.token, clientID: "oaiapp_fixture",
                nonce: "nonce", jwks: other.jwks)
        }
        let pieces = valid.token.split(separator: ".")
        let unsigned = ChatGPTIDTokenValidator.encode(Data(#"{"alg":"none","kid":"fixture"}"#.utf8)) +
            ".\(pieces[1]).\(pieces[2])"
        #expect(throws: ChatGPTAuthenticationError.invalidIDToken) {
            try ChatGPTIDTokenValidator.validate(unsigned, clientID: "oaiapp_fixture",
                nonce: "nonce", jwks: valid.jwks)
        }
    }

    @Test func validatesRS256WithSyntheticRSAJWKS() throws {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecAttrIsPermanent as String: false,
        ]
        let privateKey = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let publicKey = try #require(SecKeyCopyPublicKey(privateKey))
        let external = try #require(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
        var outerOffset = 0
        let sequence = try #require(readDER(external, offset: &outerOffset))
        var offset = 0
        let modulus = try #require(readDER(sequence, offset: &offset))
        let exponent = try #require(readDER(sequence, offset: &offset))
        let jwks = try JSONSerialization.data(withJSONObject: ["keys": [[
            "kid": "rsa-fixture", "alg": "RS256", "kty": "RSA", "use": "sig",
            "n": ChatGPTIDTokenValidator.encode(Data(modulus.drop(while: { $0 == 0 }))),
            "e": ChatGPTIDTokenValidator.encode(Data(exponent.drop(while: { $0 == 0 }))),
        ]]])
        let fixture = try IdentityFixture(nonce: "nonce")
        let payload = fixture.token.split(separator: ".")[1]
        let header = ChatGPTIDTokenValidator.encode(Data(#"{"alg":"RS256","kid":"rsa-fixture"}"#.utf8))
        let message = "\(header).\(payload)"
        let signature = try #require(SecKeyCreateSignature(
            privateKey, .rsaSignatureMessagePKCS1v15SHA256, Data(message.utf8) as CFData, nil
        )) as Data
        let token = message + "." + ChatGPTIDTokenValidator.encode(signature)
        #expect(try ChatGPTIDTokenValidator.validate(token, clientID: "oaiapp_fixture",
            nonce: "nonce", jwks: jwks).subject == "fictional-account")
        var invalid = signature
        invalid[0] ^= 1
        #expect(throws: ChatGPTAuthenticationError.invalidIDToken) {
            try ChatGPTIDTokenValidator.validate(message + "." + ChatGPTIDTokenValidator.encode(invalid),
                clientID: "oaiapp_fixture", nonce: "nonce", jwks: jwks)
        }
    }

    @Test func concurrentRefreshIsSingleFlightAndRotatesPersistedTokens() async throws {
        let store = MemoryCredentials()
        let auth = ChatGPTAuthentication(store: store, session: mockSession())
        let attempt = try await auth.beginSignIn(redirectURI: redirect)
        let fixture = try IdentityFixture(nonce: attempt.nonce)
        let refreshCount = Mutex(0)
        MockOAuthProtocol.handler.withLock { handler in
            handler = { request in
                if request.url?.path == "/.well-known/jwks.json" { return .init(data: fixture.jwks) }
                if form(request)["grant_type"] == "refresh_token" {
                    refreshCount.withLock { $0 += 1 }
                    return .init(data: Data(#"{"access_token":"rotated-access","refresh_token":"rotated-refresh","token_type":"Bearer","expires_in":3600}"#.utf8), delay: 0.05)
                }
                return fixture.tokens(expiry: 1)
            }
        }
        _ = try await auth.completeSignIn(callbackURL: callback(attempt), attempt: attempt)
        async let first = auth.accessToken()
        async let second = auth.accessToken()
        let pair = try await (first, second)
        #expect(pair.0 == "rotated-access" && pair.1 == "rotated-access")
        #expect(refreshCount.withLock { $0 } == 1)
        let data = try #require(try store.load())
        let record = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let credentials = try #require(record["credentials"] as? [String: Any])
        #expect(credentials["refreshToken"] as? String == "rotated-refresh")
        #expect(try await ChatGPTAuthentication(store: store, session: mockSession()).accessToken() == "rotated-access")
    }

    @Test func refreshPersistsRotationEvenWhenPlanPermissionIsRemoved() async throws {
        let store = MemoryCredentials()
        let auth = ChatGPTAuthentication(store: store, session: mockSession())
        let attempt = try await auth.beginSignIn(redirectURI: redirect)
        let fixture = try IdentityFixture(nonce: attempt.nonce)
        MockOAuthProtocol.handler.withLock { handler in
            handler = { request in
                if request.url?.path == "/.well-known/jwks.json" { return .init(data: fixture.jwks) }
                if form(request)["grant_type"] == "refresh_token" {
                    return .init(data: Data(#"{"access_token":"rotated-access","refresh_token":"rotated-refresh","token_type":"Bearer","expires_in":3600,"scope":"openid profile"}"#.utf8))
                }
                return fixture.tokens(expiry: 1)
            }
        }
        _ = try await auth.completeSignIn(callbackURL: callback(attempt), attempt: attempt)
        await #expect(throws: ChatGPTAuthenticationError.planPermissionDenied) {
            try await auth.accessToken()
        }
        let data = try #require(try store.load())
        let record = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let credentials = try #require(record["credentials"] as? [String: Any])
        #expect(credentials["refreshToken"] as? String == "rotated-refresh")
        #expect(try await auth.account()?.id == "fictional-account")
    }

    @Test func signOutInvalidatesLateExchangeAndClearsBeforeNetworkFailure() async throws {
        let store = MemoryCredentials()
        let auth = ChatGPTAuthentication(store: store, session: mockSession())
        let attempt = try await auth.beginSignIn(redirectURI: redirect)
        let fixture = try IdentityFixture(nonce: attempt.nonce)
        let entered = Mutex(false)
        MockOAuthProtocol.handler.withLock { handler in
            handler = { request in
                if request.url?.path == "/.well-known/jwks.json" { return .init(data: fixture.jwks) }
                entered.withLock { $0 = true }
                return fixture.tokens(delay: 0.08)
            }
        }
        let exchange = Task { try await auth.completeSignIn(callbackURL: callback(attempt), attempt: attempt) }
        let deadline = Date().addingTimeInterval(5)
        while !entered.withLock({ $0 }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(entered.withLock { $0 })
        try await auth.signOut()
        await #expect(throws: ChatGPTAuthenticationError.cancelled) { try await exchange.value }
        #expect(try await auth.account() == nil)
        // Reconnect, then make the revocation discovery fail.
        let fresh = try await auth.beginSignIn(redirectURI: redirect)
        let next = try IdentityFixture(nonce: fresh.nonce)
        MockOAuthProtocol.handler.withLock { handler in
            handler = { request in
                if request.url?.path == "/.well-known/jwks.json" { return .init(data: next.jwks) }
                if request.url?.path == "/.well-known/openid-configuration" { return .init(status: 503) }
                return next.tokens()
            }
        }
        _ = try await auth.completeSignIn(callbackURL: callback(fresh), attempt: fresh)
        await #expect(throws: ChatGPTAuthenticationError.revocationUnconfirmed) { try await auth.signOut() }
        #expect(try await auth.account() == nil)
        await #expect(throws: ChatGPTAuthenticationError.signInRequired) { try await auth.accessToken() }
    }

    @Test func declinedPlanPermissionRetainsIdentityWithoutInferenceAccess() async throws {
        let auth = ChatGPTAuthentication(store: MemoryCredentials(), session: mockSession())
        let attempt = try await auth.beginSignIn(redirectURI: redirect)
        let fixture = try IdentityFixture(nonce: attempt.nonce)
        MockOAuthProtocol.handler.withLock { handler in
            handler = { request in
                request.url?.path == "/.well-known/jwks.json" ? .init(data: fixture.jwks) :
                    fixture.tokens(scope: "openid profile email")
            }
        }
        _ = try await auth.completeSignIn(callbackURL: callback(attempt), attempt: attempt)
        #expect(try await auth.account()?.id == "fictional-account")
        await #expect(throws: ChatGPTAuthenticationError.planPermissionDenied) { try await auth.accessToken() }
    }

    @Test func expiredRefreshClearsSessionButKeepsRegistration() async throws {
        let auth = ChatGPTAuthentication(store: MemoryCredentials(), session: mockSession())
        let attempt = try await auth.beginSignIn(redirectURI: redirect)
        let fixture = try IdentityFixture(nonce: attempt.nonce)
        MockOAuthProtocol.handler.withLock { handler in
            handler = { request in
                if request.url?.path == "/.well-known/jwks.json" { return .init(data: fixture.jwks) }
                if form(request)["grant_type"] == "refresh_token" {
                    return .init(status: 400, data: Data(#"{"error":"invalid_grant"}"#.utf8))
                }
                return fixture.tokens(expiry: 1)
            }
        }
        _ = try await auth.completeSignIn(callbackURL: callback(attempt), attempt: attempt)
        await #expect(throws: ChatGPTAuthenticationError.sessionExpired) { try await auth.accessToken() }
        #expect(try await auth.account() == nil)
        #expect(parameters(try await auth.beginSignIn(redirectURI: redirect).authorizationURL)["client_id"] == "oaiapp_fixture")
    }

    private func callback(_ attempt: ChatGPTSignInAttempt) -> URL {
        var url = URLComponents(url: attempt.redirectURI, resolvingAgainstBaseURL: false)!
        url.queryItems = [.init(name: "state", value: attempt.state),
                          .init(name: "code", value: "fictional-code"),
                          .init(name: "client_id", value: "oaiapp_fixture")]
        return url.url!
    }
}

private final class MemoryCredentials: ChatGPTCredentialStore, Sendable {
    private let value = Mutex<Data?>(nil)
    func load() throws -> Data? { value.withLock { $0 } }
    func save(_ data: Data) throws { value.withLock { $0 = data } }
}

private struct MockResponse: Sendable {
    var status = 200
    var data = Data()
    var delay: TimeInterval = 0
}

private final class MockOAuthProtocol: URLProtocol, @unchecked Sendable {
    static let handler = Mutex<(@Sendable (URLRequest) throws -> MockResponse)?>(nil)
    private let stopped = Mutex(false)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let response = try Self.handler.withLock { try $0?(request) } ?? .init(status: 500)
            DispatchQueue.global().asyncAfter(deadline: .now() + response.delay) { [self] in
                guard !stopped.withLock({ $0 }) else { return }
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!,
                    statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: nil)!,
                    cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: response.data)
                client?.urlProtocolDidFinishLoading(self)
            }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { stopped.withLock { $0 = true } }
}

private func mockSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockOAuthProtocol.self]
    return URLSession(configuration: configuration)
}

private func parameters(_ url: URL) -> [String: String] {
    Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
        .compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { _, new in new })
}

private func form(_ request: URLRequest) -> [String: String] {
    var data = request.httpBody ?? Data()
    if data.isEmpty, let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
    guard let value = String(data: data, encoding: .utf8) else { return [:] }
    return parameters(URL(string: "https://fixture.invalid/?" + value)!)
}

private func readDER(_ data: Data, offset: inout Int) -> Data? {
    guard offset + 2 <= data.count else { return nil }
    offset += 1
    var length = Int(data[offset]); offset += 1
    if length & 0x80 != 0 {
        let digits = length & 0x7f
        guard digits > 0, digits <= 4, offset + digits <= data.count else { return nil }
        length = 0
        for _ in 0..<digits { length = length << 8 | Int(data[offset]); offset += 1 }
    }
    guard offset + length <= data.count else { return nil }
    defer { offset += length }
    return data.subdata(in: offset..<(offset + length))
}

private struct IdentityFixture: Sendable {
    let token: String
    let jwks: Data
    init(nonce: String, overrides: [String: any Sendable] = [:]) throws {
        let key = P256.Signing.PrivateKey()
        let publicKey = key.publicKey.x963Representation
        jwks = try JSONSerialization.data(withJSONObject: ["keys": [[
            "kid": "fixture", "alg": "ES256", "kty": "EC", "crv": "P-256", "use": "sig",
            "x": ChatGPTIDTokenValidator.encode(publicKey.subdata(in: 1..<33)),
            "y": ChatGPTIDTokenValidator.encode(publicKey.subdata(in: 33..<65)),
        ]]])
        var claims: [String: Any] = [
            "iss": "https://auth.openai.com", "sub": "fictional-account",
            "aud": "oaiapp_fixture", "nonce": nonce,
            "exp": Date().addingTimeInterval(3600).timeIntervalSince1970,
            "name": "Fictional User", "email": "fictional@example.invalid",
        ]
        for (name, value) in overrides { claims[name] = value }
        let header = ChatGPTIDTokenValidator.encode(try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": "fixture"]))
        let payload = ChatGPTIDTokenValidator.encode(try JSONSerialization.data(withJSONObject: claims))
        let input = header + "." + payload
        token = input + "." + ChatGPTIDTokenValidator.encode(try key.signature(for: Data(input.utf8)).rawRepresentation)
    }
    func tokens(expiry: Double = 3600, scope: String = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct", delay: TimeInterval = 0) -> MockResponse {
        .init(data: try! JSONSerialization.data(withJSONObject: [
            "access_token": "fictional-access", "refresh_token": "fictional-refresh",
            "id_token": token, "token_type": "Bearer", "expires_in": expiry, "scope": scope,
        ]), delay: delay)
    }
}
