import Foundation
import XCTest

@testable import NoteCore

@MainActor
final class NotebookDeletionSyncTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() async throws {
        for root in roots { try FileManager.default.removeItem(at: root) }
        roots = []
    }

    private func replica() -> NotebookReplica {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "notebook-deletion-sync-\(UUID())")
        roots.append(root)
        return NotebookReplica(directory: root)
    }

    func testDeletionWaitsForMarkerAcknowledgementAndRetriesCleanup() async throws {
        let transport = DeletionCheckingTransport()
        let local = replica()
        let coordinator = NotebookSyncCoordinator(replica: local, transport: transport)
        await coordinator.synchronize()
        let note = try await local.createNote(name: "remove.md", text: "private body")
        await coordinator.synchronize()
        try await local.setTrashed(note, true)
        let selection = try local.deletionSelection()
        try await local.permanentlyDelete(selection)

        await transport.failNextCatalog()
        await coordinator.synchronize()
        let beforeAcknowledgement = await transport.purgeCalls
        XCTAssertEqual(beforeAcknowledgement, 0)
        if case .failed = coordinator.status {} else { XCTFail("Expected failed upload") }
        let beforePurge = try await transport.fetch(after: nil)
        XCTAssertTrue(beforePurge.records.contains { $0.kind == .note })

        await transport.failNextPurge()
        await coordinator.synchronize()
        if case .failed = coordinator.status {} else { XCTFail("Expected retryable cleanup") }
        let failedPurgeCalls = await transport.purgeCalls
        XCTAssertEqual(failedPurgeCalls, 1)

        // No new catalog change is needed to retry after a process restart.
        let reopened = NotebookReplica(directory: local.directory)
        let restarted = NotebookSyncCoordinator(replica: reopened, transport: transport)
        await restarted.synchronize()
        if case .exchanged = restarted.status {} else { XCTFail("\(restarted.status)") }
        let remaining = try await transport.fetch(after: nil)
        XCTAssertFalse(remaining.records.contains { $0.kind == .note })
        XCTAssertTrue(remaining.records.contains { $0.kind == .catalog })
        let allPurgesHadMarkers = await transport.allPurgesHadMarkers
        XCTAssertTrue(allPurgesHadMarkers)
    }

    func testOfflineChildSurvivesPurgeAndOldBodyCannotReturn() async throws {
        let transport = DeletionCheckingTransport()
        let left = replica()
        let right = replica()
        let leftSync = NotebookSyncCoordinator(replica: left, transport: transport)
        let rightSync = NotebookSyncCoordinator(replica: right, transport: transport)
        await leftSync.synchronize()
        let folder = try await left.createFolder(name: "Removed folder")
        let removed = try await left.createNote(name: "old.md", text: "old", parentID: folder)
        await leftSync.synchronize()
        await rightSync.synchronize()
        let oldRecords = try await right.records()
        let oldBody = try XCTUnwrap(oldRecords.first { $0.kind == .note })
        let oldSession = try await right.openNote(removed)
        try oldSession.replaceAll(with: "offline edit")
        try await oldSession.flush()
        let survivor = try await right.createNote(name: "new.md", text: "keep", parentID: folder)

        try await left.setTrashed(folder, true)
        try await left.permanentlyDelete(left.deletionSelection(rootID: folder))
        await leftSync.synchronize()
        // Simulates a late upload by an old client that missed the marker.
        try await transport.publish(oldBody)
        await rightSync.synchronize()
        await leftSync.synchronize()

        XCTAssertTrue(oldSession.isPermanentlyDeleted)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: right.directory.appending(path: "notes/\(removed.uuidString)").path))
        let survivingPlacement = try XCTUnwrap(left.placements.first { $0.item.id == survivor })
        XCTAssertNil(survivingPlacement.parentID)
        XCTAssertFalse(survivingPlacement.isInTrash)
        let survivingSession = try await left.openNote(survivor)
        XCTAssertEqual(survivingSession.text, "keep")
        let remaining = try await transport.fetch(after: nil)
        XCTAssertFalse(remaining.records.contains {
            $0.kind == .note && $0.snapshot.noteID == removed
        })
    }

    func testDeletedLegacyProposalDropsBodyAndIgnoresLateLegacyEdits() async throws {
        let transport = DeletionCheckingTransport()
        let local = replica()
        let legacy = try NoteDocument(text: "retained legacy body")
        let coordinator = NotebookSyncCoordinator(replica: local, transport: transport)
        await coordinator.synchronize(legacyNote: legacy.snapshot())
        try await local.setTrashed(legacy.noteID, true)
        try await local.permanentlyDelete(local.deletionSelection())
        let proposalURL = local.directory.appending(path: "notebook-proposal.json")
        let proposal = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: proposalURL)) as? [String: Any])
        XCTAssertNil(proposal["legacyNote"])
        XCTAssertEqual(proposal["retiredLegacyNoteID"] as? String, legacy.noteID.uuidString)

        try legacy.replaceAll(with: "later old-client edit")
        await coordinator.synchronize(legacyNote: legacy.snapshot())
        if case .exchanged = coordinator.status {} else { XCTFail("\(coordinator.status)") }
        XCTAssertFalse(local.placements.contains { $0.item.id == legacy.noteID })
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: local.directory.appending(path: "notes/\(legacy.noteID.uuidString)").path))
    }

    func testMalformedUnusedLegacyBodyDoesNotBlockOfflineCleanup() async throws {
        let local = replica()
        let transport = DeletionCheckingTransport()
        await NotebookSyncCoordinator(replica: local, transport: transport).synchronize()
        let note = try await local.createNote(name: "remove.md")
        let proposalURL = local.directory.appending(path: "notebook-proposal.json")
        var proposal = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: proposalURL)) as? [String: Any])
        proposal["legacyNote"] = "obsolete invalid payload"
        try JSONSerialization.data(withJSONObject: proposal).write(to: proposalURL)
        try await local.setTrashed(note, true)
        try await local.permanentlyDelete(local.deletionSelection())
        XCTAssertNil(local.deletionCleanupErrorMessage)
        let scrubbed = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: proposalURL)) as? [String: Any])
        XCTAssertNil(scrubbed["legacyNote"])
    }
}

private actor DeletionCheckingTransport: SyncTransport {
    nonisolated let scope = "deletion-checking"
    private let base = InMemorySyncTransport(scope: "deletion-checking")
    private var failCatalog = false
    private var failPurge = false
    private(set) var purgeCalls = 0
    private(set) var allPurgesHadMarkers = true

    func failNextCatalog() { failCatalog = true }
    func failNextPurge() { failPurge = true }
    func bootstrap(proposing record: SyncRecord) async throws -> SyncRecord {
        try await base.bootstrap(proposing: record)
    }
    func publish(_ record: SyncRecord) async throws {
        if record.kind == .catalog, failCatalog {
            failCatalog = false
            throw SyncError.unavailable("Injected catalog upload failure")
        }
        try await base.publish(record)
    }
    func fetch(after cursor: String?) async throws -> SyncPage {
        try await base.fetch(after: cursor)
    }
    func purgeDeletedNotes(_ ids: Set<UUID>, notebookID: UUID) async throws {
        purgeCalls += 1
        let records = try await base.fetch(after: nil).records
        var marked: Set<UUID> = []
        for record in records {
            if let snapshot = record.catalogSnapshot {
                marked.formUnion(try NotebookCatalogDocument(snapshot: snapshot)
                    .items().filter(\.isPermanentlyDeleted).map(\.id))
            }
        }
        allPurgesHadMarkers = allPurgesHadMarkers && ids.isSubset(of: marked)
        if failPurge {
            failPurge = false
            throw SyncError.unavailable("Injected cleanup failure")
        }
        try await base.purgeDeletedNotes(ids, notebookID: notebookID)
    }
}
