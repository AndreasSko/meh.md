import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTP adapter for the loopback-only development sync service.
public struct LocalSyncTransport: SyncTransport, Sendable {
    public nonisolated let scope: String

    private let endpoint: URL
    private let workspace: String
    private let session: URLSession
    private let timeout: TimeInterval
    private let pageSize: Int
    private let protocolVersion: Int

    public init(
        baseURL: URL,
        workspace: String,
        session: URLSession = .shared,
        timeout: TimeInterval = 5,
        pageSize: Int = 100,
        protocolVersion: Int = 1
    ) {
        endpoint = baseURL
        self.workspace = workspace
        let legacyScope = baseURL.absoluteString.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        ) + "#" + workspace
        scope = protocolVersion == 1
            ? legacyScope
            : legacyScope + "#v\(protocolVersion)"
        self.session = session
        self.timeout = min(max(timeout, 0.25), 30)
        self.pageSize = min(max(pageSize, 1), 1_000)
        self.protocolVersion = protocolVersion
    }

    public func bootstrap(proposing record: SyncRecord) async throws
        -> SyncRecord {
        try validate(record, bootstrapping: true)
        let canonical: SyncRecord = try await send(
            path: "/v\(protocolVersion)/bootstrap",
            method: "POST",
            body: MutationRequest(scope: workspace, record: record),
            response: SyncRecord.self
        )
        try validate(canonical, bootstrapping: true)
        return canonical
    }

    public func publish(_ record: SyncRecord) async throws {
        try validate(record)
        let acknowledgement: EmptyResponse = try await send(
            path: "/v\(protocolVersion)/records",
            method: "POST",
            body: MutationRequest(scope: workspace, record: record),
            response: EmptyResponse.self
        )
        guard acknowledgement.stored else {
            throw SyncError.unavailable(
                "The sync service did not acknowledge durable storage."
            )
        }
    }

    public func fetch(after cursor: String?) async throws -> SyncPage {
        try validateProtocolVersion()
        var query = [
            URLQueryItem(name: "scope", value: workspace),
            URLQueryItem(name: "limit", value: String(pageSize)),
        ]
        if let cursor {
            query.append(URLQueryItem(name: "after", value: cursor))
        }
        let page: SyncPage = try await send(
            path: "/v\(protocolVersion)/records",
            method: "GET",
            query: query,
            response: SyncPage.self
        )
        do {
            for record in page.records {
                try validate(record)
            }
        } catch {
            throw SyncError.invalidRecord
        }
        return page
    }

    private func send<Response: Decodable>(
        path: String,
        method: String,
        query: [URLQueryItem] = [],
        response: Response.Type
    ) async throws -> Response {
        try await perform(path: path, method: method, query: query, body: nil)
    }

    private func send<Body: Encodable, Response: Decodable>(
        path: String,
        method: String,
        query: [URLQueryItem] = [],
        body: Body,
        response: Response.Type
    ) async throws -> Response {
        let encoded: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoded = try encoder.encode(body)
        } catch {
            throw SyncError.unavailable("Could not encode the sync request.")
        }
        return try await perform(
            path: path,
            method: method,
            query: query,
            body: encoded
        )
    }

    private func perform<Response: Decodable>(
        path: String,
        method: String,
        query: [URLQueryItem],
        body: Data?
    ) async throws -> Response {
        let url = try serviceURL(path: path, query: query)
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue(
                "application/json",
                forHTTPHeaderField: "Content-Type"
            )
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SyncError.unavailable(
                "The local sync service could not be reached: "
                    + error.localizedDescription
            )
        }

        guard data.count <= 32 * 1_024 * 1_024 else {
            throw SyncError.unavailable("The sync response was too large.")
        }
        guard let http = response as? HTTPURLResponse else {
            throw SyncError.unavailable("The sync service returned no HTTP status.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw decodeServiceError(data: data, status: http.statusCode)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw SyncError.unavailable("The sync service returned invalid JSON.")
        }
    }

    private func serviceURL(
        path: String,
        query: [URLQueryItem]
    ) throws -> URL {
        guard var components = URLComponents(
            url: endpoint,
            resolvingAgainstBaseURL: false
        ), components.scheme == "http",
           components.user == nil,
           components.password == nil,
           let host = components.host,
           ["localhost", "127.0.0.1", "::1"].contains(host.lowercased()) else {
            throw SyncError.unavailable(
                "The development sync service must use a loopback HTTP URL."
            )
        }
        components.fragment = nil
        components.query = nil
        components.path = components.path.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        ).isEmpty ? path : "/" + components.path.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        ) + path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else {
            throw SyncError.unavailable("The sync service URL is invalid.")
        }
        return url
    }

    private func decodeServiceError(data: Data, status: Int) -> SyncError {
        let envelope = try? JSONDecoder().decode(ErrorResponse.self, from: data)
        switch envelope?.error {
        case "invalid_cursor":
            return .invalidCursor
        case "invalid_record", "immutable_record_conflict",
            "invalid_protocol_version", "notebook_conflict",
            "bootstrap_required":
            return .invalidRecord
        default:
            let detail = envelope?.message ?? "HTTP \(status)"
            return .unavailable("The local sync service failed: \(detail)")
        }
    }

    private func validate(
        _ record: SyncRecord,
        bootstrapping: Bool = false
    ) throws {
        do {
            try validateProtocolVersion()
            guard record.protocolVersion == protocolVersion else {
                throw SyncError.invalidRecord
            }
            if bootstrapping && protocolVersion == 2 && record.kind != .catalog {
                throw SyncError.invalidRecord
            }
            try record.validate()
        } catch {
            throw SyncError.invalidRecord
        }
    }

    private func validateProtocolVersion() throws {
        guard protocolVersion == 1 || protocolVersion == 2 else {
            throw SyncError.invalidRecord
        }
    }
}

private struct MutationRequest: Encodable {
    let scope: String
    let record: SyncRecord
}

private struct EmptyResponse: Decodable {
    let stored: Bool
}

private struct ErrorResponse: Decodable {
    let error: String
    let message: String
}
