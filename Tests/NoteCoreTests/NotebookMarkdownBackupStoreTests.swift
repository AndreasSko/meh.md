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

    func testOptionalAttachmentsPreserveBytesAndResolveNoteCollisions() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "source")
        let bytes = Data([0, 255, 10, 13, 42])
        try bytes.write(to: source)
        let attachments = NotebookAttachmentStore(directory: root.appending(path: "assets"))
        let catalog = try NotebookCatalogDocument()
        let folder = try catalog.add(kind: .folder, name: "Nested")
        try catalog.add(kind: .folder, name: "Empty", parentID: folder)
        let note = try NoteDocument(text: "Exact\r\n[[image.bin]]\n")
        try catalog.add(id: note.noteID, kind: .note, name: "draft", parentID: folder)
        for (name, parent) in [("draft.md", Optional(folder)), ("root.bin", nil),
                               ("hidden.bin", nil)] {
            let descriptor = try await attachments.storeFile(at: source, attachmentID: UUID())
            try catalog.add(id: descriptor.id, kind: .attachment, name: name,
                            parentID: parent, attachment: descriptor.content)
            if name == "hidden.bin" { _ = try catalog.trashItems([descriptor.id]) }
        }
        let store = NotebookMarkdownBackupStore(directory: root.appending(path: "backups"))
        let omitted = try await store.createBackup(
            catalog: catalog.snapshot(), placements: catalog.placements(),
            notes: [note.snapshot()], retentionCount: 2)
        XCTAssertEqual(omitted.attachmentCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: omitted.url.appending(path: "root.bin").path))
        let included = try await store.createBackup(
            catalog: catalog.snapshot(), placements: catalog.placements(),
            notes: [note.snapshot()], attachmentStore: attachments, retentionCount: 2)
        XCTAssertEqual(included.attachmentCount, 2)
        XCTAssertEqual(try Data(contentsOf: included.url.appending(path: "root.bin")), bytes)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: included.url.appending(path: "hidden.bin").path))
        let nested = included.url.appending(path: "Nested")
        let names = try FileManager.default.contentsOfDirectory(atPath: nested.path)
        XCTAssertTrue(names.contains("Empty"))
        let files = try names.filter { $0 != "Empty" }.map {
            try Data(contentsOf: nested.appending(path: $0))
        }
        XCTAssertEqual(Set(files), Set([bytes, Data("Exact\r\n[[image.bin]]\n".utf8)]))
        XCTAssertEqual(names.filter { $0.lowercased().hasPrefix("draft") }.count, 2)
        let listed = try await store.listBackups()
        XCTAssertEqual(listed.first?.attachmentCount, 2)
    }

    func testUnavailableAttachmentsDoNotPublishOrPruneAndLegacyMarkersRemainOwned() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "source")
        try Data([1, 2, 3]).write(to: source)
        let attachments = NotebookAttachmentStore(directory: root.appending(path: "assets"))
        let descriptor = try await attachments.storeFile(at: source, attachmentID: UUID())
        let catalog = try NotebookCatalogDocument()
        try catalog.add(id: descriptor.id, kind: .attachment, name: "image.bin",
                        attachment: descriptor.content)
        let store = NotebookMarkdownBackupStore(directory: root.appending(path: "backups"))
        let previous = try await store.createBackup(
            catalog: catalog.snapshot(), placements: catalog.placements(), notes: [],
            retentionCount: 1, createdAt: Date(timeIntervalSince1970: 10))
        let marker = previous.url.appending(path: ".meh-markdown-backup.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: marker))
            as? [String: Any])
        json.removeValue(forKey: "attachmentCount")
        try JSONSerialization.data(withJSONObject: json).write(to: marker)
        let legacy = try await store.listBackups()
        XCTAssertEqual(legacy.first?.attachmentCount, 0)
        let stored = try await attachments.verifiedFileURL(for: descriptor)
        try Data([9]).write(to: stored)
        await XCTAssertThrowsErrorAsync {
            _ = try await store.createBackup(
                catalog: catalog.snapshot(), placements: catalog.placements(), notes: [],
                attachmentStore: attachments, retentionCount: 1)
        }
        try await attachments.remove(id: descriptor.id)
        await XCTAssertThrowsErrorAsync {
            _ = try await store.createBackup(
                catalog: catalog.snapshot(), placements: catalog.placements(), notes: [],
                attachmentStore: attachments, retentionCount: 1)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: previous.url.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            atPath: store.directory.path), [previous.url.lastPathComponent])
        let next = try await store.createBackup(
            catalog: catalog.snapshot(), placements: catalog.placements(), notes: [],
            retentionCount: 1, createdAt: Date(timeIntervalSince1970: 20))
        XCTAssertFalse(FileManager.default.fileExists(atPath: previous.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: next.url.path))
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
