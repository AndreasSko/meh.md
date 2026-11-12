import Foundation
import SmithyRetriesAPI
import TestSupport
import XCTest

@testable import NoteCore
@testable import NoteCoreAWS

/// S3-specific behavior beyond the shared transport contract.
@MainActor
final class S3SyncTransportTests: XCTestCase {
    private let credentials = S3Credentials(
        accessKeyID: "AKIAIOSFODNN7EXAMPLE",
        secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
    )

    func testConfigurationBuildsAddressesAndScopes() throws {
        let aws = S3SyncConfiguration(
            endpoint: "https://s3.eu-central-1.amazonaws.com/", region: "eu-central-1",
            bucket: "notes", prefix: "/meh/"
        )
        XCTAssertEqual(aws.scope, "s3://aws/notes/meh")
        var otherRegion = aws
        otherRegion.endpoint = "https://s3.amazonaws.com"
        XCTAssertEqual(otherRegion.scope, aws.scope)

        let minio = S3SyncConfiguration(
            endpoint: "http://192.168.1.20:9000", region: "us-east-1", bucket: "notes"
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

    func testAWSAddressesUseVirtualHostedBuckets() async throws {
        let server = FakeS3Server(host: "notes.s3.eu-central-1.amazonaws.com")
        let transport = transport(server, configuration: S3SyncConfiguration(
            endpoint: "https://s3.eu-central-1.amazonaws.com", region: "eu-central-1",
            bucket: "notes", prefix: "meh"
        ))
        _ = try? await transport.fetch(after: nil)
        XCTAssertEqual(server.requests.first, "GET /meh/meh-notebook/format.json")
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
        server.failNextPuts(AWSS3Client.maxAttempts, prefix: "meh/meh-notebook/records/"
            + fixture.notes[0].snapshot.noteID.uuidString.lowercased())
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
        let busyPresentation = SyncFailurePresentation(
            error: busy, retryWillOccurAutomatically: true, storageName: "S3"
        )
        XCTAssertEqual(busyPresentation.retryDisposition, .automatic)
        XCTAssertEqual(String(localized: busyPresentation.title), "Can't reach S3")
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

    /// The replies Backblaze B2 sent while a notebook moved to it.
    func testBusyOrFailingRequestsAreRetried() async throws {
        let server = FakeS3Server()
        let fixture = try Fixture()
        let writer = transport(server, device: "writer")
        _ = try await writer.bootstrap(proposing: fixture.catalog)
        server.failNextPuts(2, with: .init(status: 500, code: "InternalError"))
        try await writer.publish(fixture.notes[0])
        server.failNextPuts(2, with: .init(status: 503, code: "ServiceUnavailable"))
        try await writer.publish(fixture.notes[1])
        server.failNextPuts(1)
        try await writer.publish(fixture.catalog)

        let received = try await transport(server, device: "reader").fetch(after: nil).records
        XCTAssertTrue(Set(received.map(\.id)).isSuperset(of: fixture.notes.map(\.id)))
    }

    func testProxyErrorsWithoutAnS3CodeAreRetriedAndTemporary() async throws {
        let server = FakeS3Server()
        let fixture = try Fixture()
        let writer = transport(server, device: "writer")
        _ = try await writer.bootstrap(proposing: fixture.catalog)
        server.failNextPuts(1, with: .init(status: 503, body: ""))
        try await writer.publish(fixture.notes[0])

        let gateway = "<html><body><h1>502 Bad Gateway</h1><hr><center>nginx</center>"
        server.failNextPuts(5, with: .init(status: 502, body: gateway))
        do {
            try await writer.publish(fixture.notes[1])
            XCTFail("Published although every attempt failed")
        } catch {
            XCTAssertEqual(error as? S3SyncTransportError, .requestFailed(status: 502, code: "HTTP502"))
            XCTAssertTrue(NotebookSyncRetryPolicy.isTransient(error))
        }
    }

    func testRetriesStopAfterFiveAttempts() async throws {
        let server = FakeS3Server()
        let fixture = try Fixture()
        let writer = transport(server, device: "writer")
        _ = try await writer.bootstrap(proposing: fixture.catalog)
        let notebookID = try XCTUnwrap(fixture.catalog.notebookID)
        let id = fixture.notes[0].snapshot.noteID

        server.failNextPuts(5)
        let before = server.requests.count
        do {
            try await writer.purgeDeletedNotes([id], notebookID: notebookID)
            XCTFail("Purged although every attempt failed")
        } catch S3SyncTransportError.requestFailed(503, "SlowDown") {}
        XCTAssertEqual(server.requests.dropFirst(before).filter { $0.hasPrefix("PUT") }.count, 5)
        try await writer.purgeDeletedNotes([id], notebookID: notebookID)
    }

    func testRetriedLogWriteThatWasStoredKeepsTheDeviceID() async throws {
        let server = FakeS3Server()
        let fixture = try Fixture()
        let writer = transport(server, device: "writer")
        _ = try await writer.bootstrap(proposing: fixture.catalog)
        try await writer.publish(fixture.notes[0])
        let devices = { Set(server.keys(bucket: "notes", prefix: "meh/meh-notebook/log/")
            .map { $0.split(separator: "/")[3] }) }
        XCTAssertEqual(devices().count, 1)

        // The log entry is stored, but its reply is lost.
        server.failNextPuts(
            1, with: .init(status: 500, code: "InternalError", afterStoring: true),
            prefix: "meh/meh-notebook/log/"
        )
        try await writer.publish(fixture.notes[1])
        XCTAssertEqual(devices().count, 1)
    }

    func testPurgeListsStoredBodiesOnceForManyNotes() async throws {
        let server = FakeS3Server()
        let fixture = try Fixture()
        let writer = transport(server, device: "writer")
        _ = try await writer.bootstrap(proposing: fixture.catalog)
        try await writer.publish(fixture.notes[0])
        let notebookID = try XCTUnwrap(fixture.catalog.notebookID)
        let deleted = Set((0..<40).map { _ in UUID() } + [fixture.notes[0].snapshot.noteID])

        let before = server.requests.count
        try await writer.purgeDeletedNotes(deleted, notebookID: notebookID)
        let listings = server.requests.dropFirst(before).filter { $0 == "GET /notes" }
        XCTAssertEqual(listings.count, 2, "purged markers and stored bodies")
        XCTAssertEqual(
            server.keys(bucket: "notes", prefix: "meh/meh-notebook/records/"
                + fixture.notes[0].snapshot.noteID.uuidString.lowercased()), []
        )
        XCTAssertEqual(
            server.keys(bucket: "notes", prefix: "meh/meh-notebook/purged/").count, deleted.count
        )
    }

    func testPurgeReportsProgressAndBusyReplies() async throws {
        let server = FakeS3Server()
        let fixture = try Fixture()
        let writer = transport(server, device: "writer")
        _ = try await writer.bootstrap(proposing: fixture.catalog)
        let notebookID = try XCTUnwrap(fixture.catalog.notebookID)
        let events = Recorder<(String, [String: Int])>()
        let progress = Recorder<SyncCleanupProgress>()
        await writer.setDiagnosticsHandler { await events.append(($0, $1)) }
        await writer.setCleanupProgressHandler { await progress.append($0) }

        server.failNextPuts(3, prefix: "meh/meh-notebook/purged/")
        try await writer.purgeDeletedNotes(Set((0..<120).map { _ in UUID() }), notebookID: notebookID)

        let logged = await events.items
        XCTAssertEqual(
            logged.filter { $0.0 == "s3_purge_progress" }.map { $0.1["done"] }, [50, 100]
        )
        XCTAssertEqual(logged.last?.0, "s3_purge")
        XCTAssertEqual(logged.last?.1, ["notes": 120, "busy": 3])
        let reported = await progress.items
        XCTAssertEqual(reported.first?.completedCount, 0)
        XCTAssertEqual(reported.last?.completedCount, 120)
        XCTAssertEqual(reported.last?.totalCount, 120)
    }

    func testBodiesLeftByAFailedPurgeAreDeletedOnTheNextOne() async throws {
        let server = FakeS3Server()
        let fixture = try Fixture()
        let root = temporaryDirectory()
        let writer = transport(server, device: "writer", root: root)
        _ = try await writer.bootstrap(proposing: fixture.catalog)
        try await writer.publish(fixture.notes[0])
        let notebookID = try XCTUnwrap(fixture.catalog.notebookID)
        let id = fixture.notes[0].snapshot.noteID
        let bodies = "meh/meh-notebook/records/" + id.uuidString.lowercased()

        server.failNextDeletes(AWSS3Client.maxAttempts, prefix: bodies)
        do {
            try await writer.purgeDeletedNotes([id], notebookID: notebookID)
            XCTFail("Purged although every delete failed")
        } catch {}
        XCTAssertNotEqual(server.keys(bucket: "notes", prefix: bodies), [])

        // The marker is stored, yet the next pass, here after a restart,
        // still removes the bodies.
        let restarted = transport(server, device: "writer", root: root)
        _ = try await restarted.fetch(after: nil)
        try await restarted.purgeDeletedNotes([id], notebookID: notebookID)
        XCTAssertEqual(server.keys(bucket: "notes", prefix: bodies), [])
        let before = server.requests.count
        try await restarted.purgeDeletedNotes([id], notebookID: notebookID)
        XCTAssertFalse(server.requests.dropFirst(before).contains { $0.hasPrefix("PUT") })
    }

    func testDeviceStateSavedBeforeUnsweptStillLoads() async throws {
        let server = FakeS3Server()
        let fixture = try Fixture()
        let root = temporaryDirectory()
        let writer = transport(server, device: "writer", root: root)
        _ = try await writer.bootstrap(proposing: fixture.catalog)
        let state = root.appending(path: "s3-writer/s3-device.json")
        try FileManager.default.createDirectory(
            at: state.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // The format 0.25.0 saved, before `unswept` was added.
        let legacy = """
            {"version":1,"scope":"\(writer.scope)","deviceID":"legacy-device",
             "nextSequence":7,"snapshotCounts":{},"retainedBytes":0,
             "hasNewSnapshots":false}
            """
        try Data(legacy.utf8).write(to: state)

        let reopened = transport(server, device: "writer", root: root)
        try await reopened.publish(fixture.notes[0])
        XCTAssertTrue(server.keys(bucket: "notes", prefix: "meh/meh-notebook/log/")
            .contains("meh/meh-notebook/log/legacy-device/00000000000000000007.json"))
    }

    func testPurgeOfAFewNotesListsOnlyTheirFolders() async throws {
        let server = FakeS3Server()
        let fixture = try Fixture()
        let writer = transport(server, device: "writer")
        _ = try await writer.bootstrap(proposing: fixture.catalog)
        try await writer.publishBatch(fixture.notes).error.map { throw $0 }
        let notebookID = try XCTUnwrap(fixture.catalog.notebookID)
        let id = fixture.notes[0].snapshot.noteID

        let before = server.requests.count
        try await writer.purgeDeletedNotes([id], notebookID: notebookID)
        XCTAssertEqual(server.requests.dropFirst(before).filter { $0 == "GET /notes" }.count, 2)
        XCTAssertEqual(
            server.keys(bucket: "notes", prefix: "meh/meh-notebook/records/"
                + id.uuidString.lowercased()), []
        )
        XCTAssertNotEqual(
            server.keys(bucket: "notes", prefix: "meh/meh-notebook/records/"
                + fixture.notes[1].snapshot.noteID.uuidString.lowercased()), []
        )
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

    func testRegionIsReadFromAWSAddresses() {
        let region = S3SyncConfiguration.awsRegion(inEndpoint:)
        XCTAssertEqual(region("https://s3.eu-central-1.amazonaws.com"), "eu-central-1")
        XCTAssertEqual(region("https://s3.dualstack.us-west-2.amazonaws.com/"), "us-west-2")
        XCTAssertEqual(region("https://s3-ap-southeast-2.amazonaws.com"), "ap-southeast-2")
        XCTAssertEqual(region("https://s3.amazonaws.com"), "us-east-1")
        XCTAssertEqual(region("https://my-notes-2.s3.eu-west-1.amazonaws.com"), "eu-west-1")
        XCTAssertNil(region("http://192.168.1.20:9000"))
        XCTAssertNil(region("https://eu-central-1.example.com"))
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

    func testWipedStorageIsUploadedAgain() async throws {
        let server = FakeS3Server()
        let root = temporaryDirectory()
        let replica = NotebookReplica(directory: root.appending(path: "left"))
        var coordinator = NotebookSyncCoordinator(
            replica: replica, transport: transport(server, device: "left", root: root)
        )
        await coordinator.synchronize()
        let id = try await replica.createNote(name: "Kept.md", text: "still here")
        await coordinator.synchronize()
        XCTAssertTrue(coordinator.status.isExchanged)

        for key in server.keys(bucket: "notes") {
            server.setObject(nil, bucket: "notes", key: key)
        }
        // After a relaunch the device finds the folder empty.
        coordinator = NotebookSyncCoordinator(
            replica: replica, transport: transport(server, device: "left", root: root)
        )
        await coordinator.synchronize()
        XCTAssertTrue(coordinator.status.isExchanged)

        let fresh = NotebookReplica(directory: root.appending(path: "fresh"))
        let joining = NotebookSyncCoordinator(
            replica: fresh, transport: transport(server, device: "fresh", root: root)
        )
        await joining.synchronize()
        XCTAssertTrue(joining.status.isExchanged)
        let received = try await fresh.openNote(id)
        XCTAssertEqual(received.text, "still here")
    }

    func testDocumentsThatLostEveryCopyAreUploadedAgainWithinADay() async throws {
        let server = FakeS3Server()
        let root = temporaryDirectory()
        let replica = NotebookReplica(directory: root.appending(path: "left"))
        var coordinator = NotebookSyncCoordinator(
            replica: replica, transport: transport(server, device: "left", root: root)
        )
        await coordinator.synchronize()
        let id = try await replica.createNote(name: "Expired.md", text: "expired")
        await coordinator.synchronize()
        let prefix = "meh/meh-notebook/records/" + id.uuidString.lowercased()
        // For example a lifecycle rule that expires old objects.
        for key in server.keys(bucket: "notes", prefix: prefix) {
            server.setObject(nil, bucket: "notes", key: key)
        }

        // Checked recently: one listing a day is enough.
        await coordinator.synchronize()
        XCTAssertEqual(server.keys(bucket: "notes", prefix: prefix), [])

        let stateURL = root.appending(path: "s3-left/s3-device.json")
        var state = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: stateURL)) as? [String: Any])
        let checked = try XCTUnwrap(state["lastVerified"] as? Double)
        state["lastVerified"] = checked - 25 * 60 * 60
        try JSONSerialization.data(withJSONObject: state).write(to: stateURL)
        coordinator = NotebookSyncCoordinator(
            replica: replica, transport: transport(server, device: "left", root: root)
        )
        await coordinator.synchronize()
        XCTAssertTrue(coordinator.status.isExchanged)
        XCTAssertEqual(server.keys(bucket: "notes", prefix: prefix).count, 1)
    }

    func testLostDocumentIsUploadedAgainWithoutARelaunch() async throws {
        let server = FakeS3Server()
        let root = temporaryDirectory()
        let configuration = S3SyncConfiguration(
            endpoint: server.endpoint, region: "us-east-1", bucket: "notes", prefix: "meh"
        )
        let replica = NotebookReplica(directory: root.appending(path: "left"))
        // Checks on every exchange, so the same transport that uploaded
        // the note is the one that finds it missing.
        let coordinator = NotebookSyncCoordinator(replica: replica, transport: S3SyncTransport(
            configuration: configuration,
            client: AWSS3Client(
                configuration: configuration, credentials: credentials,
                session: server.session, timeout: 30,
                maxAttempts: AWSS3Client.maxAttempts, retryBackoff: NoBackoff()
            ),
            stateDirectory: root.appending(path: "s3-left"), verificationInterval: 0
        ))
        await coordinator.synchronize()
        let id = try await replica.createNote(name: "Lost.md", text: "lost")
        await coordinator.synchronize()
        let prefix = "meh/meh-notebook/records/" + id.uuidString.lowercased()
        for key in server.keys(bucket: "notes", prefix: prefix) {
            server.setObject(nil, bucket: "notes", key: key)
        }

        await coordinator.synchronize()
        XCTAssertTrue(coordinator.status.isExchanged)
        XCTAssertEqual(server.keys(bucket: "notes", prefix: prefix).count, 1)
    }

    func testStorageWipedWhileTheAppStaysOpenKeepsItsNotebook() async throws {
        let server = FakeS3Server()
        let root = temporaryDirectory()
        let configuration = S3SyncConfiguration(
            endpoint: server.endpoint, region: "us-east-1", bucket: "notes", prefix: "meh"
        )
        let replica = NotebookReplica(directory: root.appending(path: "left"))
        let coordinator = NotebookSyncCoordinator(replica: replica, transport: S3SyncTransport(
            configuration: configuration,
            client: AWSS3Client(
                configuration: configuration, credentials: credentials,
                session: server.session, timeout: 30,
                maxAttempts: AWSS3Client.maxAttempts, retryBackoff: NoBackoff()
            ),
            stateDirectory: root.appending(path: "s3-left"), verificationInterval: 0
        ))
        await coordinator.synchronize()
        let id = try await replica.createNote(name: "Kept.md", text: "still here")
        await coordinator.synchronize()
        let notebookID = try XCTUnwrap(replica.catalogSnapshot?.notebookID)

        for key in server.keys(bucket: "notes") {
            server.setObject(nil, bucket: "notes", key: key)
        }
        await coordinator.synchronize()
        XCTAssertTrue(coordinator.status.isExchanged)
        XCTAssertNotNil(server.object(bucket: "notes", key: "meh/meh-notebook/seed.json"))
        XCTAssertNotNil(server.object(bucket: "notes", key: "meh/meh-notebook/format.json"))

        let fresh = NotebookReplica(directory: root.appending(path: "fresh"))
        let joining = NotebookSyncCoordinator(
            replica: fresh, transport: transport(server, device: "fresh", root: root)
        )
        await joining.synchronize()
        XCTAssertTrue(joining.status.isExchanged)
        XCTAssertEqual(fresh.catalogSnapshot?.notebookID, notebookID)
        let received = try await fresh.openNote(id)
        XCTAssertEqual(received.text, "still here")
    }

    func testUnreadableRecordIsSkippedAndReadAgainAfterARelaunch() async throws {
        let server = FakeS3Server()
        let fixture = try Fixture()
        let root = temporaryDirectory()
        let writer = transport(server, device: "writer")
        _ = try await writer.bootstrap(proposing: fixture.catalog)
        try await writer.publishBatch(fixture.notes).error.map { throw $0 }
        let damaged = fixture.notes[0]
        let key = "meh/meh-notebook/records/"
            + damaged.snapshot.noteID.uuidString.lowercased() + "/\(damaged.id).json"
        let intact = try XCTUnwrap(server.object(bucket: "notes", key: key))
        server.setObject(Data("damaged".utf8), bucket: "notes", key: key)

        let reader = transport(server, device: "reader", root: root)
        let page = try await reader.fetch(after: nil)
        XCTAssertEqual(Set(page.records.map(\.id)), [fixture.catalog.id, fixture.notes[1].id])
        XCTAssertFalse(page.hasMore)

        // Readable now, as a record from a newer app is after an update.
        server.setObject(intact, bucket: "notes", key: key)
        let relaunched = transport(server, device: "reader", root: root)
        let next = try await relaunched.fetch(after: page.cursor)
        XCTAssertEqual(next.records, [damaged])
        // Applying that page failed, so the coordinator asks again with the
        // cursor it had, on this launch or the next.
        let again = try await relaunched.fetch(after: page.cursor)
        XCTAssertEqual(again.records, [damaged])
        let afterCrash = try await transport(server, device: "reader", root: root)
            .fetch(after: page.cursor)
        XCTAssertEqual(afterCrash.records, [damaged])
        let last = try await transport(server, device: "reader", root: root)
            .fetch(after: afterCrash.cursor)
        XCTAssertEqual(last.records, [])
        let afterRelaunch = try await transport(server, device: "reader", root: root)
            .fetch(after: last.cursor)
        XCTAssertEqual(afterRelaunch.records, [])
    }

    func testReplayFromTheStartDeliversThisDevicesOwnUploads() async throws {
        let server = FakeS3Server()
        let fixture = try Fixture()
        let device = transport(server)
        _ = try await device.bootstrap(proposing: fixture.catalog)
        let first = try await device.fetch(after: nil)
        try await device.publishBatch(fixture.notes).error.map { throw $0 }
        // A later page leaves out what this device just stored.
        let next = try await device.fetch(after: first.cursor)
        XCTAssertEqual(next.records, [])
        // A replay repairs a damaged note from this device's latest upload.
        let replay = try await device.fetch(after: nil)
        XCTAssertEqual(
            Set(replay.records.map(\.id)),
            Set(([fixture.catalog] + fixture.notes).map(\.id))
        )
        // Offered again, it is stored again rather than assumed present.
        let result = try await device.publishBatch(fixture.notes)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.acknowledgedIDs, Set(fixture.notes.map(\.id)))
    }

    func testFailedRetryOfAnUnreadableRecordIsTriedAgainWithoutARelaunch() async throws {
        let server = FakeS3Server()
        let fixture = try Fixture()
        let root = temporaryDirectory()
        let writer = transport(server, device: "writer")
        _ = try await writer.bootstrap(proposing: fixture.catalog)
        try await writer.publishBatch(fixture.notes).error.map { throw $0 }
        let damaged = fixture.notes[0]
        let key = "meh/meh-notebook/records/"
            + damaged.snapshot.noteID.uuidString.lowercased() + "/\(damaged.id).json"
        let intact = try XCTUnwrap(server.object(bucket: "notes", key: key))
        server.setObject(Data("damaged".utf8), bucket: "notes", key: key)
        let page = try await transport(server, device: "reader", root: root).fetch(after: nil)
        server.setObject(intact, bucket: "notes", key: key)

        let relaunched = transport(server, device: "reader", root: root)
        server.failNextGets(
            1, with: .init(status: 403, code: "AccessDenied"), prefix: key)
        do {
            _ = try await relaunched.fetch(after: page.cursor)
            XCTFail("The download should fail")
        } catch {}
        let next = try await relaunched.fetch(after: page.cursor)
        XCTAssertEqual(next.records, [damaged])
    }

    func testAnotherNotebookSetUpInAWipedFolderStopsTheOpenDevice() async throws {
        let server = FakeS3Server()
        let root = temporaryDirectory()
        let replica = NotebookReplica(directory: root.appending(path: "left"))
        let coordinator = NotebookSyncCoordinator(
            replica: replica, transport: transport(server, device: "left", root: root)
        )
        await coordinator.synchronize()
        _ = try await replica.createNote(name: "Kept.md", text: "still here")
        await coordinator.synchronize()
        XCTAssertTrue(coordinator.status.isExchanged)
        for key in server.keys(bucket: "notes") {
            server.setObject(nil, bucket: "notes", key: key)
        }

        // A device with its own notes sets up sync before this one notices.
        let other = NotebookReplica(directory: root.appending(path: "other"))
        let otherCoordinator = NotebookSyncCoordinator(
            replica: other, transport: transport(server, device: "other", root: root)
        )
        await otherCoordinator.synchronize()
        _ = try await other.createNote(name: "Other.md", text: "another notebook")
        await otherCoordinator.synchronize()
        XCTAssertTrue(otherCoordinator.status.isExchanged)
        XCTAssertNotEqual(other.catalogSnapshot?.notebookID, replica.catalogSnapshot?.notebookID)
        let stored = server.keys(bucket: "notes")

        _ = try await replica.createNote(name: "Later.md", text: "written after the wipe")
        await coordinator.synchronize()
        XCTAssertEqual(coordinator.lastError as? SyncError, .identityConflict)
        XCTAssertEqual(server.keys(bucket: "notes"), stored, "nothing of this notebook is written")
        await coordinator.synchronize()
        XCTAssertEqual(coordinator.lastError as? SyncError, .identityConflict)
        XCTAssertEqual(server.keys(bucket: "notes"), stored)
    }

    func testSeedStoredByAnotherDeviceDuringRestoreStopsThisOne() async throws {
        let server = FakeS3Server()
        let fixture = try Fixture()
        let device = transport(server, device: "left")
        _ = try await device.bootstrap(proposing: fixture.catalog)
        for key in server.keys(bucket: "notes") {
            server.setObject(nil, bucket: "notes", key: key)
        }
        let other = try Fixture()
        server.storeBeforeNextPut(
            try JSONEncoder().encode(other.catalog),
            bucket: "notes", key: "meh/meh-notebook/seed.json")

        do {
            try await device.beginExchange()
            XCTFail("Restored the seed over another notebook")
        } catch {
            XCTAssertEqual(error as? SyncError, .identityConflict)
        }
        do {
            try await device.publish(fixture.notes[0])
            XCTFail("Published into another notebook")
        } catch {}
        XCTAssertEqual(server.keys(bucket: "notes", prefix: "meh/meh-notebook/log/"), [])
        let seed = try JSONDecoder().decode(SyncRecord.self, from: XCTUnwrap(
            server.object(bucket: "notes", key: "meh/meh-notebook/seed.json")))
        XCTAssertEqual(seed.notebookID, other.catalog.notebookID)
    }

    func testUnreadableLogEntryDoesNotHideLaterOnes() async throws {
        let server = FakeS3Server()
        let fixture = try Fixture()
        let writer = transport(server, device: "writer")
        _ = try await writer.bootstrap(proposing: fixture.catalog)
        try await writer.publish(fixture.notes[0])
        try await writer.publish(fixture.notes[1])
        let first = try XCTUnwrap(
            server.keys(bucket: "notes", prefix: "meh/meh-notebook/log/").sorted().first)
        server.setObject(Data("damaged".utf8), bucket: "notes", key: first)

        let received = try await transport(server, device: "reader").fetch(after: nil).records
        XCTAssertEqual(Set(received.map(\.id)), [fixture.catalog.id, fixture.notes[1].id])
    }

    func testDamagedDeviceStateStartsANewLog() async throws {
        let server = FakeS3Server()
        let fixture = try Fixture()
        let root = temporaryDirectory()
        let writer = transport(server, device: "writer", root: root)
        _ = try await writer.bootstrap(proposing: fixture.catalog)
        try await writer.publish(fixture.notes[0])
        try Data("{".utf8).write(to: root.appending(path: "s3-writer/s3-device.json"))

        let reopened = transport(server, device: "writer", root: root)
        try await reopened.publish(fixture.notes[1])
        let logs = Set(server.keys(bucket: "notes", prefix: "meh/meh-notebook/log/")
            .map { $0.split(separator: "/")[3] })
        XCTAssertEqual(logs.count, 2, "the new log leaves the old entries in place")
        let received = try await transport(server, device: "reader").fetch(after: nil).records
        XCTAssertTrue(Set(received.map(\.id)).isSuperset(of: fixture.notes.map(\.id)))
    }

    func testFormatRecordOfAnotherShapeNeedsAnUpdate() async throws {
        let cases: [(String, SyncError)] = [
            (#"{"format":{"reader":3}}"#, .updateRequired(
                requiredVersion: NotebookSyncFormat.supportedVersion + 1)),
            ("damaged", .invalidRecord),
        ]
        for (body, expected) in cases {
            let server = FakeS3Server()
            server.setObject(
                Data(body.utf8), bucket: "notes", key: "meh/meh-notebook/format.json")
            do {
                _ = try await transport(server, device: "old").fetch(after: nil)
                XCTFail("Fetched despite an unknown format record")
            } catch {
                XCTAssertEqual(error as? SyncError, expected, body)
            }
        }
    }

    // MARK: - Helpers

    private func transport(
        _ server: FakeS3Server, device: String = "device", root: URL? = nil,
        configuration: S3SyncConfiguration? = nil
    ) -> S3SyncTransport {
        let configuration = configuration ?? S3SyncConfiguration(
            endpoint: server.endpoint, region: "us-east-1", bucket: "notes", prefix: "meh"
        )
        return S3SyncTransport(
            configuration: configuration,
            client: AWSS3Client(
                configuration: configuration, credentials: credentials,
                session: server.session, timeout: 30,
                maxAttempts: AWSS3Client.maxAttempts, retryBackoff: NoBackoff()
            ),
            stateDirectory: (root ?? temporaryDirectory()).appending(path: "s3-\(device)")
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

private actor Recorder<Item: Sendable> {
    private(set) var items: [Item] = []
    func append(_ item: Item) { items.append(item) }
}

/// Retries at once, so tests of failing requests stay fast.
private struct NoBackoff: RetryBackoffStrategy {
    func computeNextBackoffDelay(attempt: Int) -> TimeInterval { 0 }
}

private extension NotebookSyncCoordinator.Status {
    var isExchanged: Bool { if case .exchanged = self { true } else { false } }
}
