import Automerge
import CloudKit
import Foundation
import TestSupport
import XCTest

@testable import NoteCore

/// One damaged item, in iCloud or on this device, must not stop the rest of
/// the notebook from syncing.
@MainActor
final class SyncDamageRecoveryTests: XCTestCase {
    private var root: URL!
    private var server: FakeCloudKitServer!
    private let notebookID = UUID()

    override func setUp() async throws {
        root = temporaryDirectory()
        server = try FakeCloudKitServer(directory: root)
    }

    // MARK: Unreadable iCloud records

    func testUnreadableCloudRecordIsSkippedAndTheRestArrives() async throws {
        let catalog = try makeCatalog()
        let notes = try (0..<3).map { try makeNote("note \($0)") }
        let writer = try await open("writer")
        _ = try await writer.bootstrap(proposing: catalog)
        _ = try await writer.publishBatch([notes[0]])
        let damaged = try await plantDamagedRecord()
        _ = try await writer.publishBatch(Array(notes[1...]))

        let reader = try await open("reader")
        _ = try await reader.bootstrap(proposing: catalog)
        let received = try await fetchAll(reader)
        XCTAssertEqual(Set(received.map(\.id)), Set(notes.map(\.id) + [catalog.id]))
        XCTAssertEqual(try unreadableRecordIDs("reader"), [damaged])
        let halt = await reader.haltStatus()
        XCTAssertNil(halt)
        // The device still uploads.
        let own = try makeNote("written after the damaged record")
        let result = try await reader.publishBatch([own])
        XCTAssertNil(result.error)
        XCTAssertEqual(result.acknowledgedIDs, [own.id])
    }

    func testSkippedRecordIsReadAgainAfterARelaunch() async throws {
        let catalog = try makeCatalog()
        let note = try makeNote("readable after an update")
        let writer = try await open("writer")
        _ = try await writer.bootstrap(proposing: catalog)
        // Looks damaged to this device until it is replaced below, as a
        // record from a newer app does until the app is updated.
        try await plantDamagedRecord(named: note.id)

        let reader = try await open("reader")
        _ = try await reader.bootstrap(proposing: catalog)
        var received = try await fetchAll(reader)
        XCTAssertFalse(received.contains(note))
        XCTAssertEqual(try unreadableRecordIDs("reader"), [note.id])

        server.deleteRecord(named: note.id)
        _ = try await writer.publishBatch([note])
        await reader.retire()
        let relaunched = try await open("reader")
        received = try await fetchAll(relaunched)
        XCTAssertTrue(received.contains(note))
        XCTAssertEqual(try unreadableRecordIDs("reader"), [])
    }

    func testSkippedRecordThatWasDeletedIsForgotten() async throws {
        let catalog = try makeCatalog()
        let writer = try await open("writer")
        _ = try await writer.bootstrap(proposing: catalog)
        let damaged = try await plantDamagedRecord()
        let reader = try await open("reader")
        _ = try await reader.bootstrap(proposing: catalog)
        _ = try await fetchAll(reader)
        XCTAssertEqual(try unreadableRecordIDs("reader"), [damaged])

        server.deleteRecord(named: damaged)
        _ = try await fetchAll(reader)
        XCTAssertEqual(try unreadableRecordIDs("reader"), [])
        let halt = await reader.haltStatus()
        XCTAssertNil(halt, "Its removal needs no proof of a covering copy")
    }

    func testMissingAssetFileIsRetriedInsteadOfSkipped() throws {
        let note = try makeNote("its file did not arrive")
        let codec = CloudKitRecordCodec(mode: .notebook, zoneID: server.zoneID)
        let file = root.appending(path: "asset")
        try note.snapshot.data.write(to: file)
        let record = try codec.encode(
            note, id: CKRecord.ID(recordName: note.id, zoneID: server.zoneID),
            assetURL: file
        )
        XCTAssertEqual(try codec.decode(record), note)
        try FileManager.default.removeItem(at: file)
        XCTAssertThrowsError(try codec.decode(record)) {
            XCTAssertEqual($0 as? CloudKitSyncTransportError, .assetUnavailable)
        }
        XCTAssertEqual(
            NotebookSyncRetryPolicy.isTransient(CloudKitSyncTransportError.assetUnavailable),
            true
        )
    }

    // MARK: Damaged local sync state

    func testDamagedLocalCloudStateIsRebuiltFromICloud() async throws {
        let catalog = try makeCatalog()
        let notes = try (0..<3).map { try makeNote("note \($0)") }
        let writer = try await open("writer")
        _ = try await writer.bootstrap(proposing: catalog)
        _ = try await writer.publishBatch(notes)
        let reader = try await open("reader")
        _ = try await reader.bootstrap(proposing: catalog)
        _ = try await fetchAll(reader)
        await reader.retire()

        try Data("not json".utf8).write(to: stateURL("reader"))
        let reopened = try await open("reader")
        // Through the protocol, as the app reads them for its event log.
        let events = await (reopened as any SyncTransport).recoveryEvents()
        XCTAssertEqual(events, ["damaged cloud sync state rebuilt"])
        _ = try await reopened.bootstrap(proposing: catalog)
        let received = try await fetchAll(reopened)
        XCTAssertEqual(Set(received.map(\.id)), Set(notes.map(\.id) + [catalog.id]))
    }

    func testRebuiltStateDoesNotRecreateADeletedZone() async throws {
        let catalog = try makeCatalog()
        let device = try await open("device")
        _ = try await device.bootstrap(proposing: catalog)
        await device.retire()
        try Data("not json".utf8).write(to: stateURL("device"))
        server.deleteZone()

        var reopened = try await open("device")
        do {
            _ = try await reopened.bootstrap(proposing: catalog)
            XCTFail("Seeded iCloud again after its data was deleted")
        } catch {
            XCTAssertEqual(error as? CloudKitSyncTransportError, .unexpectedDeletion)
        }
        XCTAssertEqual(server.recordNames, [])

        // Damaged again while paused: the rebuilt state is the only sign
        // that this device had joined.
        await reopened.retire()
        var state = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: stateURL("device"))) as? [String: Any])
        XCTAssertEqual(state["rebuiltAfterJoining"] as? Bool, true)
        state["inbox"] = "damaged"
        try JSONSerialization.data(withJSONObject: state).write(to: stateURL("device"))
        reopened = try await open("device")
        do {
            _ = try await reopened.bootstrap(proposing: catalog)
            XCTFail("Seeded iCloud again after a second rebuild")
        } catch {
            XCTAssertEqual(error as? CloudKitSyncTransportError, .unexpectedDeletion)
        }
        XCTAssertEqual(server.recordNames, [])
    }

    func testDamagedEngineStateIsReplacedAndQueuedUploadsStillGoOut() async throws {
        let catalog = try makeCatalog()
        let note = try makeNote("queued before the damage")
        let device = try await open("device")
        _ = try await device.bootstrap(proposing: catalog)
        server.setOffline(true)
        _ = try? await device.publishBatch([note])
        server.setOffline(false)
        await device.retire()

        var state = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: stateURL("device"))) as? [String: Any])
        state["engineState"] = Data("not engine state".utf8).base64EncodedString()
        try JSONSerialization.data(withJSONObject: state).write(to: stateURL("device"))

        let reopened = try await open("device")
        // Through the protocol, as the app reads them for its event log.
        let events = await (reopened as any SyncTransport).recoveryEvents()
        XCTAssertEqual(events, ["damaged cloud engine state rebuilt"])
        let result = try await reopened.publishBatch([note])
        XCTAssertNil(result.error)
        XCTAssertTrue(server.recordNames.contains(note.id))
    }

    func testDamagedCoordinatorStateIsRebuilt() async throws {
        let store = InMemorySyncStore()
        let directory = root.appending(path: "notebook")
        let replica = NotebookReplica(directory: directory)
        try await replica.createLocalNotebook()
        let id = try await replica.createNote(name: "Kept.md", text: "kept")
        let coordinator = NotebookSyncCoordinator(
            replica: replica, transport: InMemorySyncTransport(scope: "shared", store: store))
        await coordinator.synchronize()
        XCTAssertNil(coordinator.lastError)

        let state = directory.appending(path: "notebook-sync-state.json")
        try Data("{".utf8).write(to: state)
        await coordinator.synchronize()
        XCTAssertNil(coordinator.lastError)
        XCTAssertTrue(try coordinator.hasDurableBinding())
        let note = try await replica.openNote(id)
        XCTAssertEqual(note.text, "kept")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("notebook-sync-state.json.damaged-") }.count, 1)
    }

    // MARK: Damaged local notes

    func testDamagedNoteIsRepairedFromSyncAndOtherNotesKeepSyncing() async throws {
        let store = InMemorySyncStore()
        let first = try await device("first", store: store)
        let damagedID = try await first.replica.createNote(name: "Damaged.md", text: "from sync")
        let otherID = try await first.replica.createNote(name: "Other.md", text: "one")
        await first.coordinator.synchronize()
        var second = try await device("second", store: store)
        await second.coordinator.synchronize()
        XCTAssertNil(second.coordinator.lastError)

        let files = second.directory.appending(path: "notes/\(damagedID.uuidString)")
        for name in ["note.automerge", "note.previous.automerge"] {
            let file = files.appending(path: name)
            if FileManager.default.fileExists(atPath: file.path) {
                try Data("damaged".utf8).write(to: file)
            }
        }
        let other = try await first.replica.openNote(otherID)
        try other.replaceAll(with: "one two")
        try await other.flush()
        await first.coordinator.synchronize()

        second = try await device("second", store: store)
        await second.coordinator.synchronize()
        XCTAssertNil(second.coordinator.lastError)
        let repaired = try await second.replica.openNote(damagedID)
        XCTAssertEqual(repaired.text, "from sync")
        let received = try await second.replica.openNote(otherID)
        XCTAssertEqual(received.text, "one two")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: files.path)
            .contains { $0.hasPrefix("note.quarantine-") }, "The damaged bytes are kept")
    }

    func testOpenDamagedNoteIsRepairedFromSyncWithoutARelaunch() async throws {
        let store = InMemorySyncStore()
        let first = try await device("first", store: store)
        let damagedID = try await first.replica.createNote(name: "Damaged.md", text: "from sync")
        await first.coordinator.synchronize()
        var second = try await device("second", store: store)
        await second.coordinator.synchronize()
        let files = second.directory.appending(path: "notes/\(damagedID.uuidString)")
        for name in ["note.automerge", "note.previous.automerge"] {
            try Data("damaged".utf8).write(to: files.appending(path: name))
        }

        second = try await device("second", store: store)
        // The app opens a note that can't be loaded to offer recovery.
        let session = try await second.replica.openNote(damagedID, allowingRecovery: true)
        XCTAssertFalse(session.isEditingEnabled)
        await second.coordinator.synchronize()
        XCTAssertNil(second.coordinator.lastError)
        XCTAssertTrue(session.isEditingEnabled)
        XCTAssertEqual(session.text, "from sync")
    }

    func testDamagedNoteThatNeverSyncedIsNamedAndOthersStillSync() async throws {
        let store = InMemorySyncStore()
        var writer = try await device("writer", store: store)
        let damagedID = try await writer.replica.createNote(name: "Only here.md", text: "local")
        let otherID = try await writer.replica.createNote(name: "Other.md", text: "synced")
        let files = writer.directory.appending(path: "notes/\(damagedID.uuidString)")
        try Data("damaged".utf8).write(to: files.appending(path: "note.automerge"))
        writer = try await device("writer", store: store)

        await writer.coordinator.synchronize()
        let failure = try XCTUnwrap(writer.coordinator.lastError as? NotebookUnreadableNotes)
        XCTAssertEqual(failure.noteIDs, [damagedID])
        XCTAssertEqual(failure.names, ["Only here.md"])
        let presentation = SyncFailurePresentation(
            error: failure, retryWillOccurAutomatically: false)
        XCTAssertEqual(String(localized: presentation.title), "A note can't be read")
        XCTAssertFalse(NotebookSyncEventLog.errorCode(failure).contains("Only here"))

        let reader = try await device("reader", store: store)
        await reader.coordinator.synchronize()
        let received = try await reader.replica.openNote(otherID)
        XCTAssertEqual(received.text, "synced")
    }

    func testReceivedVersionRepairsOnlyKnownDamage() async throws {
        let note = try NoteDocument(text: "saved")
        let older = note.snapshot()
        try note.replaceAll(with: "saved and edited")
        let newer = note.snapshot()
        let remote = try NoteDocument(snapshot: older).fork()
        try remote.replaceAll(with: "saved, then changed elsewhere")

        // A damaged current file with a valid previous one keeps both sides.
        var directory = root.appending(path: "previous")
        var storage = NoteFileStorage(directory: directory)
        try await storage.save(older)
        try await storage.save(newer)
        try Data("damaged".utf8).write(to: storage.currentURL)
        var merged = try await storage.merge(remote.snapshot())
        XCTAssertTrue(merged)
        guard case .current(let repaired) = await storage.load() else {
            return XCTFail("The note was not repaired")
        }
        let expected = try NoteDocument(snapshot: older)
        try expected.merge(remote)
        XCTAssertEqual(try NoteDocument(snapshot: repaired).text, try expected.text)

        // A file a newer app wrote is not damage and is left alone.
        directory = root.appending(path: "newer")
        storage = NoteFileStorage(directory: directory)
        try await storage.save(older)
        let future = Document(textEncoding: .unicodeScalar)
        try future.put(obj: .ROOT, key: "noteID", value: .String(note.noteID.uuidString))
        try future.put(obj: .ROOT, key: "schemaVersion", value: .Uint(2))
        _ = try future.putObject(obj: .ROOT, key: "text", ty: .Text)
        let unsupported = future.save()
        try unsupported.write(to: storage.currentURL)
        merged = try await storage.merge(remote.snapshot())
        XCTAssertFalse(merged)
        XCTAssertEqual(try Data(contentsOf: storage.currentURL), unsupported)
    }

    // MARK: Helpers

    private struct Device {
        let directory: URL
        let replica: NotebookReplica
        let coordinator: NotebookSyncCoordinator
    }

    /// Opens the notebook again, as after a relaunch.
    private func device(_ name: String, store: InMemorySyncStore) async throws -> Device {
        let directory = root.appending(path: name)
        let replica = NotebookReplica(directory: directory)
        try await replica.load()
        if replica.catalogSnapshot == nil { try await replica.createNotebookForSync() }
        return Device(
            directory: directory, replica: replica,
            coordinator: NotebookSyncCoordinator(
                replica: replica, transport: InMemorySyncTransport(scope: "shared", store: store))
        )
    }

    private func open(_ device: String) async throws -> CloudKitSyncTransport {
        try await CloudKitSyncTransport.makeNotebook(
            services: server.services,
            containerIdentifier: server.containerIdentifier,
            stateDirectory: root.appending(path: device)
        )
    }

    private func stateURL(_ device: String) -> URL {
        root.appending(path: device).appending(path: "cloudkit-sync-state.json")
    }

    private func unreadableRecordIDs(_ device: String) throws -> Set<String> {
        let state = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: stateURL(device))) as? [String: Any])
        return Set(state["unreadableRecordIDs"] as? [String] ?? [])
    }

    private func fetchAll(_ transport: CloudKitSyncTransport) async throws -> [SyncRecord] {
        var cursor: String?
        var records: [SyncRecord] = []
        while true {
            let page = try await transport.fetch(after: cursor)
            records += page.records
            cursor = page.cursor
            if !page.hasMore { return records }
        }
    }

    /// Stores a record whose content does not match its name.
    @discardableResult
    private func plantDamagedRecord(named name: String? = nil) async throws -> String {
        let name = name ?? String(repeating: "ab", count: 32)
        let file = root.appending(path: "damaged-\(UUID().uuidString)")
        try Data("not an Automerge document".utf8).write(to: file)
        let record = CKRecord(
            recordType: CloudKitTransportMode.notebook.recordType,
            recordID: CKRecord.ID(recordName: name, zoneID: server.zoneID)
        )
        record["snapshotID"] = name
        record["protocolVersion"] = NSNumber(value: 2)
        record["kind"] = SyncDocumentKind.note.rawValue
        record["notebookID"] = notebookID.uuidString
        record["documentID"] = UUID().uuidString
        record["heads"] = try JSONEncoder().encode(Set<String>())
        record["document"] = CKAsset(fileURL: file)
        _ = try await server.save(record)
        return name
    }

    private func makeCatalog() throws -> SyncRecord {
        SyncRecord(catalog: try NotebookCatalogDocument(notebookID: notebookID).snapshot())
    }

    private func makeNote(_ text: String) throws -> SyncRecord {
        let document = try NoteDocument(noteID: UUID())
        try document.replaceAll(with: text)
        return SyncRecord(snapshot: document.snapshot(), notebookID: notebookID)
    }
}
