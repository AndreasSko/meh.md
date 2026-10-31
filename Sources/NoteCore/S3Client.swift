import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where notes are stored on an S3-compatible service. Credentials are kept
/// separately, so this value can be saved in preferences and logged.
public struct S3SyncConfiguration: Codable, Equatable, Sendable {
    public var endpoint: String
    public var region: String
    public var bucket: String
    public var prefix: String

    public init(endpoint: String, region: String, bucket: String, prefix: String = "") {
        self.endpoint = endpoint
        self.region = region
        self.bucket = bucket
        self.prefix = prefix
    }

    /// Identifies the bucket and folder on every device, never a credential.
    /// Bucket names are global on AWS, so its regional endpoints share one.
    public var scope: String {
        let location = isAWS ? "aws" : (endpointURL.flatMap(S3Signer.hostHeader) ?? endpoint)
        return "s3://\(location)/\(bucket)/\(normalizedPrefix)"
    }

    public func validate() throws {
        guard let url = endpointURL, let host = url.host(percentEncoded: false),
              !host.isEmpty, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
        else {
            throw S3SyncTransportError.invalidConfiguration(
                "Enter the server address, for example https://s3.eu-central-1.amazonaws.com."
            )
        }
        switch url.scheme {
        case "https": break
        case "http" where Self.isLocalNetwork(host): break
        default:
            throw S3SyncTransportError.invalidConfiguration(
                "Use an https address. Plain http only works on your local network."
            )
        }
        guard region.range(of: "^[a-z0-9-]{1,32}$", options: .regularExpression) != nil else {
            throw S3SyncTransportError.invalidConfiguration(
                "Enter a region such as us-east-1."
            )
        }
        guard bucket.range(
            of: "^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", options: .regularExpression
        ) != nil else {
            throw S3SyncTransportError.invalidConfiguration(
                "Bucket names use 3 to 63 lowercase letters, numbers, dots, and hyphens."
            )
        }
        let segments = normalizedPrefix.split(separator: "/", omittingEmptySubsequences: false)
        guard normalizedPrefix.count <= 200,
              normalizedPrefix.isEmpty || segments.allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".."
                      && $0.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
              }) else {
            throw S3SyncTransportError.invalidConfiguration(
                "The folder may use letters, numbers, dots, hyphens, underscores, and slashes."
            )
        }
    }

    /// Plain http is only allowed where App Transport Security permits it.
    public var usesUnencryptedConnection: Bool { endpointURL?.scheme == "http" }

    var normalizedPrefix: String {
        prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }

    var endpointURL: URL? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed)
    }

    var isAWS: Bool {
        endpointURL?.host(percentEncoded: false)?.lowercased().hasSuffix(".amazonaws.com") == true
    }

    /// AWS prefers virtual-hosted URLs. Other services, and bucket names
    /// with dots that break TLS wildcards, use path-style URLs.
    func url(forKey key: String, query: [(String, String)] = []) throws -> URL {
        try validate()
        guard var components = URLComponents(url: endpointURL!, resolvingAgainstBaseURL: false)
        else { throw S3SyncTransportError.invalidConfiguration("The server address is invalid.") }
        let encodedKey = S3Signer.encode(key, keepSlash: true)
        if isAWS && !bucket.contains(".") {
            components.host = bucket + "." + (components.host ?? "")
            components.percentEncodedPath = "/" + encodedKey
        } else {
            components.percentEncodedPath = "/" + bucket + (key.isEmpty ? "" : "/" + encodedKey)
        }
        let encodedQuery: [(name: String, value: String)] = query.map {
            (S3Signer.encode($0.0), S3Signer.encode($0.1))
        }
        let sortedQuery = encodedQuery.sorted { lhs, rhs in
            lhs.name == rhs.name ? lhs.value < rhs.value : lhs.name < rhs.name
        }
        let pairs: [String] = sortedQuery.map { $0.name + "=" + $0.value }
        components.percentEncodedQuery = pairs.isEmpty ? nil : pairs.joined(separator: "&")
        if (components.scheme == "https" && components.port == 443)
            || (components.scheme == "http" && components.port == 80) {
            components.port = nil
        }
        guard let url = components.url else {
            throw S3SyncTransportError.invalidConfiguration("The server address is invalid.")
        }
        return url
    }

    static func isLocalNetwork(_ host: String) -> Bool {
        let host = host.lowercased()
        if ["localhost", "127.0.0.1", "::1"].contains(host) || host.hasSuffix(".local") {
            return true
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets = labels.compactMap { UInt8($0) }
        guard labels.count == 4, octets.count == 4 else { return false }
        return octets[0] == 10 || octets[0] == 127
            || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
    }
}

public enum S3SyncTransportError: Error, Equatable, LocalizedError {
    case invalidConfiguration(String)
    case missingCredentials
    /// The service answered with an error. `code` is the S3 error code, such
    /// as `AccessDenied`, or the status when the body had none.
    case requestFailed(status: Int, code: String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message): message
        case .missingCredentials: "Enter the access key for your S3 storage."
        case .requestFailed(let status, let code):
            "The S3 storage answered with \(code) (HTTP \(status))."
        case .invalidResponse: "The S3 storage sent a response that could not be read."
        }
    }
}

/// The few S3 operations notebook sync needs. Requests are signed with
/// SigV4 and sent through URLSession; network errors pass through unchanged
/// so shared code treats them as temporary.
struct S3Client: Sendable {
    struct Listing: Sendable {
        var keys: [(key: String, size: Int)] = []
        var commonPrefixes: [String] = []
        var nextContinuationToken: String?
        var isTruncated = false
    }

    enum PutResult: Equatable, Sendable {
        case stored
        /// `If-None-Match: *` found an existing object.
        case alreadyExists
        /// The service does not implement conditional writes.
        case conditionUnsupported
    }

    let configuration: S3SyncConfiguration
    let credentials: S3Credentials
    let session: URLSession
    let timeout: TimeInterval
    var now: @Sendable () -> Date = { Date() }

    func get(_ key: String) async throws -> Data? {
        let (data, status) = try await send("GET", key: key, accepting: [404])
        return status == 404 ? nil : data
    }

    func put(
        _ key: String, _ data: Data, ifNoneMatch: Bool = false
    ) async throws -> PutResult {
        var headers = ["Content-Type": "application/json"]
        if ifNoneMatch { headers["If-None-Match"] = "*" }
        let (_, status) = try await send(
            "PUT", key: key, body: data, headers: headers,
            accepting: ifNoneMatch ? [412, 501] : []
        )
        switch status {
        case 412: return .alreadyExists
        case 501: return .conditionUnsupported
        default: return .stored
        }
    }

    func delete(_ key: String) async throws {
        _ = try await send("DELETE", key: key, accepting: [404])
    }

    func list(
        prefix: String, delimiter: String? = nil, startAfter: String? = nil,
        continuationToken: String? = nil, maxKeys: Int = 1_000
    ) async throws -> Listing {
        var query = [("list-type", "2"), ("prefix", prefix), ("max-keys", String(maxKeys))]
        if let delimiter { query.append(("delimiter", delimiter)) }
        if let startAfter { query.append(("start-after", startAfter)) }
        if let continuationToken { query.append(("continuation-token", continuationToken)) }
        let (data, _) = try await send("GET", key: "", query: query)
        return try S3ListingParser.parse(data)
    }

    /// Every key under a prefix, following continuation tokens.
    func listAll(prefix: String) async throws -> [(key: String, size: Int)] {
        var keys: [(key: String, size: Int)] = []
        var token: String?
        repeat {
            let page = try await list(prefix: prefix, continuationToken: token)
            keys += page.keys
            token = page.isTruncated ? page.nextContinuationToken : nil
        } while token != nil
        return keys
    }

    private func send(
        _ method: String, key: String, query: [(String, String)] = [],
        body: Data = Data(), headers: [String: String] = [:],
        accepting accepted: Set<Int> = []
    ) async throws -> (Data, Int) {
        var request = URLRequest(
            url: try configuration.url(forKey: key, query: query),
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: timeout
        )
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if method == "PUT" { request.httpBody = body }
        S3Signer.sign(
            &request, payload: body, credentials: credentials,
            region: configuration.region, date: now()
        )
        let (data, response) = try await boundedData(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw S3SyncTransportError.invalidResponse
        }
        if (200..<300).contains(http.statusCode) || accepted.contains(http.statusCode) {
            return (data, http.statusCode)
        }
        let code = S3ListingParser.errorCode(data) ?? "HTTP\(http.statusCode)"
        throw S3SyncTransportError.requestFailed(status: http.statusCode, code: code)
    }

    /// Stops reading once a response exceeds the limit, so a misbehaving
    /// server cannot fill memory.
    private func boundedData(for request: URLRequest) async throws -> (Data, URLResponse) {
        let limit = 128 * 1_024 * 1_024
        let (bytes, response) = try await session.bytes(for: request)
        guard response.expectedContentLength <= Int64(limit) else {
            bytes.task.cancel()
            throw S3SyncTransportError.invalidResponse
        }
        var buffer: [UInt8] = []
        if response.expectedContentLength > 0 {
            buffer.reserveCapacity(Int(response.expectedContentLength))
        }
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count > limit {
                bytes.task.cancel()
                throw S3SyncTransportError.invalidResponse
            }
        }
        return (Data(buffer), response)
    }
}

/// Reads ListObjectsV2 results and S3 error bodies.
private final class S3ListingParser: NSObject, XMLParserDelegate {
    private var listing = S3Client.Listing()
    private var path: [String] = []
    private var text = ""
    private var currentKey: String?
    private var currentSize = 0
    private var errorCode: String?

    static func parse(_ data: Data) throws -> S3Client.Listing {
        let delegate = S3ListingParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), delegate.path.isEmpty else {
            throw S3SyncTransportError.invalidResponse
        }
        return delegate.listing
    }

    static func errorCode(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        let delegate = S3ListingParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.errorCode
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        path.append(elementName)
        text = ""
        if elementName == "Contents" {
            currentKey = nil
            currentSize = 0
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String,
        namespaceURI: String?, qualifiedName: String?
    ) {
        let parent = path.dropLast().last
        switch (parent, elementName) {
        case ("Contents", "Key"): currentKey = text
        case ("Contents", "Size"): currentSize = Int(text) ?? 0
        case ("CommonPrefixes", "Prefix"): listing.commonPrefixes.append(text)
        case ("ListBucketResult", "IsTruncated"): listing.isTruncated = text == "true"
        case ("ListBucketResult", "NextContinuationToken"):
            listing.nextContinuationToken = text
        case ("Error", "Code"): errorCode = text
        default: break
        }
        if elementName == "Contents", let currentKey {
            listing.keys.append((currentKey, currentSize))
        }
        path.removeLast()
        text = ""
    }
}
