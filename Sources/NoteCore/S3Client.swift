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
        let location = isAWS ? "aws" : (endpointURL.flatMap(Self.hostHeader) ?? endpoint)
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

    package var endpointURL: URL? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed)
    }

    package var isAWS: Bool {
        endpointURL?.host(percentEncoded: false)?.lowercased().hasSuffix(".amazonaws.com") == true
    }

    /// The region an AWS address names, such as `eu-central-1` for
    /// `https://s3.eu-central-1.amazonaws.com`, so it needn't be typed twice.
    public static func awsRegion(inEndpoint endpoint: String) -> String? {
        let configuration = S3SyncConfiguration(endpoint: endpoint, region: "", bucket: "")
        guard configuration.isAWS,
              let host = configuration.endpointURL?.host(percentEncoded: false)?.lowercased()
        else { return nil }
        if host == "s3.amazonaws.com" { return "us-east-1" }
        // Virtual-hosted addresses start with the bucket name, which can
        // look like a region, so only labels from the "s3" label on count.
        let labels = host.split(separator: ".")
        guard let start = labels.firstIndex(where: { $0 == "s3" || $0.hasPrefix("s3-") })
        else { return nil }
        return labels[start...].lazy
            .map { $0.hasPrefix("s3-") ? $0.dropFirst(3) : $0 }
            .first { $0.range(of: "^[a-z]{2}(-[a-z]+)+-[0-9]+$", options: .regularExpression) != nil }
            .map(String.init)
    }

    /// The host and, when it is not the scheme's default, the port.
    static func hostHeader(_ url: URL) -> String? {
        guard let host = url.host(percentEncoded: false)?.lowercased() else { return nil }
        let bracketed = host.contains(":") ? "[\(host)]" : host
        guard let port = url.port,
              !(url.scheme == "https" && port == 443),
              !(url.scheme == "http" && port == 80) else { return bracketed }
        return "\(bracketed):\(port)"
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

public struct S3Credentials: Codable, Equatable, Sendable {
    public let accessKeyID: String
    public let secretAccessKey: String

    public init(accessKeyID: String, secretAccessKey: String) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
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

/// The few S3 operations notebook sync needs. NoteCoreAWS implements them
/// with the AWS SDK, so NoteCore, and code that only edits notes, doesn't
/// depend on it. Service errors are `S3SyncTransportError.requestFailed`;
/// network errors pass through unchanged so shared code treats them as
/// temporary.
public protocol S3Client: Sendable {
    /// The object, or nil when there is none.
    func get(_ key: String) async throws -> Data?
    func put(_ key: String, _ data: Data, ifNoneMatch: Bool) async throws -> S3PutResult
    /// Succeeds when the object is already gone.
    func delete(_ key: String) async throws
    func listObjects(
        prefix: String, delimiter: String?, startAfter: String?,
        continuationToken: String?, maxKeys: Int
    ) async throws -> S3Listing
}

public struct S3Listing: Sendable {
    public var keys: [(key: String, size: Int)]
    public var commonPrefixes: [String]
    public var nextContinuationToken: String?
    public var isTruncated: Bool

    public init(
        keys: [(key: String, size: Int)] = [], commonPrefixes: [String] = [],
        nextContinuationToken: String? = nil, isTruncated: Bool = false
    ) {
        self.keys = keys
        self.commonPrefixes = commonPrefixes
        self.nextContinuationToken = nextContinuationToken
        self.isTruncated = isTruncated
    }
}

public enum S3PutResult: Equatable, Sendable {
    case stored
    /// `If-None-Match: *` found an existing object.
    case alreadyExists
    /// The service does not implement conditional writes.
    case conditionUnsupported
}

extension S3Client {
    func put(_ key: String, _ data: Data) async throws -> S3PutResult {
        try await put(key, data, ifNoneMatch: false)
    }

    func list(
        prefix: String, delimiter: String? = nil, startAfter: String? = nil,
        continuationToken: String? = nil, maxKeys: Int = 1_000
    ) async throws -> S3Listing {
        try await listObjects(
            prefix: prefix, delimiter: delimiter, startAfter: startAfter,
            continuationToken: continuationToken, maxKeys: maxKeys
        )
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
}
