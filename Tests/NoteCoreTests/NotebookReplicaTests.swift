import Foundation
import XCTest

@testable import NoteCore

@MainActor
final class NotebookReplicaTests: XCTestCase {
    func testLifecycleFlushPersistsAllOpenNotesWithoutSync() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        let first = try await replica.createNote(name: "First.md", text: "first")
        let second = try await replica.createNote(name: "Second.md", text: "second")
        let a = try await replica.openNote(first)
        let b = try await replica.openNote(second)
        try a.replaceAll(with: "first edited")
        try b.replaceAll(with: "second edited")
        XCTAssertEqual(a.status, .saving)
        XCTAssertEqual(b.status, .saving)

        try await replica.flushOpenNotes()

        XCTAssertEqual(a.status, .saved)
        XCTAssertEqual(b.status, .saved)
        for (id, expected) in [(first, "first edited"), (second, "second edited")] {
            let stored = try NoteDocument(serializedData: Data(
                contentsOf: replica.noteStorage(id).currentURL
            ))
            XCTAssertEqual(try stored.text, expected)
        }
    }

    func testUnlistedBodyIsCheckpointedButNotUploaded() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        let note = try NoteDocument(text: "not yet linked")
        let record = SyncRecord(
            snapshot: note.snapshot(), notebookID: replica.catalogSnapshot!.notebookID)
        try await replica.apply(record)
        let outgoing = try await replica.records()
        XCTAssertFalse(outgoing.contains { $0.kind == .note })
        let checkpoint = [record.documentKey: note.heads]
        let before = try await replica.containsHistory(checkpoint, deleted: [])
        XCTAssertTrue(before)
        try FileManager.default.removeItem(at: replica.noteStorage(note.noteID).currentURL)
        let after = try await replica.containsHistory(checkpoint, deleted: [])
        XCTAssertFalse(after, "A lost staged body must trigger replay even before metadata arrives")
    }

    func testPermanentMarkerSurvivesRestoreAndRecoversUnknownChild() throws {
        let original = try NotebookCatalogDocument()
        let folder = try original.add(kind: .folder, name: "Folder")
        let known = try original.add(kind: .note, name: "Known.md", parentID: folder)
        try original.setTrashed(folder, true)
        let deleting = try original.fork()
        let offline = try original.fork()
        try deleting.markPermanentlyDeleted([folder, known])
        try offline.setTrashed(folder, false)
        try offline.rename(known, to: "Offline.md")
        let unknown = try offline.add(kind: .note, name: "New.md", parentID: folder)
        try deleting.merge(offline)
        let visible = try deleting.placements()
        XCTAssertEqual(visible.map { $0.item.id }, [unknown])
        XCTAssertNil(visible[0].parentID)
        XCTAssertTrue(visible[0].issues.contains(.missingParent))
        XCTAssertEqual(
            Set(try deleting.items().filter(\.isPermanentlyDeleted).map(\.id)), [folder, known])
    }

    func testConcurrentOpeningAndDownloadShareOneSession() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        let id = try await replica.createNote(name: "Note.md", text: "base")
        let stored = try NoteDocument(
            serializedData: Data(contentsOf: replica.noteStorage(id).currentURL))
        try stored.replaceAll(with: "remote")
        let record = SyncRecord(
            snapshot: stored.snapshot(), notebookID: replica.catalogSnapshot!.notebookID)
        async let opened = replica.openNote(id)
        async let received: Void = replica.apply(record)
        let session = try await opened
        try await received
        XCTAssertEqual(session.text, "remote")
        let reopened = try await replica.openNote(id)
        XCTAssertTrue(session === reopened)
    }
}
