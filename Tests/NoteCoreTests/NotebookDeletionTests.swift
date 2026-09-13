import Foundation
import XCTest

@testable import NoteCore

@MainActor
final class NotebookDeletionTests: XCTestCase {
    private enum InjectedFailure: Error { case stop }

    func testSubtreeDeletesOnlyConfirmedTrashIdentities() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        let folder = try await replica.createFolder(name: "Folder")
        let known = try await replica.createNote(
            name: "Known.md",
            text: "known",
            parentID: folder
        )
        let other = try await replica.createNote(name: "Other.md", text: "other")
        let offline = try NotebookCatalogDocument(
            snapshot: XCTUnwrap(replica.catalogSnapshot)
        )
        let lateDocument = try NoteDocument(text: "retain me")
        try offline.add(
            id: lateDocument.noteID,
            kind: .note,
            name: "Late.md",
            parentID: folder
        )
        try await replica.apply(SyncRecord(
            snapshot: lateDocument.snapshot(),
            notebookID: offline.notebookID
        ))
        try await replica.setTrashed(folder, true)
        try await replica.setTrashed(other, true)

        let selection = try replica.deletionSelection(rootID: folder)
        XCTAssertEqual(selection.ids, [folder, known])
        try await replica.acceptSeed(SyncRecord(catalog: offline.snapshot()))
        let late = lateDocument.noteID

        try await replica.permanentlyDelete(selection)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: replica.noteStorage(known).currentURL.path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: replica.noteStorage(late).currentURL.path
        ))
        XCTAssertTrue(replica.placements.contains { $0.item.id == late })
        XCTAssertTrue(replica.placements.contains { $0.item.id == other })
        XCTAssertFalse(try replica.deletedIDs.contains(late))
    }

    func testSelectionRefusesAnItemRestoredAfterConfirmation() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        let note = try await replica.createNote(name: "Note.md", text: "keep")
        try await replica.setTrashed(note, true)
        let selection = try replica.deletionSelection(rootID: note)
        try await replica.setTrashed(note, false)

        do {
            try await replica.permanentlyDelete(selection)
            XCTFail("Expected restored content to be refused")
        } catch {
            XCTAssertEqual(
                error as? NotebookDeletionError,
                .itemNoLongerInTrash(note)
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: replica.noteStorage(note).currentURL.path
        ))
    }

    func testInterruptedCatalogMarkerReconcilesBeforePublishing() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        let note = try await replica.createNote(name: "Note.md", text: "delete")
        try await replica.setTrashed(note, true)
        let selection = try replica.deletionSelection(rootID: note)
        replica.deletionFaultInjector = { stage in
            if stage == .ledgerSaved { throw InjectedFailure.stop }
        }

        do {
            try await replica.permanentlyDelete(selection)
            XCTFail("Expected interruption after the deletion ledger")
        } catch is InjectedFailure {}
        replica.deletionFaultInjector = nil
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: replica.noteStorage(note).currentURL.path
        ))

        let records = try await replica.records()
        let catalogRecord = try XCTUnwrap(records.last?.catalogSnapshot)
        let catalog = try NotebookCatalogDocument(snapshot: catalogRecord)
        XCTAssertTrue(try XCTUnwrap(catalog.items().first {
            $0.id == note
        }).isPermanentlyDeleted)

        try await replica.cleanupDeletedContent()
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: replica.noteStorage(note).currentURL.path
        ))
    }

    func testCleanupFailureKeepsMarkerAndCanBeRetried() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        let note = try await replica.createNote(name: "Note.md", text: "delete")
        try await replica.setTrashed(note, true)
        replica.deletionFaultInjector = { stage in
            if stage == .beforeNoteRemoval(note) { throw InjectedFailure.stop }
        }

        try await replica.permanentlyDelete(
            try replica.deletionSelection(rootID: note)
        )

        XCTAssertTrue(try replica.deletedIDs.contains(note))
        XCTAssertNotNil(replica.deletionCleanupErrorMessage)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: replica.noteStorage(note).currentURL.path
        ))

        replica.deletionFaultInjector = nil
        try await replica.cleanupDeletedContent()
        XCTAssertNil(replica.deletionCleanupErrorMessage)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: replica.noteStorage(note).currentURL.path
        ))
    }

    func testCleanupScrubsRetainedImportWithoutDeletingUnknownChild() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        let folder = try await replica.createFolder(name: "Imported")
        let note = try await replica.createNote(
            name: "Delete.md",
            text: "delete",
            parentID: folder
        )
        try await replica.setTrashed(folder, true)
        let retained = try NoteDocument(text: "retain")
        let journal = NotebookImportJournal(
            notebookID: replica.catalogSnapshot!.notebookID,
            plan: NotebookImportPlan(
                id: UUID(),
                entries: [
                    NotebookImportEntry(
                        id: folder, kind: .folder, name: "Imported",
                        parentID: nil, text: nil
                    ),
                    NotebookImportEntry(
                        id: note, kind: .note, name: "Delete.md",
                        parentID: folder, text: "delete"
                    ),
                    NotebookImportEntry(
                        id: retained.noteID, kind: .note, name: "Retain.md",
                        parentID: folder, text: "retain"
                    ),
                ],
                skippedPaths: []
            ),
            snapshots: [
                try NoteDocument(noteID: note, text: "delete").snapshot(),
                retained.snapshot(),
            ]
        )
        let importStorage = NotebookImportStorage(directory: root)
        try importStorage.create(journal)
        let interrupted = root.appending(path: ".pending-import-interrupted.tmp")
        try FileManager.default.linkItem(
            at: importStorage.journalURL,
            to: interrupted
        )

        try await replica.permanentlyDelete(
            try replica.deletionSelection(rootID: folder)
        )

        let scrubbed = try importStorage.load()
        XCTAssertEqual(scrubbed.plan.entries.map(\.id), [retained.noteID])
        XCTAssertNil(scrubbed.plan.entries[0].parentID)
        XCTAssertEqual(scrubbed.snapshots.map(\.noteID), [retained.noteID])
        let scrubbedInterrupted = try JSONDecoder().decode(
            NotebookImportJournal.self,
            from: Data(contentsOf: interrupted)
        )
        XCTAssertEqual(
            scrubbedInterrupted.plan.entries.map(\.id),
            [retained.noteID]
        )
        XCTAssertEqual(
            scrubbedInterrupted.snapshots.map(\.noteID),
            [retained.noteID]
        )
    }

    func testCatalogRecoveryCannotRollBackDeletionLedger() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        let note = try await replica.createNote(name: "Note.md", text: "delete")
        try await replica.setTrashed(note, true)
        try await replica.permanentlyDelete(
            try replica.deletionSelection(rootID: note)
        )

        let catalogStorage = NotebookCatalogStorage(directory: root)
        try Data("damaged".utf8).write(to: catalogStorage.currentURL)
        let recovering = NotebookReplica(directory: root)
        do {
            try await recovering.load()
            XCTFail("Expected explicit catalog recovery")
        } catch {
            XCTAssertEqual(error as? NotebookReplicaError, .catalogNeedsRecovery)
        }
        try await recovering.recoverCatalogFromPrevious()

        XCTAssertTrue(try recovering.deletedIDs.contains(note))
        let recovered = try NotebookCatalogDocument(
            snapshot: XCTUnwrap(recovering.catalogSnapshot)
        )
        XCTAssertTrue(try XCTUnwrap(recovered.items().first {
            $0.id == note
        }).isPermanentlyDeleted)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    }
}
