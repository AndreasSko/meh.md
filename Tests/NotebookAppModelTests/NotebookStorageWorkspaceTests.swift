import Foundation
import NoteCore
import XCTest
@testable import NotebookAppModel

@MainActor
final class NotebookStorageWorkspaceTests: XCTestCase {
    func testAccountingUsesOnlySelectedWorkspaceAndIncludesNestedTrash() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "OwnedRun/Notebook")
        let documents = root.appending(path: "OwnedRun/Documents")
        let workspace = makeWorkspace(directory: directory, documents: documents)
        let replica = NotebookReplica(directory: directory)
        try await replica.createLocalNotebook()
        let folder = try await replica.createFolder(name: "Fictional expeditions")
        let nested = try await replica.createFolder(name: "Harbor", parentID: folder)
        let active = try await replica.createNote(
            name: "Lantern.md", text: "# Fictional lantern", parentID: nested)
        let discarded = try await replica.createNote(
            name: "Draft.md", text: "# Fictional draft", parentID: nested)
        _ = try await replica.trashItems([discarded])
        try write(documents.appending(path: "Notebook Copies/Markdown/Lantern.md"),
                  bytes: 101)
        try write(documents.appending(path: "Backups/owned/Lantern.md"), bytes: 103)
        let before = try await workspace.storageReport(for: replica)
        let activeUsage = try XCTUnwrap(before.documents.first { $0.id == active })
        let trashUsage = try XCTUnwrap(before.documents.first { $0.id == discarded })
        XCTAssertEqual(before.activeNoteCount, 1)
        XCTAssertEqual(before.trashNoteCount, 1)
        XCTAssertEqual(activeUsage.path, "Fictional expeditions / Harbor / Lantern.md")
        XCTAssertEqual(trashUsage.name, "Draft.md")
        XCTAssertTrue(trashUsage.isInTrash)
        XCTAssertTrue(trashUsage.path.hasSuffix("Draft.md"))
        XCTAssertEqual(before.categories.first { $0.category == .markdownCopies }?.byteCount, 101)
        XCTAssertEqual(before.categories.first { $0.category == .backups }?.byteCount, 103)
        XCTAssertGreaterThan(activeUsage.currentAndHistoryBytes, 0)
        XCTAssertGreaterThan(trashUsage.currentAndHistoryBytes, 0)

        // These names are fictional. Nothing outside this owned temp tree is touched.
        try write(root.appending(path: "Fictional personal notes/private.md"), bytes: 10_001)
        try write(root.appending(path: "OtherRun/Notebook/notes/foreign/note.automerge"),
                  bytes: 10_003)
        try write(root.appending(path: "OtherRun/Documents/Backups/foreign.md"), bytes: 10_007)
        try write(documents.appending(path: "Unrelated fictional file.md"), bytes: 10_009)
        let after = try await workspace.storageReport(for: replica)
        XCTAssertEqual(after.totalBytes, before.totalBytes)
        XCTAssertEqual(after.categories, before.categories)
        XCTAssertEqual(after.documents, before.documents)
        XCTAssertEqual(after.totalBytes,
            try files(in: directory).values.reduce(Int64(204)) { $0 + Int64($1.count) })
    }

    func testPendingEditsFlushAndRepeatedScansPreserveSavedHistoryAndFiles() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "Notebook")
        let documents = root.appending(path: "Documents")
        let workspace = makeWorkspace(directory: directory, documents: documents)
        let replica = NotebookReplica(directory: directory)
        try await replica.createLocalNotebook()
        let editedID = try await replica.createNote(
            name: "Fictional log.md", text: "# First fictional log")
        let unopenedID = try await replica.createNote(
            name: "Unopened.md", text: "# Unopened fictional note")
        let session = try await replica.openNote(editedID)
        let finalText = "# First fictional log\n\nA later fictional observation."
        try session.replaceAll(with: finalText)
        let expectedHistory = try session.historyVersions()
        let openIDs = replica.searchRevision.openNotes.map(\.id)
        XCTAssertEqual(openIDs, [editedID])
        let first = try await workspace.storageReport(for: replica)
        XCTAssertEqual(first.activeNoteCount, 2)
        XCTAssertTrue(first.documents.contains { $0.id == unopenedID })
        XCTAssertEqual(replica.searchRevision.openNotes.map(\.id), openIDs,
                       "Measurement must not create editor sessions for unopened notes")
        let savedFiles = try files(in: directory)
        let reopened = NotebookReplica(directory: directory)
        try await reopened.load()
        let durable = try await reopened.openNote(editedID)
        XCTAssertEqual(durable.text, finalText, "Measurement must flush pending edits")
        XCTAssertEqual(try durable.historyVersions(), expectedHistory)

        for _ in 0..<3 {
            let report = try await workspace.storageReport(for: replica)
            XCTAssertEqual(report.categories, first.categories)
            XCTAssertEqual(report.documents, first.documents)
            XCTAssertEqual(session.text, finalText)
            XCTAssertEqual(try session.historyVersions(), expectedHistory)
            XCTAssertEqual(replica.searchRevision.openNotes.map(\.id), openIDs)
            XCTAssertEqual(try files(in: directory), savedFiles,
                           "Saved current, recovery, catalog, and state bytes must stay intact")
        }
    }

    func testAttachmentAccountingFollowsInheritedTrashAndLocalResidency() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "OwnedRun/Notebook")
        let documents = root.appending(path: "OwnedRun/Documents")
        let workspace = makeWorkspace(directory: directory, documents: documents)
        let replica = NotebookReplica(directory: directory)
        try await replica.createLocalNotebook()
        let folder = try await replica.createFolder(name: "Fictional charts")
        let localSource = root.appending(path: "local.pdf")
        let remoteSource = root.appending(path: "remote.pdf")
        try write(localSource, bytes: 11)
        try write(remoteSource, bytes: 13)
        let scanner = NotebookImportScanner(attachmentStore: replica.attachmentStore)
        let plan = try await scanner.scan(urls: [localSource, remoteSource])
        try await replica.importMarkdown(plan, parentID: folder)
        let local = try XCTUnwrap(plan.entries.first { $0.name == "local.pdf" }?.attachment)
        let remote = try XCTUnwrap(plan.entries.first { $0.name == "remote.pdf" }?.attachment)
        // Keep catalog metadata but remove local bytes, as on a receiver
        // that has received the catalog before downloading attachment content.
        try await replica.attachmentStore.remove(id: remote.id)
        let initial = try await workspace.storageReport(for: replica)
        XCTAssertEqual(initial.activeAttachmentCount, 2)
        XCTAssertEqual(initial.trashAttachmentCount, 0)
        XCTAssertEqual(initial.residentAttachmentCount, 1)
        XCTAssertEqual(initial.categories.first { $0.category == .attachments }?.byteCount, 11)
        XCTAssertTrue(initial.documents.isEmpty)
        XCTAssertEqual(initial.totalBytes,
                       try files(in: directory).values.reduce(0) { $0 + Int64($1.count) })

        _ = try await replica.trashItems([folder])
        let trashed = try await workspace.storageReport(for: replica)
        XCTAssertEqual(trashed.activeAttachmentCount, 0)
        XCTAssertEqual(trashed.trashAttachmentCount, 2)
        XCTAssertEqual(trashed.residentAttachmentCount, 1)
        XCTAssertEqual(trashed.categories.first { $0.category == .attachments }?.byteCount, 11)
        try await replica.restoreItems([folder])
        let restored = try await workspace.storageReport(for: replica)
        XCTAssertEqual(restored.activeAttachmentCount, 2)
        XCTAssertEqual(restored.trashAttachmentCount, 0)
        XCTAssertEqual(restored.residentAttachmentCount, 1)

        _ = try await replica.trashItems([folder])
        try await replica.permanentlyDelete(replica.deletionSelection(rootID: folder))
        let deleted = try await workspace.storageReport(for: replica)
        XCTAssertEqual(deleted.activeAttachmentCount, 0)
        XCTAssertEqual(deleted.trashAttachmentCount, 0)
        XCTAssertEqual(deleted.residentAttachmentCount, 0)
        XCTAssertEqual(deleted.categories.first { $0.category == .attachments }?.byteCount, 0)
        // A retained cleanup leftover still consumes local storage, but is
        // no longer a managed attachment and must not revive its count.
        try write(directory.appending(path: "attachments/\(local.id)/content"), bytes: 23)
        let retained = try await workspace.storageReport(for: replica)
        XCTAssertEqual(retained.totalBytes, deleted.totalBytes + 23)
        XCTAssertEqual(retained.categories.first { $0.category == .other }?.byteCount,
                       (deleted.categories.first { $0.category == .other }?.byteCount ?? 0) + 23)
        XCTAssertEqual(retained.residentAttachmentCount, 0)
        try write(root.appending(path: "OtherRun/Notebook/attachments/\(UUID())/content"),
                  bytes: 10_001)
        try write(documents.appending(path: "Unrelated fictional attachment.pdf"), bytes: 10_003)
        let isolated = try await workspace.storageReport(for: replica)
        XCTAssertEqual(isolated.totalBytes, retained.totalBytes)
        XCTAssertEqual(isolated.categories, retained.categories)
        XCTAssertEqual(isolated.activeAttachmentCount, 0)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "NotebookStorageWorkspace-\(UUID())")
    }

    private func makeWorkspace(directory: URL, documents: URL) -> NotebookWorkspace {
        NotebookWorkspace(
            directory: directory, documentsDirectory: documents,
            transport: nil, automaticSync: false, mode: .preview,
            storageBoundary: directory.deletingLastPathComponent())
    }

    private func write(_ url: URL, bytes: Int) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 42, count: bytes).write(to: url)
    }

    private func files(in directory: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for child in try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey]) {
            if try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                for (path, data) in try files(in: child) {
                    result[child.lastPathComponent + "/" + path] = data
                }
            } else {
                result[child.lastPathComponent] = try Data(contentsOf: child)
            }
        }
        return result
    }
}
