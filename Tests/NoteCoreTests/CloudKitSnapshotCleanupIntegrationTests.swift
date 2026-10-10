import CloudKit
import Foundation
import XCTest

@testable import NoteCore

final class CloudKitSnapshotCleanupIntegrationTests: XCTestCase {
    private var root: URL!
    private var server: FakeCloudKitServer!
    private let notebookID = UUID()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "SnapshotCleanup-\(UUID())"
        )
        server = try FakeCloudKitServer(directory: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testLongEditHistoryReducesFreshJoinTransferAndKeepsHistory() async throws {
        let fixture = try fixture(edits: 32)
        let writer = try await seed(fixture)
        let beforeNames = server.recordNames
        let beforeBytes = server.storedAssetBytes
        server.resetFetchMeasurements()
        let before = try await open("before")
        let beforeCanonical = try await before.bootstrap(proposing: fixture.catalog)
        XCTAssertEqual(beforeCanonical, fixture.catalog)
        _ = try await drain(before)
        let beforeFetch = server.fetchMeasurements
        let original = try NoteDocument(snapshot: fixture.notes.last!.snapshot)
        let expectedVersions = try original.historyVersions()
        let expectedHistory = try expectedVersions.map(original.historicalText(for:))
        _ = try await writer.cleanupRedundantSnapshots(notebookID: notebookID)
        let afterNames = server.recordNames
        let afterBytes = server.storedAssetBytes
        XCTAssertLessThan(afterNames.count, beforeNames.count)
        XCTAssertLessThan(afterBytes, beforeBytes)
        XCTAssertTrue(afterNames.contains(fixture.notes.last!.id))
        XCTAssertTrue(afterNames.contains("canonical-notebook-v2"))
        server.resetFetchMeasurements()
        let after = try await open("after")
        let afterCanonical = try await after.bootstrap(proposing: fixture.catalog)
        XCTAssertEqual(afterCanonical, fixture.catalog)
        let received = try await drain(after)
        let afterFetch = server.fetchMeasurements
        XCTAssertLessThan(afterFetch.records, beforeFetch.records)
        XCTAssertLessThan(afterFetch.assetBytes, beforeFetch.assetBytes)
        let latest = try XCTUnwrap(received.first { $0.id == fixture.notes.last!.id })
        let document = try NoteDocument(snapshot: latest.snapshot)
        let start = Date()
        let history = try document.historyVersions().map(document.historicalText(for:))
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(try document.historyVersions(), expectedVersions)
        XCTAssertEqual(history, expectedHistory)
        let allStates = history + [try document.text]
        for text in fixture.texts { XCTAssertTrue(allStates.contains(text)) }
        print("Cleanup long-edit fixture: records \(beforeNames.count) -> \(afterNames.count), assets \(beforeBytes) -> \(afterBytes) bytes, fresh fetch \(beforeFetch) -> \(afterFetch), History \(history.count) versions in \(elapsed)s")
    }

    func testIndependentOfflineBranchesSurviveUntilMergedCheckpoint() async throws {
        let fixture = try fixture(edits: 2)
        let writer = try await seed(fixture)
        let branch = try NoteDocument(snapshot: fixture.notes.first!.snapshot)
        try branch.replaceUTF16(range: NSRange(location: 0, length: 0),
                                with: "Fictional offline edit\n")
        let branchRecord = record(branch)
        try await publish(writer, [branchRecord])
        _ = try await writer.cleanupRedundantSnapshots(notebookID: notebookID)
        XCTAssertTrue(server.recordNames.contains(branchRecord.id))
        XCTAssertTrue(server.recordNames.contains(fixture.notes.last!.id))
        let merged = try NoteDocument(snapshot: fixture.notes.last!.snapshot)
        try merged.merge(branch)
        let checkpoint = record(merged)
        try await publish(writer, [checkpoint])
        _ = try await writer.cleanupRedundantSnapshots(notebookID: notebookID)
        XCTAssertFalse(server.recordNames.contains(branchRecord.id))
        XCTAssertFalse(server.recordNames.contains(fixture.notes.last!.id))
        XCTAssertTrue(server.recordNames.contains(checkpoint.id))
        XCTAssertTrue(branch.historyHeads.isSubset(of: merged.historyHeads))
    }

    func testFailedSurvivorReadDoesNotDelete() async throws {
        let fixture = try fixture(edits: 3)
        let writer = try await seed(fixture)
        server.inject(.failNextRead)
        do {
            _ = try await writer.cleanupRedundantSnapshots(notebookID: notebookID)
            XCTFail("A failed survivor read must interrupt cleanup")
        } catch { XCTAssertEqual((error as? CKError)?.code, .networkFailure) }
        XCTAssertEqual(server.deletedRecordNames, [])
        XCTAssertTrue(server.recordNames.contains(fixture.notes.first!.id))
    }

    func testMissingSurvivorDoesNotDeleteAncestors() async throws {
        let fixture = try fixture(edits: 3)
        let writer = try await seed(fixture)
        server.inject(.deleteBeforeNextRead(fixture.notes.last!.id))
        do {
            _ = try await writer.cleanupRedundantSnapshots(notebookID: notebookID)
            XCTFail("A missing maximal history must stop cleanup")
        } catch {
            XCTAssertEqual(error as? CloudKitSyncTransportError, .unexpectedDeletion)
        }
        XCTAssertEqual(server.deletedRecordNames, [])
        XCTAssertTrue(server.recordNames.contains(fixture.notes.first!.id))
    }

    func testPartialDeleteRetriesAfterRestart() async throws {
        let fixture = try fixture(edits: 4)
        let writer = try await seed(fixture)
        let blocked = fixture.notes.dropLast().map(\.id).sorted().last!
        server.inject(.failDelete(.requestRateLimited) { $0.recordName == blocked })
        do {
            _ = try await writer.cleanupRedundantSnapshots(notebookID: notebookID)
            XCTFail("The throttled per-record delete must report failure")
        } catch { XCTAssertEqual((error as? CKError)?.code, .requestRateLimited) }
        XCTAssertTrue(server.recordNames.contains(blocked))
        XCTAssertFalse(server.deletedRecordNames.isEmpty)
        await writer.retire()
        let restarted = try await open("writer")
        _ = try await restarted.cleanupRedundantSnapshots(notebookID: notebookID)
        XCTAssertFalse(server.recordNames.contains(blocked))
        XCTAssertTrue(server.recordNames.contains(fixture.notes.last!.id))
    }

    func testLostDeleteAcknowledgmentAndStaleReuploadAreIdempotent() async throws {
        let fixture = try fixture(edits: 4)
        let writer = try await seed(fixture)
        server.inject(.crashAfterServerDelete)
        do {
            _ = try await writer.cleanupRedundantSnapshots(notebookID: notebookID)
            XCTFail("Lost acknowledgment must simulate a process crash")
        } catch { XCTAssertTrue(error is FakeCloudKitCrash) }
        await writer.retire()
        let restarted = try await open("writer")
        _ = try await restarted.cleanupRedundantSnapshots(notebookID: notebookID)
        XCTAssertTrue(server.recordNames.contains(fixture.notes.last!.id))
        try await publish(restarted, [fixture.notes.first!])
        XCTAssertTrue(server.recordNames.contains(fixture.notes.first!.id))
        _ = try await restarted.cleanupRedundantSnapshots(notebookID: notebookID)
        XCTAssertFalse(server.recordNames.contains(fixture.notes.first!.id))
    }

    func testConcurrentCleanersKeepSurvivorAndCursorUsable() async throws {
        let fixture = try fixture(edits: 6)
        let writer = try await seed(fixture)
        let other = try await open("other")
        _ = try await other.bootstrap(proposing: fixture.catalog)
        _ = try await drain(other)
        let sharedNotebookID = notebookID
        async let first = writer.cleanupRedundantSnapshots(notebookID: sharedNotebookID)
        async let second = other.cleanupRedundantSnapshots(notebookID: sharedNotebookID)
        _ = try await (first, second)
        XCTAssertTrue(server.recordNames.contains(fixture.notes.last!.id))
        XCTAssertTrue(server.recordNames.contains("canonical-notebook-v2"))
        _ = try await drain(other)
        let halt = await other.haltStatus()
        XCTAssertNil(halt)
    }

    func testCatalogPrunesHistoryButPreservesBootstrap() async throws {
        let fixture = try fixture(edits: 1)
        let writer = try await seed(fixture)
        let catalog = try NotebookCatalogDocument(
            serializedData: fixture.catalog.snapshot.data
        )
        try catalog.setPinnedInRecents(true, for: fixture.notes.first!.snapshot.noteID)
        let ancestor = SyncRecord(catalog: catalog.snapshot())
        try catalog.recordRecentActivity(for: fixture.notes.first!.snapshot.noteID)
        let descendant = SyncRecord(catalog: catalog.snapshot())
        try await publish(writer, [ancestor, descendant])
        _ = try await drain(writer)
        _ = try await writer.cleanupRedundantSnapshots(notebookID: notebookID)
        XCTAssertFalse(server.recordNames.contains(ancestor.id))
        XCTAssertTrue(server.recordNames.contains(descendant.id))
        XCTAssertTrue(server.recordNames.contains("canonical-notebook-v2"))
        let fresh = try await open("catalog-fresh")
        let canonical = try await fresh.bootstrap(proposing: fixture.catalog)
        XCTAssertEqual(canonical, fixture.catalog)
        let fetched = try await drain(fresh)
        XCTAssertTrue(fetched.contains(descendant))
        let before = try NotebookCatalogDocument(serializedData: ancestor.snapshot.data)
        let after = try NotebookCatalogDocument(serializedData: descendant.snapshot.data)
        XCTAssertTrue(before.historyHeads.isSubset(of: after.historyHeads))
    }

    func testUnuploadedDescendantCannotAuthorizeCleanup() async throws {
        let fixture = try fixture(edits: 2)
        let writer = try await open("writer")
        _ = try await writer.bootstrap(proposing: fixture.catalog)
        try await publish(writer, [fixture.notes.first!])
        _ = try await drain(writer)
        server.inject(.failSave(.requestRateLimited) {
            $0.recordName == fixture.notes.last!.id
        })
        let result = try await writer.publishBatch([fixture.notes.last!])
        XCTAssertNotNil(result.error)
        _ = try await writer.cleanupRedundantSnapshots(notebookID: notebookID)
        XCTAssertTrue(server.recordNames.contains(fixture.notes.first!.id))
        XCTAssertEqual(server.deletedRecordNames, [])
    }

    func testMissingDeleteResultRetriesAfterRestart() async throws {
        let fixture = try fixture(edits: 4)
        let writer = try await seed(fixture)
        let missing = fixture.notes.first!.id
        server.inject(.omitDeleteResult { $0.recordName == missing })
        do {
            _ = try await writer.cleanupRedundantSnapshots(notebookID: notebookID)
            XCTFail("An absent per-record result must remain unacknowledged")
        } catch {
            XCTAssertEqual(error as? CloudKitSyncTransportError,
                           .uploadNotAcknowledged)
        }
        XCTAssertFalse(server.recordNames.contains(missing))
        await writer.retire()
        let restarted = try await open("writer")
        _ = try await restarted.cleanupRedundantSnapshots(notebookID: notebookID)
        XCTAssertTrue(server.recordNames.contains(fixture.notes.last!.id))
        let halt = await restarted.haltStatus()
        XCTAssertNil(halt)
    }

    @MainActor
    func testThrottledMaintenanceKeepsSuccessfulSyncAndLocalEdits() async throws {
        let transport = try await CloudKitSyncTransport.makeNotebook(
            services: server.services,
            containerIdentifier: server.containerIdentifier,
            stateDirectory: root.appending(path: "coordinator")
        )
        let localDirectory = root.appending(path: "local-notebook")
        let replica = NotebookReplica(directory: localDirectory)
        let coordinator = NotebookSyncCoordinator(replica: replica, transport: transport)
        await coordinator.synchronize()
        let noteID = try await replica.createNote(name: "fictional.md", text: "First")
        await coordinator.synchronize()
        let session = try await replica.openNote(noteID)
        try session.replaceText(in: NSRange(location: 0, length: 5), with: "Local durable edit")
        try await session.flush()
        server.inject(.failDelete(.requestRateLimited) { _ in true })
        await coordinator.synchronize()
        if case .exchanged = coordinator.status { } else {
            XCTFail("Maintenance throttle must preserve successful exchange status")
        }
        XCTAssertNil(coordinator.lastError)
        let reopened = NotebookReplica(directory: localDirectory)
        try await reopened.load()
        let durable = try await reopened.openNote(noteID)
        XCTAssertEqual(durable.text, "Local durable edit")
        await coordinator.synchronize()
        XCTAssertNil(coordinator.lastError)
    }

    func testMoreThanOneDeleteBatchMakesProgressWithoutLosingHistory() async throws {
        let fixture = try fixture(edits: 105)
        let writer = try await seed(fixture)
        let initialCount = server.recordNames.count
        let first = try await writer.cleanupRedundantSnapshots(notebookID: notebookID)
        XCTAssertEqual(first.deletedSnapshotCount, 100)
        XCTAssertEqual(server.recordNames.count, initialCount - 100)
        XCTAssertTrue(server.recordNames.contains(fixture.notes.last!.id))
        let second = try await writer.cleanupRedundantSnapshots(notebookID: notebookID)
        XCTAssertEqual(second.deletedSnapshotCount, 5)
        XCTAssertEqual(server.recordNames.count, 2)
        let fresh = try await open("batch-fresh")
        _ = try await fresh.bootstrap(proposing: fixture.catalog)
        let records = try await drain(fresh)
        let latest = try XCTUnwrap(records.first { $0.id == fixture.notes.last!.id })
        let restored = try NoteDocument(snapshot: latest.snapshot)
        for snapshot in fixture.notes {
            let ancestor = try NoteDocument(snapshot: snapshot.snapshot)
            XCTAssertTrue(ancestor.historyHeads.isSubset(of: restored.historyHeads))
        }
    }

    func testNoCleanupCandidatesNeedsNoNetwork() async throws {
        let fixture = try fixture(edits: 0)
        let writer = try await seed(fixture)
        server.setOffline(true)
        let report = try await writer.cleanupRedundantSnapshots(notebookID: notebookID)
        XCTAssertEqual(report.deletedSnapshotCount, 0)
        XCTAssertEqual(server.deletedRecordNames, [])
    }

    func testMissingSurvivorProgressesAfterReceivingRemoteSuccessor() async throws {
        let fixture = try fixture(edits: 4)
        let writer = try await seed(fixture)
        let remote = try await open("successor-writer")
        _ = try await remote.bootstrap(proposing: fixture.catalog)
        let descendant = try NoteDocument(snapshot: fixture.notes.last!.snapshot)
        try descendant.replaceUTF16(range: NSRange(location: 0, length: 0),
                                    with: "Fictional successor edit\n")
        let successor = record(descendant)
        try await publish(remote, [successor])
        // The writer has durable plans based on its fetched maximal history;
        // the independently published covering record has not arrived yet.
        server.inject(.deleteBeforeNextRead(fixture.notes.last!.id))
        do {
            _ = try await writer.cleanupRedundantSnapshots(notebookID: notebookID)
            XCTFail("Unreceived replacement must not authorize cleanup")
        } catch {
            XCTAssertEqual(error as? CloudKitSyncTransportError, .unexpectedDeletion)
        }
        XCTAssertEqual(server.deletedRecordNames, [])
        let received = try await drain(writer)
        XCTAssertTrue(received.contains(successor))
        // The first bounded pass discards durable plans whose confirmed
        // survivor has disappeared. The next pass selects the new successor.
        let stale = try await writer.cleanupRedundantSnapshots(notebookID: notebookID)
        XCTAssertEqual(stale.deletedSnapshotCount, 0)
        XCTAssertEqual(server.deletedRecordNames, [])
        XCTAssertTrue(server.recordNames.contains(successor.id))
        let report = try await writer.cleanupRedundantSnapshots(notebookID: notebookID)
        XCTAssertEqual(report.deletedSnapshotCount, fixture.notes.count - 1)
        XCTAssertEqual(server.recordNames, ["canonical-notebook-v2", successor.id])
        for snapshot in fixture.notes {
            let ancestor = try NoteDocument(snapshot: snapshot.snapshot)
            XCTAssertTrue(ancestor.historyHeads.isSubset(of: descendant.historyHeads))
        }
        await writer.retire()
        let restarted = try await open("writer")
        let repeated = try await restarted.cleanupRedundantSnapshots(notebookID: notebookID)
        XCTAssertEqual(repeated.deletedSnapshotCount, 0)
        XCTAssertTrue(server.recordNames.contains(successor.id))
    }

    @MainActor
    func testMaintenanceErrorsClassifyAfterAcknowledgedDurableExchange() async throws {
        let cases: [(CloudKitSyncTransportError, Bool)] = [
            (.accountUnavailable, true),
            (.uploadNotAcknowledged, true),
            (.unexpectedDeletion, false),
        ]
        for (index, entry) in cases.enumerated() {
            let (failure, recoverable) = entry
            let device = "classification-\(index)"
            let transport = try await CloudKitSyncTransport.makeNotebook(
                services: server.services,
                containerIdentifier: server.containerIdentifier,
                stateDirectory: root.appending(path: device)
            )
            let localDirectory = root.appending(path: "\(device)-notebook")
            let replica = NotebookReplica(directory: localDirectory)
            await NotebookSyncCoordinator(replica: replica, transport: transport).synchronize()
            let text = "Fictional durable classification edit \(index)"
            let noteID = try await replica.createNote(name: "classification-\(index).md", text: text)
            let coordinator = NotebookSyncCoordinator(
                replica: replica,
                transport: CleanupFailureTransport(base: transport, failure: failure)
            )
            await coordinator.synchronize()
            if recoverable {
                if case .exchanged = coordinator.status { } else {
                    XCTFail("Recoverable maintenance must preserve successful exchange: \(failure)")
                }
                XCTAssertNil(coordinator.lastError)
            } else {
                if case .failed = coordinator.status { } else {
                    XCTFail("Integrity failure must fail synchronization")
                }
                XCTAssertEqual(coordinator.lastError as? CloudKitSyncTransportError, failure)
            }
            let reopened = NotebookReplica(directory: localDirectory)
            try await reopened.load()
            let durable = try await reopened.openNote(noteID)
            XCTAssertEqual(durable.text, text)
            // Independently read the acknowledged cloud body, rather than
            // inferring upload success from local coordinator state.
            let reader = try await CloudKitSyncTransport.makeNotebook(
                services: server.services,
                containerIdentifier: server.containerIdentifier,
                stateDirectory: root.appending(path: "\(device)-reader")
            )
            let canonical = try XCTUnwrap(replica.catalogSnapshot)
            _ = try await reader.bootstrap(proposing: SyncRecord(catalog: canonical))
            var cursor: String?
            var bodies: [SyncRecord] = []
            for _ in 0..<30 {
                let page = try await reader.fetch(after: cursor)
                bodies += page.records
                cursor = page.cursor
                if !page.hasMore { break }
            }
            let uploaded = try XCTUnwrap(bodies.first {
                $0.kind == .note && $0.snapshot.noteID == noteID
            })
            XCTAssertEqual(try NoteDocument(snapshot: uploaded.snapshot).text, text)
        }
    }

    private struct Fixture {
        let catalog: SyncRecord
        let notes: [SyncRecord]
        let texts: [String]
    }

    private func fixture(edits: Int) throws -> Fixture {
        let document = try NoteDocument(text: "Fictional research journal\n")
        var notes = [record(document)]
        var texts = [try document.text]
        for index in 0..<edits {
            let text = "Fictional research journal\nRevision \(index)\n"
                + String(repeating: "Invented observation \(index).\n", count: 80)
            try document.replaceAll(with: text)
            notes.append(record(document))
            texts.append(text)
        }
        let catalog = try NotebookCatalogDocument(notebookID: notebookID)
        _ = try catalog.add(id: document.noteID, kind: .note,
                            name: "Fictional research journal")
        return Fixture(catalog: SyncRecord(catalog: catalog.snapshot()),
                       notes: notes, texts: texts)
    }

    private func record(_ document: NoteDocument) -> SyncRecord {
        SyncRecord(snapshot: document.snapshot(), notebookID: notebookID)
    }

    private func seed(_ fixture: Fixture) async throws -> CloudKitSyncTransport {
        let writer = try await open("writer")
        _ = try await writer.bootstrap(proposing: fixture.catalog)
        try await publish(writer, fixture.notes)
        _ = try await drain(writer)
        return writer
    }

    private func publish(_ transport: CloudKitSyncTransport,
                         _ records: [SyncRecord]) async throws {
        let result = try await transport.publishBatch(records)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.acknowledgedIDs, Set(records.map(\.id)))
    }

    private func open(_ device: String) async throws -> CloudKitSyncTransport {
        try await CloudKitSyncTransport.makeNotebook(
            services: server.services,
            containerIdentifier: server.containerIdentifier,
            stateDirectory: root.appending(path: device)
        )
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
        throw SyncError.unavailable("Fake fetch exceeded page bound")
    }
}

/// Injects only maintenance outcomes; every exchange uses the real transport.
private struct CleanupFailureTransport: SyncTransport {
    let base: CloudKitSyncTransport
    let failure: CloudKitSyncTransportError
    var scope: String { base.scope }

    func bootstrap(proposing record: SyncRecord) async throws -> SyncRecord {
        try await base.bootstrap(proposing: record)
    }

    func publish(_ record: SyncRecord) async throws {
        try await base.publish(record)
    }

    func publishBatch(_ records: [SyncRecord]) async throws -> SyncBatchResult {
        try await base.publishBatch(records)
    }

    func fetch(after cursor: String?) async throws -> SyncPage {
        try await base.fetch(after: cursor)
    }

    func purgeDeletedNotes(_ noteIDs: Set<UUID>, notebookID: UUID) async throws {
        try await base.purgeDeletedNotes(noteIDs, notebookID: notebookID)
    }

    func cleanupRedundantSnapshots(notebookID: UUID) async throws -> SyncSnapshotCleanupReport {
        throw failure
    }

    func retryNotBefore() async -> Date? { await base.retryNotBefore() }
}
