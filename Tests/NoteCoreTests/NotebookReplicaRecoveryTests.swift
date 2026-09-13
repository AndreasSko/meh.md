import Foundation
import XCTest

@testable import NoteCore

@MainActor
final class NotebookReplicaRecoveryTests: XCTestCase {
    func testRecoverySessionStaysRegisteredAfterExplicitRecovery() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = NotebookReplica(directory: root)
        try await original.createLocalNotebook()
        let id = try await original.createNote(name: "Note.md", text: "previous")
        let session = try await original.openNote(id)
        try session.replaceAll(with: "current")
        try await session.flush()
        try Data("damaged".utf8).write(to: original.noteStorage(id).currentURL)

        let reopened = NotebookReplica(directory: root)
        try await reopened.load()
        do {
            _ = try await reopened.openNote(id)
            XCTFail("Ordinary opening must retain its unavailable-note behavior")
        } catch {
            XCTAssertEqual(error as? NotebookReplicaError, .noteUnavailable(id))
        }

        let recovering = try await reopened.openNote(id, allowingRecovery: true)
        guard case .recoveryRequired = recovering.status else {
            return XCTFail("Expected an explicitly recoverable session")
        }
        do {
            _ = try await reopened.openNote(id)
            XCTFail("Ordinary opening must still reject a recovery session")
        } catch {
            XCTAssertEqual(error as? NotebookReplicaError, .noteUnavailable(id))
        }
        let retained = try await reopened.openNote(id, allowingRecovery: true)
        XCTAssertTrue(recovering === retained)
        await recovering.recoverFromPrevious()
        XCTAssertEqual(recovering.text, "previous")
        XCTAssertEqual(recovering.status, .saved)
        let openedAgain = try await reopened.openNote(id)
        XCTAssertTrue(recovering === openedAgain)
    }

    func testWrongIdentityIsBlockedForLoadSaveAndRecovery() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        let expectedID = try await replica.createNote(name: "Expected.md")
        let wrong = try NoteDocument(text: "wrong note").snapshot()
        let storage = ExistingNotebookNoteStorage(
            expectedID: expectedID, base: replica.noteStorage(expectedID))

        try wrong.data.write(to: replica.noteStorage(expectedID).currentURL)
        let loaded = await storage.load()
        guard case .blocked = loaded else {
            return XCTFail("A valid document with the wrong identity must be blocked")
        }

        do {
            try await storage.save(wrong)
            XCTFail("A wrong-identity snapshot must not be saved")
        } catch {
            XCTAssertEqual(error as? NoteFileStorageError, .noteIdentityMismatch)
        }

        do {
            _ = try await storage.recover(
                NoteRecovery(previous: wrong, currentFailure: .corrupt))
            XCTFail("A wrong-identity recovery must not modify the current file")
        } catch {
            XCTAssertEqual(error as? NoteFileStorageError, .noteIdentityMismatch)
        }
        XCTAssertEqual(try Data(contentsOf: storage.base.currentURL), wrong.data)
    }

    func testCatalogRecoveryReappliesRememberedDeletion() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = NotebookReplica(directory: root)
        try await original.createLocalNotebook()
        let id = try await original.createNote(name: "Note.md")
        try await original.rename(id, to: "Renamed.md")
        let catalogStorage = NotebookCatalogStorage(directory: root)
        try Data("damaged".utf8).write(to: catalogStorage.currentURL)

        let recovering = NotebookReplica(directory: root)
        do {
            try await recovering.load()
            XCTFail("The damaged catalog must require explicit recovery")
        } catch {
            XCTAssertEqual(error as? NotebookReplicaError, .catalogNeedsRecovery)
        }
        try await recovering.rememberDeletions([id])
        try await recovering.recoverCatalogFromPrevious()
        XCTAssertTrue(try recovering.deletedIDs.contains(id))
        XCTAssertFalse(recovering.placements.contains { $0.item.id == id })

        let reopened = NotebookReplica(directory: root)
        try await reopened.load()
        XCTAssertTrue(try reopened.deletedIDs.contains(id))
        XCTAssertFalse(reopened.placements.contains { $0.item.id == id })
    }

    func testPersistedSnapshotsReturnsOnlyListedNoteBodies() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        _ = try await replica.createFolder(name: "Folder")
        let first = try await replica.createNote(name: "One.md", text: "one")
        let second = try await replica.createNote(name: "Two.md", text: "two")

        let snapshots = try await replica.persistedNoteSnapshots()

        XCTAssertEqual(Set(snapshots.map(\.noteID)), [first, second])
        let texts = try snapshots.map { try NoteDocument(snapshot: $0).text }
        XCTAssertEqual(Set(texts), ["one", "two"])
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "NotebookReplicaRecoveryTests-\(UUID().uuidString)")
    }
}
