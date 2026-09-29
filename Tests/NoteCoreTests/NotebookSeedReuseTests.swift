import Foundation
import XCTest

@testable import NoteCore

@MainActor
final class NotebookSeedReuseTests: XCTestCase {
    func testRepeatedSeedSkipsCatalogWriteOnlyWithMatchingDurableCopies() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        _ = try await replica.createNote(name: "Note.md")
        let seed = SyncRecord(catalog: try XCTUnwrap(replica.catalogSnapshot))

        for _ in 0..<3 {
            try await replica.acceptSeed(seed)
        }

        let storage = NotebookCatalogStorage(directory: root)
        let currentBefore = try Data(contentsOf: storage.currentURL)
        let previousBefore = try Data(contentsOf: storage.previousURL)
        let installed = try XCTUnwrap(replica.catalogSnapshot)
        XCTAssertEqual(currentBefore, installed.data)
        XCTAssertEqual(previousBefore, installed.data)

        replica.catalogWriteSuspension = { throw InjectedFailure.save }
        try await replica.acceptSeed(seed)
        replica.catalogWriteSuspension = nil

        XCTAssertEqual(try Data(contentsOf: storage.currentURL), currentBefore)
        XCTAssertEqual(try Data(contentsOf: storage.previousURL), previousBefore)
        XCTAssertEqual(replica.catalogSnapshot, installed)
    }

    func testFailedAcceptSeedDoesNotCreateReusableCache() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        let seed = SyncRecord(catalog: try XCTUnwrap(replica.catalogSnapshot))

        replica.catalogWriteSuspension = { throw InjectedFailure.save }
        for _ in 0..<2 {
            do {
                try await replica.acceptSeed(seed)
                XCTFail("A failed full-path write must fail again on retry")
            } catch {
                XCTAssertTrue(error is InjectedFailure)
            }
        }

        replica.catalogWriteSuspension = nil
        try await replica.acceptSeed(seed)
        XCTAssertNotNil(replica.catalogSnapshot)
    }

    func testMetadataChangesInvalidateReuseAndKeepInboxAndRecents() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        let note = try await replica.createNote(name: "Note.md")
        let inbox = try await replica.createFolder(name: "Inbox")
        let oldSeed = SyncRecord(catalog: try XCTUnwrap(replica.catalogSnapshot))
        for _ in 0..<2 { try await replica.acceptSeed(oldSeed) }

        try await replica.setDefaultNewNoteParentID(inbox)
        try await replica.recordRecentActivity(for: note)
        try await replica.setPinnedInRecents(true, for: note)

        replica.catalogWriteSuspension = { throw InjectedFailure.save }
        do {
            try await replica.acceptSeed(oldSeed)
            XCTFail("A metadata edit must invalidate the reuse cache")
        } catch {
            XCTAssertTrue(error is InjectedFailure)
        }
        replica.catalogWriteSuspension = nil
        try await replica.acceptSeed(oldSeed)

        XCTAssertEqual(replica.defaultNewNoteParentID, inbox)
        XCTAssertTrue(replica.isPinnedInRecents(note))
        XCTAssertEqual(replica.recentNotes.first?.id, note)
    }

    func testValidCatalogRollbackRepairsDiskAndKeepsNewerInboxMetadata() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        let inbox = try await replica.createFolder(name: "Inbox")
        let oldSeed = SyncRecord(catalog: try XCTUnwrap(replica.catalogSnapshot))

        try await replica.rename(inbox, to: "Renamed Inbox")
        try await replica.setDefaultNewNoteParentID(inbox)
        for _ in 0..<3 { try await replica.acceptSeed(oldSeed) }

        let storage = NotebookCatalogStorage(directory: root)
        let installed = try XCTUnwrap(replica.catalogSnapshot)
        try XCTUnwrap(oldSeed.catalogSnapshot).data.write(to: storage.currentURL)

        try await replica.acceptSeed(oldSeed)

        XCTAssertEqual(replica.defaultNewNoteParentID, inbox)
        XCTAssertEqual(
            replica.placements.first { $0.item.id == inbox }?.item.name,
            "Renamed Inbox"
        )
        XCTAssertNotEqual(try Data(contentsOf: storage.currentURL), oldSeed.snapshot.data)
        XCTAssertEqual(
            try NotebookCatalogDocument(
                snapshot: try XCTUnwrap(replica.catalogSnapshot)
            ).items().first { $0.id == inbox }?.name,
            "Renamed Inbox"
        )
        let persisted = try NotebookCatalogDocument(
            snapshot: try XCTUnwrap(replica.catalogSnapshot)
        )
        XCTAssertTrue(installed.heads.isSubset(of: persisted.historyHeads))
    }

    func testForgedSeedWithReusedRecordIDIsRejectedWithoutChangingReplica() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        let seed = SyncRecord(catalog: try XCTUnwrap(replica.catalogSnapshot))
        for _ in 0..<3 { try await replica.acceptSeed(seed) }
        let installed = try XCTUnwrap(replica.catalogSnapshot)
        let currentURL = NotebookCatalogStorage(directory: root).currentURL
        let currentBytes = try Data(contentsOf: currentURL)

        var payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(seed))
                as? [String: Any]
        )
        var snapshot = try XCTUnwrap(payload["snapshot"] as? [String: Any])
        snapshot["heads"] = ["forged-head"]
        payload["snapshot"] = snapshot
        let forged = try JSONDecoder().decode(
            SyncRecord.self,
            from: JSONSerialization.data(withJSONObject: payload)
        )
        XCTAssertEqual(forged.id, seed.id)

        do {
            try await replica.acceptSeed(forged)
            XCTFail("A forged seed must fail validation even when its ID matches")
        } catch {
            XCTAssertEqual(error as? NotebookCatalogError, .identityMismatch)
        }

        XCTAssertEqual(replica.catalogSnapshot, installed)
        XCTAssertEqual(try Data(contentsOf: currentURL), currentBytes)
    }

    func testCorruptCurrentCatalogFallsBackToExistingStorageError() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        let seed = SyncRecord(catalog: try XCTUnwrap(replica.catalogSnapshot))
        for _ in 0..<3 { try await replica.acceptSeed(seed) }
        let storage = NotebookCatalogStorage(directory: root)
        let installed = try XCTUnwrap(replica.catalogSnapshot)
        let foreign = try NotebookCatalogDocument()
        try foreign.snapshot().data.write(to: storage.currentURL)
        do {
            try await replica.acceptSeed(seed)
            XCTFail("A valid catalog for another notebook must be rejected")
        } catch {
            XCTAssertEqual(
                error as? NotebookCatalogStorageError,
                .notebookIdentityMismatch
            )
        }
        try installed.data.write(to: storage.currentURL)
        for _ in 0..<3 { try await replica.acceptSeed(seed) }

        let corrupt = Data("damaged outside the replica".utf8)
        try corrupt.write(to: storage.currentURL)

        replica.catalogWriteSuspension = { throw InjectedFailure.save }
        do {
            try await replica.acceptSeed(seed)
            XCTFail("Changed durable bytes must force the full path")
        } catch {
            XCTAssertTrue(error is InjectedFailure)
        }
        replica.catalogWriteSuspension = nil
        do {
            try await replica.acceptSeed(seed)
            XCTFail("The existing storage validation error must remain visible")
        } catch {
            XCTAssertEqual(
                error as? NotebookCatalogStorageError,
                .invalidCurrentDocument
            )
        }
        XCTAssertEqual(try Data(contentsOf: storage.currentURL), corrupt)
    }

    func testMissingCurrentCatalogFallsBackAndRestoresIt() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        let seed = SyncRecord(catalog: try XCTUnwrap(replica.catalogSnapshot))
        for _ in 0..<3 { try await replica.acceptSeed(seed) }
        let storage = NotebookCatalogStorage(directory: root)
        try FileManager.default.removeItem(at: storage.currentURL)

        try await replica.acceptSeed(seed)

        XCTAssertEqual(try Data(contentsOf: storage.currentURL),
            try XCTUnwrap(replica.catalogSnapshot).data)
        guard case .current = await storage.load() else {
            return XCTFail("The missing current catalog must be restored")
        }
    }

    func testCorruptPreviousCatalogCopyInvalidatesReuseAndIsReplaced() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        let seed = SyncRecord(catalog: try XCTUnwrap(replica.catalogSnapshot))
        for _ in 0..<3 { try await replica.acceptSeed(seed) }
        let storage = NotebookCatalogStorage(directory: root)
        try Data("damaged previous copy".utf8).write(to: storage.previousURL)
        try await replica.acceptSeed(seed)

        let installed = try XCTUnwrap(replica.catalogSnapshot)
        XCTAssertEqual(try Data(contentsOf: storage.currentURL), installed.data)
        XCTAssertEqual(try Data(contentsOf: storage.previousURL), installed.data)

        try FileManager.default.removeItem(at: storage.previousURL)
        try await replica.acceptSeed(seed)
        XCTAssertEqual(try Data(contentsOf: storage.previousURL),
            try XCTUnwrap(replica.catalogSnapshot).data)
    }

    func testNewDeletionLedgerIDIsMergedBeforeSeedPersistence() async throws {
        for previousState in ["matching", "corrupt", "missing"] {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let replica = NotebookReplica(directory: root)
            try await replica.createLocalNotebook()
            let note = try await replica.createNote(name: "Note.md")
            let seed = SyncRecord(catalog: try XCTUnwrap(replica.catalogSnapshot))
            for _ in 0..<3 { try await replica.acceptSeed(seed) }
            let installed = try XCTUnwrap(replica.catalogSnapshot)
            let storage = NotebookCatalogStorage(directory: root)
            if previousState == "matching" {
                XCTAssertEqual(
                    try Data(contentsOf: storage.previousURL), installed.data
                )
            } else if previousState == "corrupt" {
                try Data("damaged previous copy".utf8).write(to: storage.previousURL)
            } else if previousState == "missing" {
                try FileManager.default.removeItem(at: storage.previousURL)
            }
            _ = try NotebookDeletionStorage(directory: root).record(
                [note], notebookID: installed.notebookID
            )

            replica.catalogWriteSuspension = { throw InjectedFailure.save }
            do {
                try await replica.acceptSeed(seed)
                XCTFail("A refreshed deletion ledger must force persistence")
            } catch {
                XCTAssertTrue(error is InjectedFailure)
            }
            XCTAssertTrue(try replica.deletedIDs.contains(note))
            XCTAssertFalse(replica.placements.contains { $0.item.id == note })

            replica.catalogWriteSuspension = nil
            try await replica.acceptSeed(seed)

            let persisted = try NotebookCatalogDocument(
                snapshot: try XCTUnwrap(replica.catalogSnapshot)
            )
            XCTAssertTrue(try XCTUnwrap(persisted.items().first {
                $0.id == note
            }).isPermanentlyDeleted)
            // A real catalog change preserves the prior valid revision.
            XCTAssertEqual(try Data(contentsOf: storage.previousURL), installed.data)
            let current = try XCTUnwrap(replica.catalogSnapshot)
            XCTAssertEqual(try Data(contentsOf: storage.currentURL), current.data)
            try await replica.acceptSeed(seed)
            XCTAssertEqual(try Data(contentsOf: storage.previousURL), current.data)
        }
    }

    func testAcceptSeedWaitsForAnInFlightCatalogWrite() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        let inbox = try await replica.createFolder(name: "Inbox")
        let seed = SyncRecord(catalog: try XCTUnwrap(replica.catalogSnapshot))
        for _ in 0..<3 { try await replica.acceptSeed(seed) }
        let writeEntered = expectation(description: "catalog write entered")
        var releaseWrite: CheckedContinuation<Void, Never>?
        replica.catalogWriteSuspension = {
            writeEntered.fulfill()
            await withCheckedContinuation { releaseWrite = $0 }
        }
        let write = Task {
            try await replica.setDefaultNewNoteParentID(inbox)
        }
        await fulfillment(of: [writeEntered], timeout: 2)

        // acceptSeed must not bypass the in-flight write; it queues behind it.
        replica.catalogWriteSuspension = nil
        let accept = Task { try await replica.acceptSeed(seed) }
        await Task.yield()
        XCTAssertNil(replica.defaultNewNoteParentID)
        releaseWrite?.resume()
        try await write.value
        try await accept.value
        XCTAssertEqual(replica.defaultNewNoteParentID, inbox)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "NotebookSeedReuseTests-\(UUID().uuidString)"
        )
    }
}

private enum InjectedFailure: Error {
    case save
}
