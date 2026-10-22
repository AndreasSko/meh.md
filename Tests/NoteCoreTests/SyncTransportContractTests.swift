import Foundation
import TestSupport
import XCTest

@testable import NoteCore

/// The behavior every sync backend must provide for the coordinator. Each
/// check runs against every backend, so a new storage system is covered by
/// adding it to `backends()`.
///
/// The local HTTP backend runs only when `MEH_NOTEBOOK_HTTP_URL` points at a
/// disposable loopback service, as in `run_notebook_sync_validation.sh`.
@MainActor
final class SyncTransportContractTests: XCTestCase {
    func testConcurrentBootstrapAgreesOnOneDiscoverableSeed() async throws {
        try await forEachBackend { backend in
            let left = try await backend.open("left")
            let right = try await backend.open("right")
            let leftSeed = try Fixture().catalog
            let rightSeed = try Fixture().catalog

            async let first = left.bootstrap(proposing: leftSeed)
            async let second = right.bootstrap(proposing: rightSeed)
            let seeds = try await [first, second]

            XCTAssertEqual(seeds[0], seeds[1], backend.name)
            XCTAssertTrue([leftSeed, rightSeed].contains(seeds[0]), backend.name)
            let again = try await left.bootstrap(proposing: try Fixture().catalog)
            XCTAssertEqual(again, seeds[0], "\(backend.name): seed changed")
            let replay = try await drain(right)
            XCTAssertTrue(replay.contains(seeds[0]), "\(backend.name): seed not fetched")
        }
    }

    func testPublishedRecordsReachOtherDevices() async throws {
        try await forEachBackend { backend in
            let fixture = try Fixture()
            let writer = try await backend.open("writer")
            let reader = try await backend.open("reader")
            _ = try await writer.bootstrap(proposing: fixture.catalog)

            let result = try await writer.publishBatch(fixture.notes)
            XCTAssertNil(result.error, backend.name)
            XCTAssertEqual(
                result.acknowledgedIDs, Set(fixture.notes.map(\.id)), backend.name
            )
            // A retried publish of a stored record succeeds without a copy.
            try await writer.publish(fixture.notes[0])

            _ = try await reader.bootstrap(proposing: try Fixture().catalog)
            let received = try await drain(reader)
            XCTAssertEqual(
                Set(received.map(\.id)),
                Set(([fixture.catalog] + fixture.notes).map(\.id)),
                backend.name
            )
        }
    }

    func testCursorDeliversOnlyNewRecords() async throws {
        try await forEachBackend { backend in
            let fixture = try Fixture()
            let writer = try await backend.open("writer")
            let reader = try await backend.open("reader")
            _ = try await writer.bootstrap(proposing: fixture.catalog)
            try await writer.publish(fixture.notes[0])
            _ = try await reader.bootstrap(proposing: fixture.catalog)
            let (initial, cursor) = try await drainWithCursor(reader, after: nil)
            XCTAssertTrue(initial.contains(fixture.notes[0]), backend.name)

            try await writer.publish(fixture.notes[1])
            let (later, _) = try await drainWithCursor(reader, after: cursor)

            XCTAssertTrue(later.contains(fixture.notes[1]), "\(backend.name): missed new record")
            XCTAssertFalse(
                later.contains(fixture.notes[0]), "\(backend.name): repeated delivered record"
            )
        }
    }

    func testScopeIsStableForTheSameRemote() async throws {
        try await forEachBackend { backend in
            let first = try await backend.open("first")
            let second = try await backend.open("second")
            XCTAssertFalse(first.scope.isEmpty, backend.name)
            XCTAssertEqual(first.scope, second.scope, backend.name)
        }
    }

    func testRejectsRecordsThatFailValidation() async throws {
        try await forEachBackend { backend in
            let fixture = try Fixture()
            let transport = try await backend.open("writer")
            _ = try await transport.bootstrap(proposing: fixture.catalog)
            do {
                try await transport.publish(try fixture.forged())
                XCTFail("\(backend.name): accepted a forged record")
            } catch {
                XCTAssertEqual(error as? SyncError, .invalidRecord, backend.name)
            }
        }
    }

    func testPurgeRemovesDeletedBodiesAndKeepsTheCatalog() async throws {
        try await forEachBackend { backend in
            let fixture = try Fixture()
            let writer = try await backend.open("writer")
            _ = try await writer.bootstrap(proposing: fixture.catalog)
            _ = try await writer.publishBatch(fixture.notes)
            let marker = try fixture.deletionMarker(for: fixture.notes[0])
            try await writer.publish(marker)

            try await writer.purgeDeletedNotes(
                [fixture.notes[0].snapshot.noteID], notebookID: fixture.notebookID
            )

            let reader = try await backend.open("reader")
            _ = try await reader.bootstrap(proposing: fixture.catalog)
            let received = Set(try await drain(reader).map(\.id))
            XCTAssertFalse(received.contains(fixture.notes[0].id), backend.name)
            XCTAssertTrue(received.contains(fixture.notes[1].id), backend.name)
            XCTAssertTrue(received.contains(marker.id), backend.name)
        }
    }

    func testConcurrentEditsConvergeThroughTheBackend() async throws {
        try await forEachBackend { backend in
            let root = temporaryDirectory().appending(path: backend.name)
            let left = NotebookReplica(directory: root.appending(path: "left"))
            let right = NotebookReplica(directory: root.appending(path: "right"))
            let a = NotebookSyncCoordinator(
                replica: left, transport: try await backend.open("left")
            )
            let b = NotebookSyncCoordinator(
                replica: right, transport: try await backend.open("right")
            )
            try await synchronize(a, backend)
            try await synchronize(b, backend)
            let id = try await left.createNote(name: "Shared.md", text: "one two")
            try await synchronize(a, backend)
            try await synchronize(b, backend)

            let leftNote = try await left.openNote(id)
            let rightNote = try await right.openNote(id)
            try leftNote.replaceText(in: NSRange(location: 0, length: 3), with: "ONE")
            try rightNote.replaceText(in: NSRange(location: 4, length: 3), with: "TWO")
            try await leftNote.flush()
            try await rightNote.flush()
            try await synchronize(a, backend)
            try await synchronize(b, backend)
            try await synchronize(a, backend)

            XCTAssertEqual(leftNote.text, "ONE TWO", backend.name)
            XCTAssertEqual(rightNote.text, "ONE TWO", backend.name)
            XCTAssertEqual(left.placements, right.placements, backend.name)
        }
    }

    // MARK: - Backends

    /// One empty remote store, opened by independent simulated devices.
    private struct Backend {
        let name: String
        let open: @MainActor (_ device: String) async throws -> any SyncTransport
    }

    private func backends() throws -> [Backend] {
        let root = temporaryDirectory()
        let store = InMemorySyncStore()
        var backends = [
            Backend(name: "in-memory") { _ in
                InMemorySyncTransport(scope: "contract", store: store, pageSize: 2)
            },
        ]

        let server = try FakeCloudKitServer(directory: root.appending(path: "cloudkit"))
        backends.append(Backend(name: "cloudkit") { device in
            let transport = try await CloudKitSyncTransport.makeNotebook(
                services: server.services,
                containerIdentifier: server.containerIdentifier,
                stateDirectory: root.appending(path: "cloudkit-\(device)")
            )
            self.addTeardownBlock { await transport.retire() }
            return transport
        })

        if let endpoint = ProcessInfo.processInfo.environment["MEH_NOTEBOOK_HTTP_URL"],
           let url = URL(string: endpoint), url.host == "127.0.0.1" {
            let workspace = "contract-\(UUID().uuidString)"
            backends.append(Backend(name: "local-http") { _ in
                LocalSyncTransport(
                    baseURL: url, workspace: workspace, pageSize: 2, protocolVersion: 2
                )
            })
        }
        return backends
    }

    /// Runs the check on every backend with a fresh remote, reporting each
    /// backend's failure separately.
    private func forEachBackend(
        _ check: (Backend) async throws -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        for backend in try backends() {
            do {
                try await check(backend)
            } catch {
                XCTFail("\(backend.name): \(error)", file: file, line: line)
            }
        }
    }

    // MARK: - Helpers

    private func drain(_ transport: any SyncTransport) async throws -> [SyncRecord] {
        try await drainWithCursor(transport, after: nil).records
    }

    private func drainWithCursor(
        _ transport: any SyncTransport, after start: String?
    ) async throws -> (records: [SyncRecord], cursor: String?) {
        var cursor = start
        var records: [SyncRecord] = []
        for _ in 0..<100 {
            let page = try await transport.fetch(after: cursor)
            records += page.records
            cursor = page.cursor
            if !page.hasMore { return (records, cursor) }
        }
        throw SyncError.unavailable("Fetch exceeded the page bound")
    }

    private func synchronize(
        _ coordinator: NotebookSyncCoordinator, _ backend: Backend
    ) async throws {
        await coordinator.synchronize()
        if case .failed(let message) = coordinator.status {
            throw SyncError.unavailable("\(backend.name) sync failed: \(message)")
        }
    }
}

/// A notebook catalog listing two notes, with one record per note body.
private struct Fixture {
    let notebookID = UUID()
    let catalogDocument: NotebookCatalogDocument
    let catalog: SyncRecord
    let notes: [SyncRecord]

    init() throws {
        let documents = try ["First fictional note\n", "Second fictional note\n"].map {
            try NoteDocument(text: $0)
        }
        catalogDocument = try NotebookCatalogDocument(notebookID: notebookID)
        for (index, document) in documents.enumerated() {
            _ = try catalogDocument.add(
                id: document.noteID, kind: .note, name: "Fictional \(index)"
            )
        }
        catalog = SyncRecord(catalog: catalogDocument.snapshot())
        let notebookID = notebookID
        notes = documents.map {
            SyncRecord(snapshot: $0.snapshot(), notebookID: notebookID)
        }
    }

    func deletionMarker(for note: SyncRecord) throws -> SyncRecord {
        try catalogDocument.markPermanentlyDeleted([note.snapshot.noteID])
        return SyncRecord(catalog: catalogDocument.snapshot())
    }

    /// A record whose ID does not match its content.
    func forged() throws -> SyncRecord {
        let data = try JSONEncoder().encode(notes[0])
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object["id"] = String(repeating: "0", count: 64)
        return try JSONDecoder().decode(
            SyncRecord.self, from: JSONSerialization.data(withJSONObject: object)
        )
    }
}
