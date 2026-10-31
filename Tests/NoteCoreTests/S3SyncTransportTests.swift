import Foundation
import TestSupport
import XCTest

@testable import NoteCore

/// S3-specific behavior beyond the shared transport contract.
@MainActor
final class S3SyncTransportTests: XCTestCase {
    private let credentials = S3Credentials(
        accessKeyID: "AKIAIOSFODNN7EXAMPLE",
        secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
    )

    func testSignatureMatchesTheAWSExample() throws {
        // "Example: GET Object" from the AWS Signature Version 4 docs.
        let authorization = S3Signer.authorization(
            method: "GET",
            url: try XCTUnwrap(URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")),
            headers: [
                "Host": "examplebucket.s3.amazonaws.com",
                "Range": "bytes=0-9",
                "x-amz-content-sha256": S3Signer.emptyPayloadHash,
                "x-amz-date": "20130524T000000Z",
            ],
            payloadHash: S3Signer.emptyPayloadHash,
            credentials: credentials, region: "us-east-1", amzDate: "20130524T000000Z"
        )
        XCTAssertEqual(
            authorization,
            "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, "
                + "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, "
                + "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
        )
    }

    func testConfigurationBuildsAddressesAndScopes() throws {
        let aws = S3SyncConfiguration(
            endpoint: "https://s3.eu-central-1.amazonaws.com/", region: "eu-central-1",
            bucket: "notes", prefix: "/meh/"
        )
        XCTAssertEqual(
            try aws.url(forKey: "meh/a b.json").absoluteString,
            "https://notes.s3.eu-central-1.amazonaws.com/meh/a%20b.json"
        )
        XCTAssertEqual(aws.scope, "s3://aws/notes/meh")
        var otherRegion = aws
        otherRegion.endpoint = "https://s3.amazonaws.com"
        XCTAssertEqual(otherRegion.scope, aws.scope)

        let minio = S3SyncConfiguration(
            endpoint: "http://192.168.1.20:9000", region: "us-east-1", bucket: "notes"
        )
        XCTAssertEqual(
            try minio.url(forKey: "k", query: [("prefix", "a/"), ("list-type", "2")])
                .absoluteString,
            "http://192.168.1.20:9000/notes/k?list-type=2&prefix=a%2F"
        )
        XCTAssertEqual(minio.scope, "s3://192.168.1.20:9000/notes/")
        XCTAssertTrue(minio.usesUnencryptedConnection)

        for invalid in [
            S3SyncConfiguration(endpoint: "http://s3.example.com", region: "us-east-1", bucket: "notes"),
            S3SyncConfiguration(endpoint: "https://s3.example.com", region: "", bucket: "notes"),
            S3SyncConfiguration(endpoint: "https://s3.example.com", region: "auto", bucket: "No"),
            S3SyncConfiguration(
                endpoint: "https://s3.example.com", region: "auto", bucket: "notes", prefix: "a/../b"
            ),
            S3SyncConfiguration(endpoint: "https://u:p@s3.example.com", region: "auto", bucket: "notes"),
        ] {
            XCTAssertThrowsError(try invalid.validate(), invalid.endpoint)
        }
    }

    func testBootstrapWithoutConditionalWritesStillAgreesOnTheStoredSeed() async throws {
        for mode in [FakeS3Server.ConditionalWrites.notImplemented, .ignored] {
            let server = FakeS3Server()
            server.conditionalWrites = mode
            let first = transport(server, device: "first")
            let second = transport(server, device: "second")
            let seed = try Fixture.catalog()
            let stored = try await first.bootstrap(proposing: seed)
            let joined = try await second.bootstrap(proposing: try Fixture.catalog())
            XCTAssertEqual(stored, seed)
            XCTAssertEqual(joined, seed)
            let report = try await first.checkConnection()
            XCTAssertFalse(report.supportsConditionalWrites)
            XCTAssertEqual(report.existingNotebookID, seed.notebookID)
        }
    }

    func testConnectionCheckReportsConditionalWritesAndLeavesNoObject() async throws {
        let server = FakeS3Server()
        let report = try await transport(server, device: "check").checkConnection()
        XCTAssertTrue(report.supportsConditionalWrites)
        XCTAssertNil(report.existingNotebookID)
        // The check removes its object in the background.
        let deadline = ContinuousClock.now + .seconds(5)
        while !server.keys(bucket: "notes").isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(server.keys(bucket: "notes"), [])
    }

    func testNewerFormatPausesSyncForAnUpdate() async throws {
        let server = FakeS3Server()
        server.setObject(
            Data(#"{"minimumReaderVersion":99,"minimumWriterVersion":99}"#.utf8),
            bucket: "notes", key: "meh/meh-notebook/format.json"
        )
        do {
            _ = try await transport(server, device: "old").fetch(after: nil)
            XCTFail("Fetched despite a newer format")
        } catch {
            XCTAssertEqual(error as? SyncError, .updateRequired(requiredVersion: 99))
        }
    }

    func testPurgedBodiesStayDeletedWhenAStaleDevicePublishesThem() async throws {
        let server = FakeS3Server()
        let catalog = try NotebookCatalogDocument()
        let note = try NoteDocument(text: "Fictional deleted note\n")
        _ = try catalog.add(id: note.noteID, kind: .note, name: "Deleted")
        let notebookID = catalog.snapshot().notebookID
        let body = SyncRecord(snapshot: note.snapshot(), notebookID: notebookID)

        let stale = transport(server, device: "stale")
        let cleaner = transport(server, device: "cleaner")
        _ = try await stale.bootstrap(proposing: SyncRecord(catalog: catalog.snapshot()))
        _ = try await cleaner.fetch(after: nil)
        try await cleaner.purgeDeletedNotes([note.noteID], notebookID: notebookID)
        // The stale device has not fetched since the purge.
        try await stale.publish(body)

        let reader = transport(server, device: "reader")
        let page = try await reader.fetch(after: nil)
        XCTAssertFalse(page.records.contains(body))
        _ = try await reader.cleanupRedundantSnapshots(notebookID: notebookID)
        XCTAssertEqual(
            server.keys(bucket: "notes", prefix: "meh/meh-notebook/records/"
                + note.noteID.uuidString.lowercased()), []
        )
    }

    func testCleanupKeepsOnlyCoveringSnapshotsAndPeersStillConverge() async throws {
        let server = FakeS3Server()
        let root = temporaryDirectory()
        let left = NotebookReplica(directory: root.appending(path: "left"))
        let right = NotebookReplica(directory: root.appending(path: "right"))
        let leftTransport = transport(server, device: "left", root: root)
        let a = NotebookSyncCoordinator(replica: left, transport: leftTransport)
        let b = NotebookSyncCoordinator(
            replica: right, transport: transport(server, device: "right", root: root)
        )
        await a.synchronize()
        let id = try await left.createNote(name: "Draft.md", text: "one")
        await a.synchronize()
        let note = try await left.openNote(id)
        for word in [" two", " three", " four"] {
            try note.replaceText(in: NSRange(location: (note.text as NSString).length, length: 0),
                                 with: word)
            try await note.flush()
            await a.synchronize()
        }
        let prefix = "meh/meh-notebook/records/" + id.uuidString.lowercased()
        XCTAssertEqual(server.keys(bucket: "notes", prefix: prefix).count, 4)

        let status = try await leftTransport.snapshotMaintenanceStatus(
            notebookID: try XCTUnwrap(left.catalogSnapshot?.notebookID)
        )
        XCTAssertEqual(status?.hasPendingCleanup, true)
        let report = try await a.cleanupSnapshots()
        XCTAssertEqual(report.deletedSnapshotCount, 3 + 0, "older note snapshots")
        XCTAssertEqual(server.keys(bucket: "notes", prefix: prefix).count, 1)

        await b.synchronize()
        XCTAssertEqual(b.status.isExchanged, true)
        let received = try await right.openNote(id)
        XCTAssertEqual(received.text, "one two three four")
    }

    func testOnlyStoredRecordsAreAcknowledgedAndRetrySucceeds() async throws {
        let server = FakeS3Server()
        let fixture = try Fixture()
        let writer = transport(server, device: "writer")
        _ = try await writer.bootstrap(proposing: fixture.catalog)
        server.failNextPuts(1)
        let result = try await writer.publishBatch(fixture.notes)
        XCTAssertNotNil(result.error)
        XCTAssertEqual(result.acknowledgedIDs.count, 1, "the other record was logged")
        let retry = try await writer.publishBatch(fixture.notes)
        XCTAssertNil(retry.error)
        XCTAssertEqual(retry.acknowledgedIDs, Set(fixture.notes.map(\.id)))
        let reader = transport(server, device: "reader")
        let received = try await reader.fetch(after: nil).records
        XCTAssertEqual(Set(received.map(\.id)), Set(([fixture.catalog] + fixture.notes).map(\.id)))
    }

    func testOfflineFailuresAreTemporaryAndAccessErrorsNeedAttention() async throws {
        let server = FakeS3Server()
        server.offline = true
        do {
            _ = try await transport(server, device: "offline").fetch(after: nil)
            XCTFail("Fetched while offline")
        } catch {
            let presentation = SyncFailurePresentation(error: error, retryWillOccurAutomatically: true)
            XCTAssertEqual(presentation.retryDisposition, .automatic)
        }
        let denied = SyncFailurePresentation(
            error: S3SyncTransportError.requestFailed(status: 403, code: "SignatureDoesNotMatch"),
            retryWillOccurAutomatically: true
        )
        XCTAssertEqual(String(localized: denied.title), "S3 access denied")
        XCTAssertEqual(denied.retryDisposition, .manual)
        let busy = S3SyncTransportError.requestFailed(status: 503, code: "SlowDown")
        let busyPresentation = SyncFailurePresentation(error: busy, retryWillOccurAutomatically: true)
        XCTAssertEqual(busyPresentation.retryDisposition, .automatic)
        XCTAssertEqual(
            String(localized: busyPresentation.message),
            "A temporary network or S3 storage problem stopped sync."
        )
        XCTAssertEqual(NotebookSyncRetryPolicy.isTransient(busy), true)
        XCTAssertEqual(
            NotebookSyncEventLog.errorCode(busy), "S3SyncTransportError.requestFailed.503.SlowDown"
        )
    }

    func testRestoredCopyOfADeviceDoesNotOverwriteItsLog() async throws {
        let server = FakeS3Server()
        let fixture = try Fixture()
        let root = temporaryDirectory()
        let original = transport(server, device: "phone", root: root)
        _ = try await original.bootstrap(proposing: fixture.catalog)
        try await original.publish(fixture.catalog)
        // A restored backup starts from the same saved device state.
        let copy = root.appending(path: "s3-restored")
        try FileManager.default.copyItem(at: root.appending(path: "s3-phone"), to: copy)
        let restored = S3SyncTransport(
            configuration: S3SyncConfiguration(
                endpoint: server.endpoint, region: "us-east-1", bucket: "notes", prefix: "meh"
            ),
            credentials: credentials, stateDirectory: copy, session: server.session
        )

        try await original.publish(fixture.notes[0])
        try await restored.publish(fixture.notes[1])

        let reader = transport(server, device: "reader")
        let received = Set(try await reader.fetch(after: nil).records.map(\.id))
        XCTAssertTrue(received.isSuperset(of: fixture.notes.map(\.id)))
    }

    func testCleanupKeepsALoggedSnapshotWhenTheNewerOneWasNeverLogged() async throws {
        let server = FakeS3Server()
        let catalog = try NotebookCatalogDocument()
        let note = try NoteDocument(text: "one")
        _ = try catalog.add(id: note.noteID, kind: .note, name: "Draft")
        let notebookID = catalog.snapshot().notebookID
        let first = SyncRecord(snapshot: note.snapshot(), notebookID: notebookID)
        let writer = transport(server, device: "writer")
        _ = try await writer.bootstrap(proposing: SyncRecord(catalog: catalog.snapshot()))
        try await writer.publish(first)
        try note.replaceUTF16(range: NSRange(location: 3, length: 0), with: " two")
        let newer = SyncRecord(snapshot: note.snapshot(), notebookID: notebookID)
        // The body was stored, but its log entry never was.
        server.setObject(
            try JSONEncoder().encode(newer), bucket: "notes",
            key: "meh/meh-notebook/records/\(note.noteID.uuidString.lowercased())/\(newer.id).json"
        )

        let report = try await writer.cleanupRedundantSnapshots(notebookID: notebookID)
        XCTAssertEqual(report.deletedSnapshotCount, 0)
        let reader = transport(server, device: "reader")
        let received = try await reader.fetch(after: nil).records
        XCTAssertTrue(received.contains(first))
    }

    func testPurgeSkipsNotesThatAreAlreadyPurged() async throws {
        let server = FakeS3Server()
        let fixture = try Fixture()
        let writer = transport(server, device: "writer")
        _ = try await writer.bootstrap(proposing: fixture.catalog)
        let id = fixture.notes[0].snapshot.noteID
        let notebookID = try XCTUnwrap(fixture.catalog.notebookID)
        try await writer.purgeDeletedNotes([id], notebookID: notebookID)
        let before = server.requests.count
        try await writer.purgeDeletedNotes([id], notebookID: notebookID)
        let repeated = server.requests.dropFirst(before)
        XCTAssertFalse(repeated.contains { $0.hasPrefix("PUT") || $0.hasPrefix("DELETE") })
    }

    func testSetupWritesTheFormatRecordAfterAnEarlierFailure() async throws {
        let server = FakeS3Server()
        let fixture = try Fixture()
        _ = try await transport(server, device: "first").bootstrap(proposing: fixture.catalog)
        let format = try XCTUnwrap(server.keys(bucket: "notes").first { $0.hasSuffix("format.json") })
        // The first device stored the seed but failed before the format.
        server.setObject(nil, bucket: "notes", key: format)
        _ = try await transport(server, device: "second").bootstrap(proposing: fixture.catalog)
        XCTAssertNotNil(server.object(bucket: "notes", key: format))
    }

    func testPlainHTTPIsOnlyAcceptedForLocalAddresses() {
        XCTAssertTrue(S3SyncConfiguration.isLocalNetwork("192.168.1.20"))
        XCTAssertTrue(S3SyncConfiguration.isLocalNetwork("10.0.0.1"))
        XCTAssertFalse(S3SyncConfiguration.isLocalNetwork("10.0.0.1.example.com"))
        XCTAssertFalse(S3SyncConfiguration.isLocalNetwork("8.8.8.8"))
    }

    func testCursorFromAnotherBucketIsRejected() async throws {
        let server = FakeS3Server()
        let fixture = try Fixture()
        let first = transport(server, device: "first")
        _ = try await first.bootstrap(proposing: fixture.catalog)
        let cursor = try await first.fetch(after: nil).cursor
        let other = S3SyncTransport(
            configuration: S3SyncConfiguration(
                endpoint: server.endpoint, region: "us-east-1", bucket: "notes", prefix: "other"
            ),
            credentials: credentials, stateDirectory: temporaryDirectory(), session: server.session
        )
        do {
            _ = try await other.fetch(after: cursor)
            XCTFail("Accepted a foreign cursor")
        } catch {
            XCTAssertEqual(error as? SyncError, .invalidCursor)
        }
    }

    // MARK: - Helpers

    private func transport(
        _ server: FakeS3Server, device: String, root: URL? = nil
    ) -> S3SyncTransport {
        S3SyncTransport(
            configuration: S3SyncConfiguration(
                endpoint: server.endpoint, region: "us-east-1", bucket: "notes", prefix: "meh"
            ),
            credentials: credentials,
            stateDirectory: (root ?? temporaryDirectory()).appending(path: "s3-\(device)"),
            session: server.session
        )
    }

    private struct Fixture {
        let catalog: SyncRecord
        let notes: [SyncRecord]

        init() throws {
            let document = try NotebookCatalogDocument()
            let notebookID = document.snapshot().notebookID
            let bodies = try ["First fictional note\n", "Second fictional note\n"].map {
                try NoteDocument(text: $0)
            }
            for (index, body) in bodies.enumerated() {
                _ = try document.add(id: body.noteID, kind: .note, name: "Fictional \(index)")
            }
            catalog = SyncRecord(catalog: document.snapshot())
            notes = bodies.map { SyncRecord(snapshot: $0.snapshot(), notebookID: notebookID) }
        }

        static func catalog() throws -> SyncRecord {
            SyncRecord(catalog: try NotebookCatalogDocument().snapshot())
        }
    }
}

private extension NotebookSyncCoordinator.Status {
    var isExchanged: Bool { if case .exchanged = self { true } else { false } }
}
