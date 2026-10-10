import CloudKit
import Foundation
import XCTest

@testable import NoteCore

final class CloudKitSnapshotCleanupDeletionRaceTests: XCTestCase {
    @MainActor
    func testPermanentPurgeAfterReadWithImmediateNotification() async throws {
        try await permanentPurgeRace(beforeDelete: false, notifyWhilePaused: true)
    }

    @MainActor
    func testPermanentPurgeAfterReadWithDelayedNotification() async throws {
        try await permanentPurgeRace(beforeDelete: false, notifyWhilePaused: false)
    }

    @MainActor
    func testPermanentPurgeImmediatelyBeforeDeleteDispatch() async throws {
        try await permanentPurgeRace(beforeDelete: true, notifyWhilePaused: false)
    }

    @MainActor
    private func permanentPurgeRace(
        beforeDelete: Bool, notifyWhilePaused: Bool
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "CleanupDeletionRace-\(UUID())"
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try FakeCloudKitServer(directory: root)
        let fixture = try fixture()
        let gate = CloudKitRaceGate()
        let database = CloudKitRaceDatabase(
            base: server,
            afterRead: beforeDelete ? nil : (fixture.current.id, gate),
            beforeDelete: beforeDelete ? (fixture.old.id, gate) : nil
        )
        let cleaner = try await open(
            "cleaner", root: root, server: server,
            services: database.services(base: server.services)
        )
        _ = try await cleaner.bootstrap(proposing: fixture.catalog)
        try await publish([fixture.old, fixture.current, fixture.sibling], to: cleaner)
        _ = try await drain(cleaner)
        let purger = try await open("purger", root: root, server: server)
        _ = try await purger.bootstrap(proposing: fixture.catalog)
        _ = try await drain(purger)

        let pending = Task {
            try await cleaner.cleanupRedundantSnapshots(notebookID: fixture.notebookID)
        }
        do {
            try await gate.waitUntilPaused()
            XCTAssertTrue(server.recordNames.contains(fixture.current.id))
            let catalog = try NotebookCatalogDocument(
                snapshot: XCTUnwrap(fixture.catalog.catalogSnapshot)
            )
            try catalog.markPermanentlyDeleted([fixture.noteID])
            let marker = SyncRecord(catalog: catalog.snapshot())
            // Match production ordering: remotely acknowledge the permanent
            // catalog marker before removing any note body.
            try await publish([marker], to: purger)
            XCTAssertTrue(server.recordNames.contains(marker.id))
            try await purger.purgeDeletedNotes(
                [fixture.noteID], notebookID: fixture.notebookID
            )
            XCTAssertFalse(server.recordNames.contains(fixture.old.id))
            XCTAssertFalse(server.recordNames.contains(fixture.current.id))
            XCTAssertTrue(server.recordNames.contains(fixture.sibling.id))
            if notifyWhilePaused {
                // Fetch actual server modifications and deletion events while
                // the successful survivor read is waiting to return to cleanup.
                let received = try await drain(cleaner)
                XCTAssertTrue(received.contains(marker))
            }
            await gate.release()
            let report = try await pending.value
            // With delayed notification, DELETE returns unknownItem. It must
            // complete the intention without reporting a successful deletion.
            XCTAssertEqual(report.deletedSnapshotCount, 0)
        } catch {
            pending.cancel()
            await gate.release()
            _ = try? await pending.value
            throw error
        }

        let attempts = await database.deletionAttempts()
        XCTAssertEqual(attempts, notifyWhilePaused ? [] : [[fixture.old.id]])
        _ = try await drain(cleaner)
        let halt = await cleaner.haltStatus()
        XCTAssertNil(halt)
        try await assertReplicaConverges(
            cleaner, name: "cleaner-replica", fixture: fixture, root: root
        )
        await cleaner.retire()

        let restarted = try await open("cleaner", root: root, server: server)
        try await assertReplicaConverges(
            restarted, name: "cleaner-replica", fixture: fixture, root: root
        )
        // The acknowledged permanent deletion survives restarting both local
        // stores. Replaying the cached old bodies cannot upload them again.
        try await publish([fixture.old, fixture.current], to: restarted)
        let repeated = try await restarted.cleanupRedundantSnapshots(
            notebookID: fixture.notebookID
        )
        XCTAssertEqual(repeated.deletedSnapshotCount, 0)
        let restartedHalt = await restarted.haltStatus()
        XCTAssertNil(restartedHalt)
        XCTAssertFalse(server.recordNames.contains(fixture.old.id))
        XCTAssertFalse(server.recordNames.contains(fixture.current.id))
        XCTAssertTrue(server.recordNames.contains("canonical-notebook-v2"))
        XCTAssertTrue(server.recordNames.contains(fixture.sibling.id))

        let fresh = try await open("fresh", root: root, server: server)
        _ = try await fresh.bootstrap(proposing: fixture.catalog)
        let received = try await drain(fresh)
        XCTAssertFalse(received.contains {
            $0.kind == .note && $0.snapshot.noteID == fixture.noteID
        })
        let markedCatalogs = try received.compactMap(\.catalogSnapshot).map {
            try NotebookCatalogDocument(snapshot: $0)
        }
        XCTAssertTrue(try markedCatalogs.contains {
            try $0.items().contains { $0.id == fixture.noteID && $0.isPermanentlyDeleted }
        })
        let sibling = try XCTUnwrap(received.first {
            $0.kind == .note && $0.snapshot.noteID == fixture.sibling.snapshot.noteID
        })
        let expected = try NoteDocument(snapshot: fixture.sibling.snapshot)
        let restored = try NoteDocument(snapshot: sibling.snapshot)
        XCTAssertEqual(try restored.text, try expected.text)
        XCTAssertEqual(try restored.historyVersions(), try expected.historyVersions())
        XCTAssertEqual(try restored.historyVersions().map(restored.historicalText(for:)),
                       try expected.historyVersions().map(expected.historicalText(for:)))
        try await assertReplicaConverges(
            fresh, name: "fresh-replica", fixture: fixture, root: root
        )
        await purger.retire()
        await restarted.retire()
        await fresh.retire()
    }

    @MainActor
    private func assertReplicaConverges(
        _ transport: CloudKitSyncTransport, name: String,
        fixture: Fixture, root: URL
    ) async throws {
        let replica = NotebookReplica(directory: root.appending(path: name))
        let coordinator = NotebookSyncCoordinator(replica: replica, transport: transport)
        await coordinator.synchronize()
        XCTAssertNil(coordinator.lastError)
        guard case .exchanged = coordinator.status else {
            XCTFail("Permanent deletion must converge: \(coordinator.status)")
            return
        }
        XCTAssertTrue(try replica.deletedIDs.contains(fixture.noteID))
        XCTAssertFalse(replica.placements.contains { $0.item.id == fixture.noteID })
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: replica.directory.appending(path: "notes/\(fixture.noteID.uuidString)").path
        ))
        let sibling = try await replica.openNote(fixture.sibling.snapshot.noteID)
        XCTAssertEqual(sibling.text, "Fictional unrelated final\n")
    }

    private struct Fixture {
        let notebookID: UUID
        let noteID: UUID
        let catalog: SyncRecord
        let old: SyncRecord
        let current: SyncRecord
        let sibling: SyncRecord
    }

    private func fixture() throws -> Fixture {
        let notebookID = UUID()
        let note = try NoteDocument(text: "Fictional removal draft\n")
        let old = SyncRecord(snapshot: note.snapshot(), notebookID: notebookID)
        try note.replaceAll(with: "Fictional removal final\n")
        let current = SyncRecord(snapshot: note.snapshot(), notebookID: notebookID)
        let sibling = try NoteDocument(text: "Fictional unrelated draft\n")
        try sibling.replaceAll(with: "Fictional unrelated final\n")
        let siblingRecord = SyncRecord(snapshot: sibling.snapshot(), notebookID: notebookID)
        let catalog = try NotebookCatalogDocument(notebookID: notebookID)
        _ = try catalog.add(id: note.noteID, kind: .note, name: "Fictional removal")
        _ = try catalog.add(id: sibling.noteID, kind: .note, name: "Fictional unrelated")
        return Fixture(notebookID: notebookID, noteID: note.noteID,
                       catalog: SyncRecord(catalog: catalog.snapshot()),
                       old: old, current: current, sibling: siblingRecord)
    }

    @MainActor
    private func open(
        _ device: String, root: URL, server: FakeCloudKitServer,
        services: CloudKitServices? = nil
    ) async throws -> CloudKitSyncTransport {
        try await CloudKitSyncTransport.makeNotebook(
            services: services ?? server.services,
            containerIdentifier: server.containerIdentifier,
            stateDirectory: root.appending(path: device)
        )
    }

    @MainActor
    private func publish(_ records: [SyncRecord], to transport: CloudKitSyncTransport)
        async throws {
        let result = try await transport.publishBatch(records)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.acknowledgedIDs, Set(records.map(\.id)))
    }

    @MainActor
    private func drain(_ transport: CloudKitSyncTransport) async throws -> [SyncRecord] {
        var cursor: String?
        var records: [SyncRecord] = []
        for _ in 0..<30 {
            let page = try await transport.fetch(after: cursor)
            records += page.records
            cursor = page.cursor
            if !page.hasMore { return records }
        }
        throw SyncError.unavailable("Purge race fetch exceeded page bound")
    }
}
