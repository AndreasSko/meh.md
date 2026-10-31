import Foundation

/// An in-process S3 service for tests, reached through `URLProtocol`.
///
/// It implements the subset notebook sync uses: path-style GET, PUT, DELETE,
/// `If-None-Match: *`, and ListObjectsV2 with prefix, delimiter,
/// start-after, continuation tokens, and max-keys. Every request must carry
/// a SigV4 Authorization header.
public final class FakeS3Server: @unchecked Sendable {
    public enum ConditionalWrites: Sendable {
        case supported
        /// Answers 501 like Backblaze B2.
        case notImplemented
        /// Ignores the header and overwrites.
        case ignored
    }

    public let host: String
    public var endpoint: String { "http://\(host)" }
    public let session: URLSession

    private let lock = NSLock()
    private var objects: [String: Data] = [:]
    private var _offline = false
    private var _conditionalWrites = ConditionalWrites.supported
    private var _requests: [String] = []
    private var _failNextPuts = 0

    public init() {
        host = "s3-\(UUID().uuidString.lowercased().prefix(8)).local"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeS3Protocol.self]
        session = URLSession(configuration: configuration)
        FakeS3Protocol.register(self)
    }

    deinit { FakeS3Protocol.unregister(host) }

    public var offline: Bool {
        get { lock.withLock { _offline } }
        set { lock.withLock { _offline = newValue } }
    }

    public var conditionalWrites: ConditionalWrites {
        get { lock.withLock { _conditionalWrites } }
        set { lock.withLock { _conditionalWrites = newValue } }
    }

    /// Method and path of every request, for request-count checks.
    public var requests: [String] { lock.withLock { _requests } }

    /// Fails the next PUT requests with a 503.
    public func failNextPuts(_ count: Int) { lock.withLock { _failNextPuts = count } }

    public func keys(bucket: String, prefix: String = "") -> [String] {
        lock.withLock {
            objects.keys.filter { $0.hasPrefix(bucket + "/" + prefix) }
                .map { String($0.dropFirst(bucket.count + 1)) }.sorted()
        }
    }

    public func object(bucket: String, key: String) -> Data? {
        lock.withLock { objects[bucket + "/" + key] }
    }

    public func setObject(_ data: Data?, bucket: String, key: String) {
        lock.withLock { objects[bucket + "/" + key] = data }
    }

    fileprivate func respond(to request: URLRequest, body: Data)
        -> (status: Int, headers: [String: String], body: Data)? {
        lock.withLock {
            if _offline { return nil }
            guard let url = request.url,
                  request.value(forHTTPHeaderField: "Authorization")?
                    .hasPrefix("AWS4-HMAC-SHA256 Credential=") == true,
                  request.value(forHTTPHeaderField: "x-amz-date") != nil else {
                return (403, [:], Self.error("AccessDenied"))
            }
            let method = request.httpMethod ?? "GET"
            let path = url.path(percentEncoded: false)
            _requests.append(method + " " + path)
            let parts = path.dropFirst().split(separator: "/", maxSplits: 1)
            guard let bucket = parts.first.map(String.init) else {
                return (400, [:], Self.error("InvalidRequest"))
            }
            let key = parts.count > 1 ? String(parts[1]) : ""
            let full = bucket + "/" + key
            switch method {
            case "PUT":
                if _failNextPuts > 0 {
                    _failNextPuts -= 1
                    return (503, [:], Self.error("SlowDown"))
                }
                if request.value(forHTTPHeaderField: "If-None-Match") == "*" {
                    switch _conditionalWrites {
                    case .supported where objects[full] != nil:
                        return (412, [:], Self.error("PreconditionFailed"))
                    case .notImplemented:
                        return (501, [:], Self.error("NotImplemented"))
                    default: break
                    }
                }
                objects[full] = body
                return (200, ["ETag": "\"\(body.count)\""], Data())
            case "DELETE":
                objects[full] = nil
                return (204, [:], Data())
            case "GET" where key.isEmpty:
                return (200, [:], list(bucket: bucket, url: url))
            case "GET":
                guard let data = objects[full] else {
                    return (404, [:], Self.error("NoSuchKey"))
                }
                return (200, [:], data)
            default:
                return (405, [:], Self.error("MethodNotAllowed"))
            }
        }
    }

    private func list(bucket: String, url: URL) -> Data {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        let prefix = value("prefix") ?? ""
        let delimiter = value("delimiter")
        let startAfter = value("continuation-token") ?? value("start-after") ?? ""
        let maxKeys = Int(value("max-keys") ?? "") ?? 1_000
        let keys = objects.keys.filter { $0.hasPrefix(bucket + "/") }
            .map { String($0.dropFirst(bucket.count + 1)) }
            .filter { $0.hasPrefix(prefix) && $0 > startAfter }.sorted()
        var contents: [String] = []
        var prefixes: [String] = []
        var last: String?
        var truncated = false
        for key in keys {
            if contents.count + prefixes.count >= maxKeys {
                truncated = true
                break
            }
            if let delimiter,
               let range = key.dropFirst(prefix.count).range(of: delimiter) {
                let common = String(key[..<range.upperBound])
                if prefixes.last != common { prefixes.append(common) }
                last = common + "\u{10FFFF}"
                continue
            }
            if let last, key < last { continue }
            contents.append(key)
            last = key
        }
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><ListBucketResult>"
        xml += "<IsTruncated>\(truncated)</IsTruncated>"
        if truncated, let last { xml += "<NextContinuationToken>\(escape(last))</NextContinuationToken>" }
        for key in contents {
            let size = objects[bucket + "/" + key]?.count ?? 0
            xml += "<Contents><Key>\(escape(key))</Key><Size>\(size)</Size></Contents>"
        }
        for common in prefixes {
            xml += "<CommonPrefixes><Prefix>\(escape(common))</Prefix></CommonPrefixes>"
        }
        return Data((xml + "</ListBucketResult>").utf8)
    }

    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func error(_ code: String) -> Data {
        Data("<?xml version=\"1.0\"?><Error><Code>\(code)</Code><Message>\(code)</Message></Error>".utf8)
    }
}

private final class FakeS3Protocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var servers: [String: FakeS3Server] = [:]
    private static let lock = NSLock()

    static func register(_ server: FakeS3Server) {
        lock.withLock { servers[server.host] = server }
    }

    static func unregister(_ host: String) {
        lock.withLock { servers[host] = nil }
    }

    private static func server(for request: URLRequest) -> FakeS3Server? {
        guard let host = request.url?.host else { return nil }
        return lock.withLock { servers[host] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        server(for: request) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let server = Self.server(for: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        guard let reply = server.respond(to: request, body: body) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status,
            httpVersion: "HTTP/1.1", headerFields: reply.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
