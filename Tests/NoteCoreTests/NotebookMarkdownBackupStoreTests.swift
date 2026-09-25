import Foundation
import XCTest
@testable import NoteCore

final class NotebookMarkdownBackupStoreTests: XCTestCase {
    func testBackupPreservesMarkdownTreeAndExcludesTrash() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try NotebookCatalogDocument()
        let folder = try catalog.add(kind: .folder, name: "Projects")
        try catalog.add(kind: .folder, name: "Empty", parentID: folder)
        let first = try NoteDocument(text: "# Exact 👋\nSecond line\n")
        let second = try NoteDocument(text: "Other\r\n")
        let trashed = try NoteDocument(text: "Hidden")
        try catalog.add(id: first.noteID, kind: .note, name: "Draft", parentID: folder)
        try catalog.add(id: second.noteID, kind: .note, name: "draft.md", parentID: folder)
        try catalog.add(id: trashed.noteID, kind: .note, name: "Discarded")
        _ = try catalog.trashItems([trashed.noteID])
        let store = NotebookMarkdownBackupStore(directory: root)
        let backup = try await store.createBackup(
            catalog: catalog.snapshot(),
            placements: catalog.placements(),
            notes: [first.snapshot(), second.snapshot(), trashed.snapshot()],
            retentionCount: 14
        )
        let projects = backup.url.appending(path: "Projects")
        let names = try Set(FileManager.default.contentsOfDirectory(atPath: projects.path))
        XCTAssertTrue(names.contains("Empty"))
        XCTAssertEqual(names.filter { $0.lowercased().hasPrefix("draft") }.count, 2)
        let noteContents = try names.filter { $0.hasSuffix(".md") }.map {
            try Data(contentsOf: projects.appending(path: $0))
        }
        XCTAssertEqual(
            Set(noteContents),
            Set([Data("# Exact 👋\nSecond line\n".utf8), Data("Other\r\n".utf8)])
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: backup.url.appending(path: "Discarded.md").path
        ))
        XCTAssertEqual(backup.noteCount, 2)
        let listed = try await store.listBackups()
        XCTAssertEqual(listed.map(\.url), [backup.url])
    }

    func testRetentionOnlyRemovesOlderOwnedCompletedBackupsAfterSuccess() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try NotebookCatalogDocument()
        let note = try NoteDocument(text: "Persisted")
        try catalog.add(id: note.noteID, kind: .note, name: "Note")
        let store = NotebookMarkdownBackupStore(directory: root)
        let first = try await store.createBackup(
            catalog: catalog.snapshot(), placements: catalog.placements(),
            notes: [note.snapshot()], retentionCount: 2,
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let userFolder = root.appending(path: "Backup-user-folder")
        try FileManager.default.createDirectory(at: userFolder, withIntermediateDirectories: true)
        let second = try await store.createBackup(
            catalog: catalog.snapshot(), placements: catalog.placements(),
            notes: [note.snapshot()], retentionCount: 2,
            createdAt: Date(timeIntervalSince1970: 20)
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await store.createBackup(
                catalog: catalog.snapshot(), placements: catalog.placements(),
                notes: [], retentionCount: 2
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.url.path))
        let third = try await store.createBackup(
            catalog: catalog.snapshot(), placements: catalog.placements(),
            notes: [note.snapshot()], retentionCount: 2,
            createdAt: Date(timeIntervalSince1970: 30)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: third.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: userFolder.path))
        let listed = try await store.listBackups()
        XCTAssertEqual(listed.map(\.url), [third.url, second.url])
        try await store.enforceRetention(notebookID: catalog.notebookID, keeping: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: third.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: userFolder.path))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "NotebookMarkdownBackupStoreTests-\(UUID().uuidString)"
        )
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void
) async {
    do {
        try await expression()
        XCTFail("Expected an error")
    } catch { }
}
