import Foundation
import XCTest

@testable import NoteCore

@MainActor
final class NotebookBrowserIntegrationTests: XCTestCase {
    func testNoOpMoveDoesNotRotateDurableCatalog() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        let note = try await replica.createNote(name: "Already last.md")
        let storage = NotebookCatalogStorage(directory: root)
        let current = try Data(contentsOf: storage.currentURL)
        let previous = try Data(contentsOf: storage.previousURL)
        let receipt = try await replica.moveItems([note], to: nil)
        XCTAssertNil(receipt)
        XCTAssertEqual(try Data(contentsOf: storage.currentURL), current)
        XCTAssertEqual(try Data(contentsOf: storage.previousURL), previous)
    }

    func testBatchMoveKeepsSubtreeBodiesAndUndoAcrossRename() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        let folder = try await replica.createFolder(name: "Moons")
        let destination = try await replica.createFolder(name: "Archive")
        let child = try await replica.createNote(
            name: "Europa.md", text: "\u{FEFF}# Ice\r\n👋🏽\r\n", parentID: folder)
        let peer = try await replica.createNote(name: "Comet.md", text: "A fictional comet.\n")
        let session = try await replica.openNote(child)
        let bodies = try await replica.persistedNoteSnapshots()
        let undoResult = try await replica.moveItems([folder, child, peer], to: destination)
        let undo = try XCTUnwrap(undoResult)
        XCTAssertEqual(Set(undo.itemIDs), [folder, peer])
        XCTAssertEqual(replica.placements.first { $0.item.id == child }?.parentID, folder)
        XCTAssertEqual(replica.placements.first { $0.item.id == folder }?.parentID, destination)
        let movedBodies = try await replica.persistedNoteSnapshots()
        XCTAssertEqual(movedBodies, bodies)
        let selected = try await replica.openNote(child)
        XCTAssertTrue(selected === session)

        try await replica.rename(folder, to: "Galilean moons")
        let redo = try await replica.undoBrowserChange(undo)
        XCTAssertNil(replica.placements.first { $0.item.id == folder }?.parentID)
        XCTAssertEqual(replica.placements.first { $0.item.id == folder }?.item.name, "Galilean moons")
        XCTAssertEqual(replica.placements.first { $0.item.id == child }?.parentID, folder)
        _ = try await replica.undoBrowserChange(redo)
        let reloaded = NotebookReplica(directory: root)
        try await reloaded.load()
        XCTAssertEqual(reloaded.placements, replica.placements)
        let reloadedBodies = try await reloaded.persistedNoteSnapshots()
        XCTAssertEqual(reloadedBodies, bodies)
    }

    func testBatchTrashAndUndoPreserveChildTrashAndEditedContent() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        let folder = try await replica.createFolder(name: "Expedition")
        let child = try await replica.createNote(name: "Lander.md", text: "old", parentID: folder)
        let undo = try await replica.trashItems([folder, child])
        XCTAssertEqual(undo.itemIDs, [folder])
        XCTAssertTrue(replica.placements.allSatisfy(\.isInTrash))
        let session = try await replica.openNote(child)
        try session.replaceAll(with: "A fictional landing report.\r\n")
        try await session.flush()
        try await replica.setTrashed(child, true)
        _ = try await replica.undoBrowserChange(undo)
        XCTAssertEqual(replica.placements.first { $0.item.id == folder }?.isInTrash, false)
        XCTAssertEqual(replica.placements.first { $0.item.id == child }?.isInTrash, true)
        XCTAssertEqual(session.text, "A fictional landing report.\r\n")
    }

    func testInvalidBatchAndStaleUndoLeaveCatalogUnchanged() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        let first = try await replica.createFolder(name: "First")
        let second = try await replica.createFolder(name: "Second")
        let note = try await replica.createNote(name: "Orbit.md")
        let before = replica.catalogSnapshot
        do {
            _ = try await replica.trashItems([note, UUID()])
            XCTFail("An invalid member must reject the entire selection")
        } catch {}
        XCTAssertEqual(replica.catalogSnapshot, before)
        let undoResult = try await replica.moveItems([note], to: first)
        let undo = try XCTUnwrap(undoResult)
        let remote = try NotebookCatalogDocument(snapshot: XCTUnwrap(replica.catalogSnapshot))
        try remote.move(note, to: second)
        try await replica.apply(SyncRecord(catalog: remote.snapshot()))
        let afterRemote = replica.catalogSnapshot
        do {
            _ = try await replica.undoBrowserChange(undo)
            XCTFail("Undo must not overwrite a later remote move")
        } catch {
            XCTAssertEqual(error as? NotebookBrowserChangeError, .staleUndo)
        }
        XCTAssertEqual(replica.catalogSnapshot, afterRemote)
        let reloaded = NotebookReplica(directory: root)
        try await reloaded.load()
        XCTAssertEqual(reloaded.catalogSnapshot, afterRemote)
    }
}
