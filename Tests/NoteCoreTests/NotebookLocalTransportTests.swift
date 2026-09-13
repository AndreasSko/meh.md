import Foundation
import XCTest

@testable import NoteCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

final class NotebookLocalTransportTests: XCTestCase, @unchecked Sendable {
    private let notebookID = UUID(
        uuidString: "628FC016-B345-4B2E-A004-1942FFB800B6"
    )!

    func testV2UsesNotebookRoutesAndScope() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NotebookSyncURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let catalog = try NotebookCatalogDocument(
            notebookID: notebookID
        )
        let catalogRecord = SyncRecord(catalog: catalog.snapshot())
        let noteRecord = SyncRecord(
            snapshot: try NoteDocument(text: "body").snapshot(),
            notebookID: notebookID
        )

        NotebookSyncURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            switch (request.httpMethod, url.path) {
            case ("POST", "/v2/bootstrap"):
                return try Self.response(catalogRecord, for: url)
            case ("POST", "/v2/records"):
                return try Self.response(["stored": true], for: url)
            case ("GET", "/v2/records"):
                let components = URLComponents(
                    url: url,
                    resolvingAgainstBaseURL: false
                )
                XCTAssertEqual(
                    components?.queryItems?.first { $0.name == "scope" }?.value,
                    "notebook"
                )
                return try Self.response(
                    SyncPage(
                        records: [catalogRecord, noteRecord],
                        cursor: "complete",
                        hasMore: false
                    ),
                    for: url
                )
            default:
                XCTFail("Unexpected request: \(request)")
                return try Self.response(["stored": false], for: url)
            }
        }

        let transport = LocalSyncTransport(
            baseURL: URL(string: "http://127.0.0.1:8765/")!,
            workspace: "notebook",
            session: session,
            protocolVersion: 2
        )
        XCTAssertEqual(
            transport.scope,
            "http://127.0.0.1:8765#notebook#v2"
        )
        let accepted = try await transport.bootstrap(proposing: catalogRecord)
        XCTAssertEqual(accepted, catalogRecord)
        try await transport.publish(noteRecord)
        let fetched = try await transport.fetch(after: nil)
        XCTAssertEqual(fetched.records, [catalogRecord, noteRecord])
    }

    func testV2RejectsLegacyRecordsAndNoteBootstrapLocally() async throws {
        let transport = LocalSyncTransport(
            baseURL: URL(string: "http://127.0.0.1:8765/")!,
            workspace: "notebook",
            protocolVersion: 2
        )
        let legacy = SyncRecord(
            snapshot: try NoteDocument(text: "legacy").snapshot()
        )
        let note = SyncRecord(
            snapshot: try NoteDocument(text: "body").snapshot(),
            notebookID: notebookID
        )

        await assertInvalidRecord {
            try await transport.publish(legacy)
        }
        await assertInvalidRecord {
            _ = try await transport.bootstrap(proposing: note)
        }
    }

    func testV1RejectsNotebookRecordsLocally() async throws {
        let transport = LocalSyncTransport(
            baseURL: URL(string: "http://127.0.0.1:8765/")!,
            workspace: "legacy"
        )
        let note = SyncRecord(
            snapshot: try NoteDocument(text: "body").snapshot(),
            notebookID: notebookID
        )

        await assertInvalidRecord {
            try await transport.publish(note)
        }
        XCTAssertEqual(transport.scope, "http://127.0.0.1:8765#legacy")
    }

    func testUnsupportedProtocolVersionIsRejectedLocally() async {
        let transport = LocalSyncTransport(
            baseURL: URL(string: "http://127.0.0.1:8765/")!,
            workspace: "unsupported",
            protocolVersion: 3
        )

        await assertInvalidRecord {
            _ = try await transport.fetch(after: nil)
        }
    }

    private func assertInvalidRecord(
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected invalid record")
        } catch let error as SyncError {
            XCTAssertEqual(error, .invalidRecord)
        } catch {
            XCTFail("Expected SyncError, got \(error)")
        }
    }

    private static func response<Value: Encodable>(
        _ value: Value,
        for url: URL
    ) throws -> (HTTPURLResponse, Data) {
        (
            try XCTUnwrap(
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )
            ),
            try JSONEncoder().encode(value)
        )
    }
}

private final class NotebookSyncURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let (response, data) = try handler(request)
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
