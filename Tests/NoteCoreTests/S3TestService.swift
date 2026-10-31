import Foundation
@testable import NoteCore

/// A real S3-compatible service for tests, configured by environment:
/// `MEH_S3_TEST_ENDPOINT`, `MEH_S3_TEST_BUCKET`, `MEH_S3_TEST_ACCESS_KEY`,
/// `MEH_S3_TEST_SECRET_KEY`, and optionally `MEH_S3_TEST_REGION`. Each test
/// uses its own random prefix in that bucket.
struct S3TestService {
    let configuration: S3SyncConfiguration
    let credentials: S3Credentials

    static func fromEnvironment() -> S3TestService? {
        let environment = ProcessInfo.processInfo.environment
        guard let endpoint = environment["MEH_S3_TEST_ENDPOINT"],
              let bucket = environment["MEH_S3_TEST_BUCKET"],
              let accessKey = environment["MEH_S3_TEST_ACCESS_KEY"],
              let secretKey = environment["MEH_S3_TEST_SECRET_KEY"] else { return nil }
        return S3TestService(
            configuration: S3SyncConfiguration(
                endpoint: endpoint, region: environment["MEH_S3_TEST_REGION"] ?? "us-east-1",
                bucket: bucket
            ),
            credentials: S3Credentials(accessKeyID: accessKey, secretAccessKey: secretKey)
        )
    }

    func transport(prefix: String, stateDirectory: URL, pageSize: Int = 200) -> S3SyncTransport {
        var configuration = configuration
        configuration.prefix = prefix
        return S3SyncTransport(
            configuration: configuration, credentials: credentials,
            stateDirectory: stateDirectory, pageSize: pageSize
        )
    }
}
