import CryptoKit
import Foundation

/// An access key pair for an S3-compatible service. Never logged or part of
/// a sync scope.
public struct S3Credentials: Codable, Equatable, Sendable {
    public let accessKeyID: String
    public let secretAccessKey: String

    public init(accessKeyID: String, secretAccessKey: String) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
    }
}

/// AWS Signature Version 4 for S3 requests, signed in the Authorization
/// header with a hashed payload. S3-compatible services accept the same
/// signature.
enum S3Signer {
    static let emptyPayloadHash = sha256Hex(Data())

    /// Adds `x-amz-date`, `x-amz-content-sha256`, and `Authorization` to a
    /// request whose URL path and query are already encoded with `encode`.
    static func sign(
        _ request: inout URLRequest, payload: Data,
        credentials: S3Credentials, region: String, date: Date
    ) {
        let payloadHash = sha256Hex(payload)
        let amzDate = timestamp(date)
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        var headers = request.allHTTPHeaderFields ?? [:]
        headers["host"] = request.url.flatMap(hostHeader)
        let authorization = authorization(
            method: request.httpMethod ?? "GET", url: request.url!,
            headers: headers, payloadHash: payloadHash,
            credentials: credentials, region: region, amzDate: amzDate
        )
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
    }

    static func authorization(
        method: String, url: URL, headers: [String: String],
        payloadHash: String, credentials: S3Credentials,
        region: String, amzDate: String
    ) -> String {
        let day = String(amzDate.prefix(8))
        let canonicalHeaders = headers
            .map { ($0.key.lowercased(), normalize($0.value)) }
            .sorted { $0.0 < $1.0 }
        let signedHeaders = canonicalHeaders.map(\.0).joined(separator: ";")
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = components?.percentEncodedPath ?? "/"
        let canonicalRequest = [
            method,
            path.isEmpty ? "/" : path,
            canonicalQuery(components?.percentEncodedQuery),
            canonicalHeaders.map { "\($0.0):\($0.1)\n" }.joined(),
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")
        let credentialScope = "\(day)/\(region)/s3/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256", amzDate, credentialScope,
            sha256Hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")
        var key = SymmetricKey(data: Data(("AWS4" + credentials.secretAccessKey).utf8))
        for part in [day, region, "s3", "aws4_request"] {
            key = SymmetricKey(data: hmac(key, part))
        }
        let signature = hmac(key, stringToSign).map { String(format: "%02x", $0) }.joined()
        return "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyID)/\(credentialScope), "
            + "SignedHeaders=\(signedHeaders), Signature=\(signature)"
    }

    /// Percent-encodes everything except unreserved characters, as SigV4
    /// requires. Pass `keepSlash` for object key paths.
    static func encode(_ value: String, keepSlash: Bool = false) -> String {
        var allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        if keepSlash { allowed.insert("/") }
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func timestamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date
        )
        return String(
            format: "%04d%02d%02dT%02d%02d%02dZ",
            parts.year!, parts.month!, parts.day!,
            parts.hour!, parts.minute!, parts.second!
        )
    }

    /// The Host header URLSession sends: the port only when it is not the
    /// scheme's default.
    static func hostHeader(_ url: URL) -> String? {
        guard let host = url.host(percentEncoded: false)?.lowercased() else { return nil }
        let bracketed = host.contains(":") ? "[\(host)]" : host
        guard let port = url.port,
              !(url.scheme == "https" && port == 443),
              !(url.scheme == "http" && port == 80) else { return bracketed }
        return "\(bracketed):\(port)"
    }

    private static func canonicalQuery(_ query: String?) -> String {
        guard let query, !query.isEmpty else { return "" }
        let pairs: [(name: String, value: String)] = query
            .split(separator: "&", omittingEmptySubsequences: true)
            .map { pair in
                let parts = pair.split(separator: "=", maxSplits: 1)
                return (String(parts[0]), parts.count > 1 ? String(parts[1]) : "")
            }
        let sorted = pairs.sorted { lhs, rhs in
            lhs.name == rhs.name ? lhs.value < rhs.value : lhs.name < rhs.name
        }
        return sorted.map { $0.name + "=" + $0.value }.joined(separator: "&")
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespaces)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    private static func hmac(_ key: SymmetricKey, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key))
    }
}
