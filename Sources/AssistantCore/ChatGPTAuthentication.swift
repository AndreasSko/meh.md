import CryptoKit
import Foundation
import Security

public struct ChatGPTAccount: Codable, Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let email: String?

    public init(id: String, displayName: String, email: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.email = email
    }
}

public struct ChatGPTSignInAttempt: Sendable {
    public let authorizationURL: URL
    public let redirectURI: URL
    public let state: String
    let verifier: String
    let nonce: String
    let identifier: UUID
    let generation: UInt64
    let clientID: String?
}

public enum ChatGPTAuthenticationError: Error, LocalizedError, Equatable {
    case invalidRedirect, invalidCallback, cancelled, registrationIncomplete
    case invalidIDToken, planPermissionDenied, signInRequired, storageFailure
    case invalidResponse, requestFailed, sessionExpired, revocationUnconfirmed

    public var errorDescription: String? {
        switch self {
        case .invalidRedirect: "The local sign-in callback could not be prepared."
        case .invalidCallback: "The sign-in response did not match this attempt. Try again."
        case .cancelled: "Sign-in was cancelled."
        case .registrationIncomplete: "ChatGPT did not finish registering this app. Try again."
        case .invalidIDToken: "The ChatGPT account could not be verified. Try again."
        case .planPermissionDenied: "Allow this app to use your ChatGPT plan to continue."
        case .signInRequired: "Sign in with ChatGPT to continue."
        case .storageFailure: "ChatGPT credentials could not be saved securely."
        case .invalidResponse: "ChatGPT returned an unexpected sign-in response."
        case .requestFailed: "ChatGPT sign-in is temporarily unavailable. Try again."
        case .sessionExpired: "Your ChatGPT session ended. Sign in again."
        case .revocationUnconfirmed:
            "Signed out on this device. Remote sign-out could not be confirmed. " +
            "You can disconnect the app in ChatGPT Settings."
        }
    }
}

/// A public OAuth client using only the documented SIWC endpoints.
public actor ChatGPTAuthentication {
    private struct Registration: Codable, Sendable {
        var clientID: String
        var account: ChatGPTAccount?
    }

    private struct Credentials: Codable, Sendable {
        var accessToken: String
        var refreshToken: String?
        var idToken: String
        var scopes: Set<String>
        var expiresAt: Date
    }

    private struct SavedState: Codable, Sendable {
        var hostID: String
        var registration: Registration?
        var credentials: Credentials?
    }

    private struct TokenResponse: Decodable, Sendable {
        let access_token: String
        let refresh_token: String?
        let id_token: String?
        let token_type: String
        let expires_in: Double
        let scope: String?
    }

    private struct OAuthFailure: Decodable { let error: String }
    private let store: any ChatGPTCredentialStore
    private let session: URLSession
    private var saved: SavedState?
    private var generation: UInt64 = 0
    private var pending: UUID?
    private var signInIdentifier: UUID?
    private var refresh: (id: UUID, task: Task<String, Error>)?
    private static let resource = "https://api.openai.com/v1"
    private static let tokenURL = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    private static let scope = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"

    public init(store: any ChatGPTCredentialStore,
                session: URLSession = URLSession(configuration: .ephemeral)) {
        self.store = store
        self.session = session
    }

    public func account() async throws -> ChatGPTAccount? {
        let state = try load()
        return state.credentials == nil ? nil : state.registration?.account
    }

    public func beginSignIn(redirectURI: URL) async throws -> ChatGPTSignInAttempt {
        guard let redirect = URLComponents(url: redirectURI, resolvingAgainstBaseURL: false),
              redirect.scheme == "http", redirect.host == "127.0.0.1",
              let port = redirect.port, port > 0, port <= 65535,
              redirect.percentEncodedPath == "/auth/callback", redirect.query == nil,
              redirect.fragment == nil, redirect.user == nil, redirect.password == nil else {
            throw ChatGPTAuthenticationError.invalidRedirect
        }
        let record = try load()
        generation &+= 1
        refresh?.task.cancel(); refresh = nil
        let identifier = UUID()
        pending = identifier
        signInIdentifier = identifier
        let state = try randomSecret()
        let nonce = try randomSecret()
        let verifier = try randomSecret()
        var items: [URLQueryItem] = [
            .init(name: "client_id", value: record.registration?.clientID ?? "dynamic_agent_client"),
            .init(name: "ext_agent_host_id", value: record.hostID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI.absoluteString),
            .init(name: "scope", value: Self.scope),
            .init(name: "resource", value: Self.resource),
            .init(name: "state", value: state), .init(name: "nonce", value: nonce),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: ChatGPTIDTokenValidator.encode(Data(SHA256.hash(data: Data(verifier.utf8))))),
        ]
        if record.registration == nil {
            items.append(.init(name: "agent_name_hint", value: "meh.md"))
        } else if let hint = record.credentials?.idToken {
            items.append(.init(name: "id_token_hint", value: hint))
        }
        var url = URLComponents(string: "https://auth.openai.com/api/accounts/authorize")!
        url.queryItems = items
        return ChatGPTSignInAttempt(
            authorizationURL: url.url!, redirectURI: redirectURI, state: state,
            verifier: verifier, nonce: nonce, identifier: identifier,
            generation: generation, clientID: record.registration?.clientID
        )
    }

    public func cancelSignIn(attempt: ChatGPTSignInAttempt) {
        guard signInIdentifier == attempt.identifier,
              generation == attempt.generation else { return }
        pending = nil
        signInIdentifier = nil
        generation &+= 1
    }

    public func completeSignIn(
        callbackURL: URL, attempt: ChatGPTSignInAttempt
    ) async throws -> ChatGPTAccount {
        guard pending == attempt.identifier, generation == attempt.generation else {
            throw ChatGPTAuthenticationError.cancelled
        }
        defer {
            if signInIdentifier == attempt.identifier { signInIdentifier = nil }
        }
        pending = nil // An attempt can exchange a code at most once.
        guard let callback = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let expected = URLComponents(url: attempt.redirectURI, resolvingAgainstBaseURL: false),
              callback.scheme == expected.scheme, callback.host == expected.host,
              callback.port == expected.port, callback.percentEncodedPath == expected.percentEncodedPath,
              callback.user == nil, callback.password == nil, callback.fragment == nil,
              let query = callback.queryItems,
              Set(query.map(\.name)).count == query.count,
              query.first(where: { $0.name == "state" })?.value == attempt.state else {
            throw ChatGPTAuthenticationError.invalidCallback
        }
        if query.contains(where: { $0.name == "error" }) {
            throw ChatGPTAuthenticationError.cancelled
        }
        guard let code = query.first(where: { $0.name == "code" })?.value,
              !code.isEmpty, code.utf8.count <= 8192 else {
            throw ChatGPTAuthenticationError.invalidCallback
        }
        let returnedID = query.first(where: { $0.name == "client_id" })?.value
        let clientID: String
        if let existing = attempt.clientID {
            guard returnedID == nil || returnedID == existing else {
                throw ChatGPTAuthenticationError.invalidCallback
            }
            clientID = existing
        } else {
            guard let issued = returnedID, !issued.isEmpty,
                  issued != "dynamic_agent_client", issued.utf8.count <= 1024 else {
                throw ChatGPTAuthenticationError.registrationIncomplete
            }
            clientID = issued
            // Retain the issued registration even if code exchange fails.
            var record = try load()
            record.registration = Registration(clientID: issued, account: nil)
            try persist(record)
        }
        let token = try await tokens([
            "grant_type": "authorization_code", "client_id": clientID,
            "code": code, "code_verifier": attempt.verifier,
            "redirect_uri": attempt.redirectURI.absoluteString, "resource": Self.resource,
        ])
        guard let idToken = token.id_token else { throw ChatGPTAuthenticationError.invalidIDToken }
        let jwks = try await getJSON(URL(string: "https://auth.openai.com/.well-known/jwks.json")!)
        let identity = try ChatGPTIDTokenValidator.validate(
            idToken, clientID: clientID, nonce: attempt.nonce, jwks: jwks
        )
        try requireGeneration(attempt.generation)
        var record = try load()
        if let previous = record.registration?.account, previous.id != identity.subject {
            throw ChatGPTAuthenticationError.invalidIDToken
        }
        let scopes = Set((token.scope ?? "").split(separator: " ").map(String.init))
        let account = ChatGPTAccount(
            id: identity.subject, displayName: identity.name ?? identity.email ?? "ChatGPT",
            email: identity.email
        )
        record.registration = Registration(clientID: clientID, account: account)
        record.credentials = Credentials(
            accessToken: token.access_token, refreshToken: token.refresh_token,
            idToken: idToken, scopes: scopes,
            expiresAt: Date().addingTimeInterval(token.expires_in)
        )
        try Task.checkCancellation()
        try persist(record)
        return account
    }

    public func accessToken() async throws -> String {
        let record = try load()
        guard let credentials = record.credentials else { throw ChatGPTAuthenticationError.signInRequired }
        guard credentials.scopes.contains("chatgpt.tokens.use.direct") else {
            throw ChatGPTAuthenticationError.planPermissionDenied
        }
        if credentials.expiresAt.timeIntervalSinceNow > 60 { return credentials.accessToken }
        if let refresh {
            let version = generation
            let token = try await refresh.task.value
            try requireGeneration(version)
            return token
        }
        guard let registration = record.registration,
              let refreshToken = credentials.refreshToken else {
            throw ChatGPTAuthenticationError.signInRequired
        }
        let id = UUID()
        let version = generation
        let task = Task { try await self.renew(
            registration: registration, credentials: credentials,
            refreshToken: refreshToken, generation: version
        ) }
        refresh = (id, task)
        defer { if refresh?.id == id { refresh = nil } }
        let token = try await task.value
        try requireGeneration(version)
        return token
    }

    public func signOut() async throws {
        generation &+= 1; pending = nil; signInIdentifier = nil
        refresh?.task.cancel(); refresh = nil
        var record = try load()
        let previous = record
        record.credentials = nil
        try persist(record) // Clear locally before any network suspension.
        guard let refreshToken = previous.credentials?.refreshToken,
              let clientID = previous.registration?.clientID else { return }
        do {
            let discovery = try await getJSON(URL(string: "https://auth.openai.com/.well-known/openid-configuration")!)
            guard let object = try JSONSerialization.jsonObject(with: discovery) as? [String: Any],
                  let value = object["revocation_endpoint"] as? String,
                  let endpoint = URL(string: value), endpoint.scheme == "https",
                  endpoint.host == "auth.openai.com", endpoint.user == nil,
                  endpoint.password == nil, endpoint.fragment == nil else {
                throw ChatGPTAuthenticationError.revocationUnconfirmed
            }
            let (_, response) = try await session.data(for: formRequest(endpoint, [
                "token": refreshToken, "token_type_hint": "refresh_token", "client_id": clientID,
            ]), delegate: RejectRedirects())
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw ChatGPTAuthenticationError.revocationUnconfirmed
            }
        } catch {
            throw ChatGPTAuthenticationError.revocationUnconfirmed
        }
    }

    private func renew(
        registration: Registration, credentials: Credentials,
        refreshToken: String, generation version: UInt64
    ) async throws -> String {
        do {
            let token = try await tokens([
                "grant_type": "refresh_token", "client_id": registration.clientID,
                "refresh_token": refreshToken, "resource": Self.resource,
            ])
            var record = try load()
            try requireGeneration(version)
            var updated = credentials
            if let idToken = token.id_token {
                let jwks = try await getJSON(URL(string: "https://auth.openai.com/.well-known/jwks.json")!)
                let identity = try ChatGPTIDTokenValidator.validate(
                    idToken, clientID: registration.clientID, nonce: nil, jwks: jwks
                )
                guard identity.subject == registration.account?.id else {
                    throw ChatGPTAuthenticationError.invalidIDToken
                }
                updated.idToken = idToken
            }
            try requireGeneration(version)
            updated.accessToken = token.access_token
            updated.refreshToken = token.refresh_token ?? credentials.refreshToken
            updated.expiresAt = Date().addingTimeInterval(token.expires_in)
            if let scope = token.scope { updated.scopes = Set(scope.split(separator: " ").map(String.init)) }
            record.credentials = updated
            try Task.checkCancellation()
            try persist(record)
            guard updated.scopes.contains("chatgpt.tokens.use.direct") else {
                throw ChatGPTAuthenticationError.planPermissionDenied
            }
            return updated.accessToken
        } catch ChatGPTAuthenticationError.sessionExpired {
            try requireGeneration(version)
            var record = try load(); record.credentials = nil; try persist(record)
            throw ChatGPTAuthenticationError.sessionExpired
        }
    }

    private func load() throws -> SavedState {
        if let saved { return saved }
        if let data = try store.load() {
            guard let record = try? JSONDecoder().decode(SavedState.self, from: data),
                  record.hostID.hasPrefix("urn:uuid:") else {
                throw ChatGPTAuthenticationError.storageFailure
            }
            saved = record
            return record
        }
        let record = SavedState(hostID: "urn:uuid:" + UUID().uuidString.lowercased())
        try persist(record)
        return record
    }

    private func persist(_ record: SavedState) throws {
        try store.save(JSONEncoder().encode(record))
        saved = record
    }

    private func requireGeneration(_ version: UInt64) throws {
        guard version == generation else { throw ChatGPTAuthenticationError.cancelled }
    }

    private func randomSecret() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ChatGPTAuthenticationError.invalidResponse
        }
        return ChatGPTIDTokenValidator.encode(Data(bytes))
    }

    private func tokens(_ values: [String: String]) async throws -> TokenResponse {
        let (data, response) = try await session.data(
            for: formRequest(Self.tokenURL, values), delegate: RejectRedirects()
        )
        guard let http = response as? HTTPURLResponse else { throw ChatGPTAuthenticationError.invalidResponse }
        guard http.statusCode == 200 else {
            if let error = try? JSONDecoder().decode(OAuthFailure.self, from: data),
               ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
                "refresh_token_invalidated", "refresh_token_reused", "refresh_token_invalid"].contains(error.error),
               values["grant_type"] == "refresh_token" {
                throw ChatGPTAuthenticationError.sessionExpired
            }
            throw ChatGPTAuthenticationError.requestFailed
        }
        guard let result = try? JSONDecoder().decode(TokenResponse.self, from: data),
              !result.access_token.isEmpty, result.token_type.lowercased() == "bearer",
              result.expires_in.isFinite, result.expires_in > 0 else {
            throw ChatGPTAuthenticationError.invalidResponse
        }
        return result
    }

    private func getJSON(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request, delegate: RejectRedirects())
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 1_048_576 else {
            throw ChatGPTAuthenticationError.requestFailed
        }
        return data
    }

    private func formRequest(_ url: URL, _ values: [String: String]) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        request.httpBody = Data(values.sorted(by: { $0.key < $1.key }).map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=" +
            $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").utf8)
        return request
    }

    private final class RejectRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}
