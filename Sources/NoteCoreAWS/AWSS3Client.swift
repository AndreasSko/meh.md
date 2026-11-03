import AWSS3
import ClientRuntime
import Foundation
import NoteCore
import Smithy
import SmithyHTTPAPI
import SmithyIdentity
import SmithyRetries
import SmithyRetriesAPI

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension S3SyncTransport {
    /// A transport that sends its requests with the AWS SDK.
    public init(
        configuration: S3SyncConfiguration,
        credentials: S3Credentials,
        stateDirectory: URL,
        session: URLSession = .shared,
        timeout: TimeInterval = 30,
        maxAttempts: Int = AWSS3Client.maxAttempts,
        pageSize: Int = 200
    ) {
        self.init(
            configuration: configuration,
            client: AWSS3Client(
                configuration: configuration, credentials: credentials,
                session: session, timeout: timeout, maxAttempts: maxAttempts
            ),
            stateDirectory: stateDirectory, pageSize: pageSize
        )
    }
}

/// S3 requests sent with the AWS SDK, which signs them and retries
/// throttling and server errors with exponential backoff.
public struct AWSS3Client: NoteCore.S3Client {
    /// Tries per request, including the first. The SDK default of three
    /// was not enough to ride out a burst of errors from Backblaze B2.
    public static let maxAttempts = 5

    let bucket: String
    private let sdk: Result<AWSS3.S3Client, any Error>

    public init(
        configuration: S3SyncConfiguration, credentials: S3Credentials,
        session: URLSession = .shared, timeout: TimeInterval = 30,
        maxAttempts: Int = maxAttempts
    ) {
        self.init(
            configuration: configuration, credentials: credentials, session: session,
            timeout: timeout, maxAttempts: maxAttempts,
            retryBackoff: ExponentialBackoffStrategy()
        )
    }

    init(
        configuration: S3SyncConfiguration, credentials: S3Credentials,
        session: URLSession, timeout: TimeInterval, maxAttempts: Int,
        retryBackoff: any RetryBackoffStrategy
    ) {
        bucket = configuration.bucket
        sdk = Result {
            try configuration.validate()
            let config = try AWSS3.S3Client.S3ClientConfig(
                awsCredentialIdentityResolver: StaticAWSCredentialIdentityResolver(
                    AWSCredentialIdentity(
                        accessKey: credentials.accessKeyID,
                        secret: credentials.secretAccessKey
                    )
                ),
                // Other services reject or mishandle the checksum headers
                // newer SDKs send by default; S3 needs none of them here.
                requestChecksumCalculation: .whenRequired,
                responseChecksumValidation: .whenRequired,
                ignoreConfiguredEndpointURLs: true,
                region: configuration.region,
                // AWS addresses resolve from the region; other services use
                // path-style URLs at the address given.
                forcePathStyle: !configuration.isAWS,
                // Every retry draws on one budget per client, and an empty
                // budget stops all retries. The default of 500 lasts about 25
                // requests that fail every try, too few for a burst of errors
                // during a purge of hundreds of notes.
                retryStrategyOptions: RetryStrategyOptions(
                    backoffStrategy: retryBackoff, maxRetriesBase: max(0, maxAttempts - 1),
                    availableCapacity: 5_000, maxCapacity: 5_000
                ),
                endpoint: configuration.isAWS
                    ? nil : configuration.endpointURL?.absoluteString,
                httpClientEngine: S3SessionEngine(session: session, timeout: timeout)
            )
            return AWSS3.S3Client(config: config)
        }
    }

    public func get(_ key: String) async throws -> Data? {
        do {
            let output = try await perform {
                try await $0.getObject(input: GetObjectInput(bucket: bucket, key: key))
            }
            return try await output.body?.readData() ?? Data()
        } catch S3SyncTransportError.requestFailed(404, _) {
            return nil
        }
    }

    public func put(
        _ key: String, _ data: Data, ifNoneMatch: Bool
    ) async throws -> S3PutResult {
        do {
            _ = try await perform {
                try await $0.putObject(input: PutObjectInput(
                    body: .data(data), bucket: bucket, contentType: "application/json",
                    ifNoneMatch: ifNoneMatch ? "*" : nil, key: key
                ))
            }
            return .stored
        } catch S3SyncTransportError.requestFailed(412, _) where ifNoneMatch {
            return .alreadyExists
        } catch S3SyncTransportError.requestFailed(501, _) where ifNoneMatch {
            return .conditionUnsupported
        }
    }

    public func delete(_ key: String) async throws {
        do {
            _ = try await perform {
                try await $0.deleteObject(input: DeleteObjectInput(bucket: bucket, key: key))
            }
        } catch S3SyncTransportError.requestFailed(404, _) {}
    }

    public func listObjects(
        prefix: String, delimiter: String?, startAfter: String?,
        continuationToken: String?, maxKeys: Int
    ) async throws -> S3Listing {
        let output = try await perform {
            try await $0.listObjectsV2(input: ListObjectsV2Input(
                bucket: bucket, continuationToken: continuationToken, delimiter: delimiter,
                maxKeys: maxKeys, prefix: prefix, startAfter: startAfter
            ))
        }
        return S3Listing(
            keys: (output.contents ?? []).compactMap { object in
                object.key.map { ($0, object.size ?? 0) }
            },
            commonPrefixes: (output.commonPrefixes ?? []).compactMap(\.prefix),
            nextContinuationToken: output.nextContinuationToken,
            isTruncated: output.isTruncated ?? false
        )
    }

    private func perform<Output>(
        _ operation: (AWSS3.S3Client) async throws -> Output
    ) async throws -> Output {
        let client = try sdk.get()
        do {
            return try await operation(client)
        } catch let error as any HTTPError {
            let status = error.httpResponse.statusCode.rawValue
            let code = (error as? any ServiceError)?.typeName ?? "HTTP\(status)"
            throw S3SyncTransportError.requestFailed(status: status, code: code)
        }
    }
}

/// Sends the SDK's requests through a URLSession of our choosing, so a
/// connection check can wait for local network access, which the SDK's own
/// engine cannot be configured to do.
struct S3SessionEngine: SmithyHTTPAPI.HTTPClient {
    let session: URLSession
    let timeout: TimeInterval

    func send(request: SmithyHTTPAPI.HTTPRequest) async throws -> SmithyHTTPAPI.HTTPResponse {
        var components = URLComponents()
        components.scheme = request.destination.scheme.rawValue
        components.host = request.destination.host
        if let port = request.destination.port,
           !(request.destination.scheme == .https && port == 443),
           !(request.destination.scheme == .http && port == 80) {
            components.port = Int(port)
        }
        components.percentEncodedPath = request.destination.path
        if let items = request.queryItems, !items.isEmpty {
            components.percentEncodedQueryItems = items.map {
                URLQueryItem(name: $0.name, value: $0.value)
            }
        }
        guard let url = components.url else { throw S3SyncTransportError.invalidResponse }
        var urlRequest = URLRequest(
            url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: timeout
        )
        urlRequest.httpMethod = request.method.rawValue
        for header in request.headers.headers {
            for value in header.value { urlRequest.addValue(value, forHTTPHeaderField: header.name) }
        }
        urlRequest.httpBody = try await request.body.readData()
        let (data, response) = try await boundedData(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw S3SyncTransportError.invalidResponse
        }
        // The SDK only reads errors with an S3 error code. A proxy's empty
        // or HTML reply would otherwise be neither retried nor reported by
        // its status, so it gets the status as its code.
        var body = data
        if http.statusCode >= 300, data.range(of: Data("<Code>".utf8)) == nil {
            body = Data("<Error><Code>HTTP\(http.statusCode)</Code></Error>".utf8)
        }
        var headers = Headers()
        for case let (name as String, value as String) in http.allHeaderFields {
            headers.add(name: name, value: value)
        }
        return HTTPResponse(
            headers: headers, body: .data(body),
            statusCode: HTTPStatusCode(rawValue: http.statusCode)
                ?? (http.statusCode >= 500 ? .internalServerError : .badRequest)
        )
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
