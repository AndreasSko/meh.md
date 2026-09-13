import Foundation
import XCTest

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@testable import NoteCore

final class SyncTransportTests: XCTestCase, @unchecked Sendable {
    private let noteID = UUID(
        uuidString: "9C86E52A-7037-4107-B7AA-148E3308A52D"
    )!

    func testConcurrentBootstrapChoosesOneDiscoverableSeed() async throws {
        let store = InMemorySyncStore()
        let left = InMemorySyncTransport(scope: "shared", store: store)
        let right = InMemorySyncTransport(scope: "shared", store: store)
        let leftRecord = try record(text: "left")
        let rightRecord = try record(text: "right")

        async let first = left.bootstrap(proposing: leftRecord)
        async let second = right.bootstrap(proposing: rightRecord)
        let seeds = try await [first, second]

        XCTAssertEqual(seeds[0], seeds[1])
        XCTAssertTrue([leftRecord, rightRecord].contains(seeds[0]))
        let page = try await left.fetch(after: nil)
        XCTAssertEqual(page.records, [seeds[0]])
    }

    func testRetriesPaginationAndScopeBoundCursors() async throws {
        let store = InMemorySyncStore()
        let transport = InMemorySyncTransport(
            scope: "first",
            store: store,
            pageSize: 2
        )
        let records = try (0..<5).map { try record(text: "record-\($0)") }
        _ = try await transport.bootstrap(proposing: records[0])
        for record in records.dropFirst() {
            try await transport.publish(record)
            try await transport.publish(record)
        }

        let first = try await transport.fetch(after: nil)
        let second = try await transport.fetch(after: first.cursor)
        let third = try await transport.fetch(after: second.cursor)
        XCTAssertEqual(first.records, Array(records[0..<2]))
        XCTAssertTrue(first.hasMore)
        XCTAssertEqual(second.records, Array(records[2..<4]))
        XCTAssertTrue(second.hasMore)
        XCTAssertEqual(third.records, [records[4]])
        XCTAssertFalse(third.hasMore)

        let other = InMemorySyncTransport(scope: "second", store: store)
        await assertSyncError(.invalidCursor) {
            _ = try await other.fetch(after: first.cursor)
        }
        let otherPage = try await other.fetch(after: nil)
        XCTAssertTrue(otherPage.records.isEmpty)
    }

    func testInvalidRecordsOfflineDeliveryAndLostAcknowledgements() async throws {
        let store = InMemorySyncStore()
        let transport = InMemorySyncTransport(scope: "shared", store: store)
        let valid = try record(text: "stored despite lost acknowledgement")
        let invalid = try JSONDecoder().decode(
            SyncRecord.self,
            from: Data(
                """
                {"id":"wrong","snapshot":{"data":"","heads":[],
                "noteID":"\(noteID.uuidString)"}}
                """.utf8
            )
        )

        await assertSyncError(.invalidRecord) {
            try await transport.publish(invalid)
        }

        await store.loseNextAcknowledgement()
        do {
            try await transport.publish(valid)
            XCTFail("Expected the simulated acknowledgement loss")
        } catch let error as SyncError {
            guard case .unavailable = error else {
                return XCTFail("Expected unavailable, got \(error)")
            }
        }
        try await transport.publish(valid)
        let persisted = try await transport.fetch(after: nil)
        XCTAssertEqual(persisted.records, [valid])

        await store.setOffline(true)
        do {
            _ = try await transport.fetch(after: nil)
            XCTFail("Expected the store to be offline")
        } catch let error as SyncError {
            guard case .unavailable = error else {
                return XCTFail("Expected unavailable, got \(error)")
            }
        }
    }

    func testHTTPAdapterEncodesWorkspaceAndMapsInvalidCursor() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SyncURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let transport = LocalSyncTransport(
            baseURL: URL(string: "http://127.0.0.1:8765/")!,
            workspace: "device tests & spaces",
            session: session,
            timeout: 1,
            pageSize: 7
        )

        SyncURLProtocol.handler = { request in
            let components = URLComponents(
                url: try XCTUnwrap(request.url),
                resolvingAgainstBaseURL: false
            )
            XCTAssertEqual(components?.path, "/v1/records")
            XCTAssertEqual(
                components?.queryItems?.first { $0.name == "scope" }?.value,
                "device tests & spaces"
            )
            XCTAssertEqual(
                components?.queryItems?.first { $0.name == "limit" }?.value,
                "7"
            )
            let body = Data(
                """
                {"error":"invalid_cursor","message":"bad cursor"}
                """.utf8
            )
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 400,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                body
            )
        }

        await assertSyncError(.invalidCursor) {
            _ = try await transport.fetch(after: "bad")
        }
        XCTAssertTrue(transport.scope.contains("#device tests & spaces"))
    }

    private func record(text: String) throws -> SyncRecord {
        SyncRecord(snapshot: try NoteDocument(noteID: noteID, text: text).snapshot())
    }

    private func assertSyncError(
        _ expected: SyncError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)")
        } catch let error as SyncError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Expected SyncError, got \(error)")
        }
    }
}

private final class SyncURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler:
        ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
