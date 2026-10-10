import CloudKit
import Foundation
import XCTest

@testable import NoteCore

@MainActor
final class CloudKitLegacyDeletionRecoveryTests: XCTestCase {
    nonisolated(unsafe) private var root: URL!
    nonisolated(unsafe) private var server: FakeCloudKitServer!
    private let migration = CloudKitSyncStateMigration.legacySnapshotDeletionHalt

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "LegacyDeletionRecovery-\(UUID())"
        )
        server = try FakeCloudKitServer(directory: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testUpgradeAfterCleanupRecoversAutomaticallyAndKeepsOfflineEdits() async throws {
        let fixture = try await fixture(publishLatest: false)
        let replica = NotebookReplica(directory: root.appending(path: "local-notebook"))
        let before = NotebookSyncCoordinator(replica: replica, transport: fixture.receiver)
        await before.synchronize()
        XCTAssertNil(before.lastError)
        let editor = try await replica.openNote(fixture.noteID)
        try editor.replaceText(in: NSRange(location: 0, length: 0),
                               with: "Fictional unsynced iPad edit\n")
        try await replica.flushOpenNotes()
        let checkpoints = root.appending(path: "local-notebook/notebook-sync-state.json")
        let checkpointBytes = try Data(contentsOf: checkpoints)
        let offlineSnapshot = try XCTUnwrap(editor.currentSnapshot)
        let offlineText = editor.text
        XCTAssertTrue(offlineText.hasPrefix("Fictional unsynced iPad edit\n"))
        await fixture.receiver.retire()
        try await publish([fixture.latestNote, fixture.latestCatalog], to: fixture.writer)
        try await retireSnapshots(fixture)
        let original = try saveLegacyHalt()
        let originalCursor = try original.page(after: nil, limit: original.inbox.count).cursor
        let cloudBefore = server.recordNames
        let mutations = server.mutationCount

        let recovered = try await open("receiver")
        let didRecover = await recovered.recoveredLegacySnapshotDeletionHalt
        XCTAssertTrue(didRecover)
        assertNil(await recovered.haltStatus())
        XCTAssertEqual(server.recordNames, cloudBefore)
        XCTAssertEqual(server.mutationCount, mutations, "Recovery must be read-only")
        XCTAssertEqual(try Data(contentsOf: checkpoints), checkpointBytes)
        let saved = try state()
        XCTAssertFalse(saved.hasUnexpectedDeletion)
        XCTAssertTrue(saved.completedSyncStateMigrations.contains(migration))
        XCTAssertEqual(saved.inboxGeneration, original.inboxGeneration)
        XCTAssertEqual(saved.engineState, original.engineState)
        XCTAssertEqual(saved.outbox, original.outbox)
        XCTAssertEqual(saved.deletedNoteIDs, original.deletedNoteIDs)
        XCTAssertEqual(saved.purgedRecordIDs, original.purgedRecordIDs)
        XCTAssertNoThrow(try saved.page(after: originalCursor, limit: 100))
        XCTAssertEqual(try JSONDecoder().decode(CloudKitTransportState.self,
            from: Data(contentsOf: backupURL)), original)

        let resumed = NotebookSyncCoordinator(replica: replica, transport: recovered)
        await resumed.synchronize()
        XCTAssertNil(resumed.lastError)
        let current = try await replica.openNote(fixture.noteID)
        XCTAssertTrue(current.text.hasPrefix("Fictional unsynced iPad edit\n"))
        let persisted = try await replica.persistedNoteSnapshots()
        let restored = try NoteDocument(snapshot: XCTUnwrap(persisted.first { $0.noteID == fixture.noteID }))
        XCTAssertTrue(fixture.oldNote.snapshot.heads.isSubset(of: restored.historyHeads))
        XCTAssertTrue(offlineSnapshot.heads.isSubset(of: restored.historyHeads))
        XCTAssertTrue(try restored.historyVersions().map(restored.historicalText(for:))
            .contains(offlineText))
        await recovered.retire()
        let reads = server.directRecordReads.count
        let restarted = try await open("receiver")
        assertFalse(await restarted.recoveredLegacySnapshotDeletionHalt)
        XCTAssertEqual(server.directRecordReads.count, reads, "Completed recovery must not rerun")
        await restarted.retire()
    }

    func testPendingUploadAndItsExactBytesSurviveRecovery() async throws {
        let fixture = try await fixture()
        let offline = try NoteDocument(snapshot: fixture.oldNote.snapshot)
        try offline.replaceAll(with: "Fictional queued edit")
        let pending = SyncRecord(snapshot: offline.snapshot(), notebookID: fixture.notebookID)
        server.inject(.failSave(.networkUnavailable) { $0.recordName == pending.id })
        let result = try await fixture.receiver.publishBatch([pending])
        XCTAssertNotNil(result.error)
        await fixture.receiver.retire()
        try await retireSnapshots(fixture)
        let original = try saveLegacyHalt()
        XCTAssertEqual(original.outbox[pending.id], pending)
        let mutations = server.mutationCount
        let recovered = try await open("receiver")
        XCTAssertEqual(try state().outbox[pending.id], pending)
        XCTAssertEqual(server.mutationCount, mutations)
        XCTAssertFalse(server.recordNames.contains(pending.id))
        let sent = try await recovered.publishBatch([pending])
        XCTAssertNil(sent.error)
        XCTAssertEqual(sent.acknowledgedIDs, [pending.id])
        await recovered.retire()
    }

    func testTransientReadFailureKeepsHaltAndRetriesOnNextOpen() async throws {
        let fixture = try await haltedFixture()
        let original = try Data(contentsOf: stateURL)
        server.inject(.failNextRead)
        do {
            _ = try await open("receiver")
            XCTFail("An unsuccessful verification must not clear the halt")
        } catch { XCTAssertEqual((error as? CKError)?.code, .networkFailure) }
        XCTAssertEqual(try Data(contentsOf: stateURL), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))
        let recovered = try await open("receiver")
        assertTrue(await recovered.recoveredLegacySnapshotDeletionHalt)
        XCTAssertTrue(server.recordNames.contains(fixture.latestNote.id))
        await recovered.retire()
    }

    func testInterruptedFreshFetchKeepsOriginalStateAndCanRestart() async throws {
        _ = try await haltedFixture()
        let original = try Data(contentsOf: stateURL)
        server.inject(.crashAfterFetchedChanges)
        do {
            _ = try await open("receiver")
            XCTFail("The interrupted fetch must abort verification")
        } catch { XCTAssertTrue(error is FakeCloudKitCrash) }
        XCTAssertEqual(try Data(contentsOf: stateURL), original)
        let recovered = try await open("receiver")
        assertTrue(await recovered.recoveredLegacySnapshotDeletionHalt)
        await recovered.retire()
    }

    func testThrottledZoneResultPreservesHaltAndPersistsCooldown() async throws {
        _ = try await haltedFixture()
        let original = try Data(contentsOf: stateURL)
        let reads = server.directRecordReads.count
        let mutations = server.mutationCount
        server.inject(.failNextZoneResult(.requestRateLimited, retryAfter: 30))
        do {
            _ = try await open("receiver")
            XCTFail("A throttled zone read must stop verification")
        } catch {
            XCTAssertEqual((error as? CKError)?.code, .requestRateLimited)
        }
        XCTAssertEqual(try Data(contentsOf: stateURL), original)
        XCTAssertEqual(server.directRecordReads.count, reads)
        XCTAssertEqual(server.mutationCount, mutations)
        let cooldown = try CloudKitAvailabilityCooldownStore(
            directory: root.appending(path: "receiver")
        )
        XCTAssertGreaterThan(try XCTUnwrap(cooldown.throttle.notBefore)
            .timeIntervalSinceNow, 0)
    }

    func testMissingHistoryCanonicalAndZoneNeverClearLegacyHalt() async throws {
        for missing in ["note", "catalog", "canonical", "zone"] {
            let fixture = try await haltedFixture()
            let original = try Data(contentsOf: stateURL)
            switch missing {
            case "note": server.deleteRecord(named: fixture.latestNote.id)
            case "catalog": server.deleteRecord(named: fixture.latestCatalog.id)
            case "canonical": server.deleteRecord(named: "canonical-notebook-v2")
            default: server.deleteZone()
            }
            let names = server.recordNames
            let mutations = server.mutationCount
            do {
                _ = try await open("receiver")
                XCTFail("Missing \(missing) must keep sync paused")
            } catch {
                XCTAssertEqual(error as? CloudKitSyncTransportError, .unexpectedDeletion)
            }
            XCTAssertEqual(try Data(contentsOf: stateURL), original)
            XCTAssertEqual(server.recordNames, names)
            XCTAssertEqual(server.mutationCount, mutations)
            try FileManager.default.removeItem(at: root)
            try setUpWithError()
        }
    }

    func testHealthyLegacyStateMarksMigrationWithoutCloudVerification() async throws {
        let fixture = try await fixture()
        await fixture.receiver.retire()
        _ = try saveLegacyHalt(halted: false)
        let reads = server.directRecordReads.count
        let mutations = server.mutationCount
        let reopened = try await open("receiver")
        XCTAssertEqual(server.directRecordReads.count, reads)
        XCTAssertEqual(server.mutationCount, mutations)
        XCTAssertTrue(try state().completedSyncStateMigrations.contains(migration))
        assertFalse(await reopened.recoveredLegacySnapshotDeletionHalt)
        await reopened.retire()
    }

    func testCompletedAndExplicitNewHaltsNeverRunLegacyRecovery() async throws {
        let fixture = try await fixture()
        await fixture.receiver.retire()
        let healthy = try state()
        for reason in [nil, CloudKitRemoteDeletionHaltReason.canonicalBootstrapDeleted, .zoneDeleted] {
            var saved = healthy
            saved.hasUnexpectedDeletion = true
            saved.remoteDeletionHaltReason = reason
            if reason != nil { saved.completedSyncStateMigrations.remove(migration) }
            try JSONEncoder().encode(saved).write(to: stateURL)
            let reads = server.directRecordReads.count
            let reopened = try await open("receiver")
            assertNotNil(await reopened.haltStatus())
            assertFalse(await reopened.recoveredLegacySnapshotDeletionHalt)
            XCTAssertEqual(server.directRecordReads.count, reads)
            XCTAssertEqual(try state(), saved)
            await reopened.retire()
        }
    }

    func testUnknownMigrationCompletionsSurviveLegacyRecovery() async throws {
        _ = try await haltedFixture()
        var saved = try state()
        saved.completedSyncStateMigrations.insert("future-recovery-v7")
        try JSONEncoder().encode(saved).write(to: stateURL)
        let recovered = try await open("receiver")
        XCTAssertEqual(try state().completedSyncStateMigrations,
                       [migration, "future-recovery-v7"])
        await recovered.retire()
    }

    func testChangedAccountStopsBeforeRecovery() async throws {
        _ = try await haltedFixture()
        let original = try Data(contentsOf: stateURL)
        let reads = server.directRecordReads.count
        server.switchAccount()
        do {
            _ = try await open("receiver")
            XCTFail("Account-bound recovery must reject a changed account")
        } catch { XCTAssertEqual(error as? SyncError, .scopeChanged) }
        XCTAssertEqual(server.directRecordReads.count, reads)
        XCTAssertEqual(try Data(contentsOf: stateURL), original)
    }

    func testPermanentlyDeletedBodyDoesNotBlockRecoveryOrResurrect() async throws {
        let fixture = try await fixture()
        await fixture.receiver.retire()
        let catalog = try NotebookCatalogDocument(snapshot: XCTUnwrap(fixture.latestCatalog.catalogSnapshot))
        try catalog.markPermanentlyDeleted([fixture.noteID])
        let marker = SyncRecord(catalog: catalog.snapshot())
        try await publish([marker], to: fixture.writer)
        try await fixture.writer.purgeDeletedNotes([fixture.noteID], notebookID: fixture.notebookID)
        _ = try saveLegacyHalt()
        let names = server.recordNames
        let recovered = try await open("receiver")
        assertTrue(await recovered.recoveredLegacySnapshotDeletionHalt)
        XCTAssertEqual(server.recordNames, names)
        let replica = NotebookReplica(directory: root.appending(path: "deleted-notebook"))
        let coordinator = NotebookSyncCoordinator(replica: replica, transport: recovered)
        await coordinator.synchronize()
        XCTAssertNil(coordinator.lastError)
        XCTAssertFalse(replica.placements.contains { $0.item.id == fixture.noteID })
        XCTAssertFalse(server.recordNames.contains(fixture.oldNote.id))
        XCTAssertFalse(server.recordNames.contains(fixture.latestNote.id))
        await recovered.retire()
    }

    func testSurvivorDeletionDuringConfirmationKeepsLegacyHalt() async throws {
        let fixture = try await haltedFixture()
        let original = try Data(contentsOf: stateURL)
        let gate = CloudKitRaceGate()
        let database = CloudKitRaceDatabase(base: server,
            afterRead: (name: fixture.latestNote.id, gate: gate))
        let services = database.services(base: server.services)
        let opening = Task { try await self.open("receiver", services: services) }
        do {
            try await gate.waitUntilPaused()
            server.deleteRecord(named: fixture.latestNote.id)
            await gate.release()
            _ = try await opening.value
            XCTFail("A disappearing survivor cannot authorize recovery")
        } catch {
            opening.cancel()
            await gate.release()
            _ = try? await opening.value
            XCTAssertEqual(error as? CloudKitSyncTransportError, .unexpectedDeletion)
        }
        XCTAssertEqual(try Data(contentsOf: stateURL), original)
    }

    func testCoveringSuccessorDuringConfirmationCanRecover() async throws {
        let fixture = try await haltedFixture()
        let gate = CloudKitRaceGate()
        let database = CloudKitRaceDatabase(base: server,
            afterRead: (name: fixture.latestNote.id, gate: gate))
        let services = database.services(base: server.services)
        let opening = Task { try await self.open("receiver", services: services) }
        do {
            try await gate.waitUntilPaused()
            let note = try NoteDocument(snapshot: fixture.latestNote.snapshot)
            try note.replaceAll(with: "Fictional newer cloud checkpoint")
            let successor = SyncRecord(snapshot: note.snapshot(), notebookID: fixture.notebookID)
            try await publish([successor], to: fixture.writer)
            server.deleteRecord(named: fixture.latestNote.id)
            await gate.release()
            let recovered = try await opening.value
            assertTrue(await recovered.recoveredLegacySnapshotDeletionHalt)
            XCTAssertTrue(try state().inbox.contains(successor))
            await recovered.retire()
        } catch {
            opening.cancel()
            await gate.release()
            _ = try? await opening.value
            throw error
        }
    }

    func testFailedRecoveryCommitKeepsHaltAndCompletionReplayable() async throws {
        _ = try await haltedFixture()
        let original = try Data(contentsOf: stateURL)
        let mutations = server.mutationCount
        do {
            _ = try await CloudKitSyncTransport.makeNotebook(
                services: server.services, containerIdentifier: server.containerIdentifier,
                stateDirectory: root.appending(path: "receiver"),
                writeState: { _, _ in throw POSIXError(.ENOSPC) }
            )
            XCTFail("A failed durable commit must not complete recovery")
        } catch {
            let failure = try XCTUnwrap(error as? CloudKitStateWriteFailure)
            XCTAssertTrue(failure.isRecoverable)
        }
        XCTAssertEqual(try Data(contentsOf: stateURL), original)
        XCTAssertEqual(server.mutationCount, mutations)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
        let recovered = try await open("receiver")
        assertTrue(await recovered.recoveredLegacySnapshotDeletionHalt)
        await recovered.retire()
    }

    func testLostConcurrentBranchCannotBeExcusedByLatestText() async throws {
        let fixture = try await fixture()
        let branch = try NoteDocument(snapshot: fixture.oldNote.snapshot)
        try branch.replaceAll(with: "Fictional latest text")
        let branchRecord = SyncRecord(snapshot: branch.snapshot(), notebookID: fixture.notebookID)
        XCTAssertNotEqual(branchRecord.id, fixture.latestNote.id)
        try await publish([branchRecord], to: fixture.writer)
        _ = try await drain(fixture.receiver)
        await fixture.receiver.retire()
        try await retireSnapshots(fixture)
        server.deleteRecord(named: branchRecord.id)
        _ = try saveLegacyHalt()
        let original = try Data(contentsOf: stateURL)
        do {
            _ = try await open("receiver")
            XCTFail("Matching text must not excuse lost concurrent history")
        } catch {
            XCTAssertEqual(error as? CloudKitSyncTransportError, .unexpectedDeletion)
        }
        XCTAssertEqual(try Data(contentsOf: stateURL), original)
    }

    func testCancelledConfirmationKeepsHaltAndDoesNotPublish() async throws {
        let fixture = try await haltedFixture()
        let original = try Data(contentsOf: stateURL)
        let mutations = server.mutationCount
        let gate = CloudKitRaceGate()
        let database = CloudKitRaceDatabase(base: server,
            afterRead: (name: fixture.latestNote.id, gate: gate))
        let services = database.services(base: server.services)
        let opening = Task { try await self.open("receiver", services: services) }
        do {
            try await gate.waitUntilPaused()
            opening.cancel()
            await gate.release()
            _ = try await opening.value
            XCTFail("Cancelled verification must not commit")
        } catch {
            opening.cancel()
            await gate.release()
            _ = try? await opening.value
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(try Data(contentsOf: stateURL), original)
        XCTAssertEqual(server.mutationCount, mutations)
    }

    func testEmptyLegacyStateCannotClearAnUnexplainedHalt() async throws {
        let receiver = try await open("receiver")
        await receiver.retire()
        _ = try saveLegacyHalt()
        let original = try Data(contentsOf: stateURL)
        let reads = server.directRecordReads.count
        do {
            _ = try await open("receiver")
            XCTFail("An empty inbox provides no evidence for automatic recovery")
        } catch {
            XCTAssertEqual(error as? CloudKitSyncTransportError, .unexpectedDeletion)
        }
        XCTAssertEqual(try Data(contentsOf: stateURL), original)
        XCTAssertEqual(server.directRecordReads.count, reads)
    }

    private func assertNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(value, file: file, line: line)
    }
    private func assertNotNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNotNil(value, file: file, line: line)
    }
    private func assertTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(value, file: file, line: line)
    }
    private func assertFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(value, file: file, line: line)
    }

    private struct Fixture {
        var notebookID: UUID
        var noteID: UUID
        var oldNote: SyncRecord
        var latestNote: SyncRecord
        var oldCatalog: SyncRecord
        var latestCatalog: SyncRecord
        var writer: CloudKitSyncTransport
        var receiver: CloudKitSyncTransport
    }

    private func fixture(publishLatest: Bool = true) async throws -> Fixture {
        let notebookID = UUID()
        let note = try NoteDocument(text: "Fictional original text")
        let oldNote = SyncRecord(snapshot: note.snapshot(), notebookID: notebookID)
        try note.replaceAll(with: "Fictional latest text")
        let latestNote = SyncRecord(snapshot: note.snapshot(), notebookID: notebookID)
        let catalog = try NotebookCatalogDocument(notebookID: notebookID)
        _ = try catalog.add(id: note.noteID, kind: .note, name: "Fictional journal")
        let canonical = SyncRecord(catalog: catalog.snapshot())
        let writer = try await open("writer")
        _ = try await writer.bootstrap(proposing: canonical)
        try catalog.setPinnedInRecents(true, for: note.noteID)
        let oldCatalog = SyncRecord(catalog: catalog.snapshot())
        try await publish([oldNote, oldCatalog], to: writer)
        let receiver = try await open("receiver")
        _ = try await receiver.bootstrap(proposing: canonical)
        _ = try await drain(receiver)
        try catalog.recordRecentActivity(for: note.noteID)
        let latestCatalog = SyncRecord(catalog: catalog.snapshot())
        if publishLatest { try await publish([latestNote, latestCatalog], to: writer) }
        return Fixture(notebookID: notebookID, noteID: note.noteID,
            oldNote: oldNote, latestNote: latestNote, oldCatalog: oldCatalog,
            latestCatalog: latestCatalog, writer: writer, receiver: receiver)
    }

    private func haltedFixture() async throws -> Fixture {
        let fixture = try await fixture()
        await fixture.receiver.retire()
        try await retireSnapshots(fixture)
        _ = try saveLegacyHalt()
        return fixture
    }

    private func retireSnapshots(_ fixture: Fixture) async throws {
        let cleanup = try await fixture.writer.cleanupRedundantSnapshots(notebookID: fixture.notebookID)
        XCTAssertGreaterThan(cleanup.deletedSnapshotCount, 0)
        XCTAssertFalse(server.recordNames.contains(fixture.oldNote.id))
        XCTAssertFalse(server.recordNames.contains(fixture.oldCatalog.id))
    }

    /// Pre-#214 catalog deletion saved a fatal Bool without record IDs.
    /// Encode that old layout; keep its acknowledged inbox and engine token.
    private func saveLegacyHalt(halted: Bool = true) throws -> CloudKitTransportState {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: stateURL)) as? [String: Any])
        json.removeValue(forKey: "completedSyncStateMigrations")
        json.removeValue(forKey: "remoteDeletionHaltReason")
        json.removeValue(forKey: "canonicalSnapshotID")
        json.removeValue(forKey: "remoteDeletedSnapshotIDs")
        json["hasUnexpectedDeletion"] = halted
        try JSONSerialization.data(withJSONObject: json).write(to: stateURL)
        return try state()
    }

    private var stateURL: URL { root.appending(path: "receiver/cloudkit-sync-state.json") }
    private var backupURL: URL { root.appending(path: "receiver/cloudkit-sync-state.before-legacy-recovery-v1.json") }
    private func state() throws -> CloudKitTransportState {
        try JSONDecoder().decode(CloudKitTransportState.self, from: Data(contentsOf: stateURL))
    }
    private func open(_ name: String, services: CloudKitServices? = nil) async throws
        -> CloudKitSyncTransport {
        try await CloudKitSyncTransport.makeNotebook(services: services ?? server.services,
            containerIdentifier: server.containerIdentifier, stateDirectory: root.appending(path: name))
    }
    private func publish(_ records: [SyncRecord], to transport: CloudKitSyncTransport) async throws {
        let result = try await transport.publishBatch(records)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.acknowledgedIDs, Set(records.map(\.id)))
    }
    private func drain(_ transport: CloudKitSyncTransport) async throws -> [SyncRecord] {
        var cursor: String?
        var records: [SyncRecord] = []
        for _ in 0..<30 {
            let page = try await transport.fetch(after: cursor)
            records += page.records
            cursor = page.cursor
            if !page.hasMore { return records }
        }
        throw SyncError.unavailable("Recovery fixture exceeded its fetch bound")
    }
}
