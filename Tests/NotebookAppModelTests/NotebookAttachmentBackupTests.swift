import Foundation
import NoteCore
import XCTest

@testable import NotebookAppModel

@MainActor
final class NotebookAttachmentBackupTests: XCTestCase {
    private let preferenceKey = "meh.md.backupIncludesAttachments"
    private let noteText = "# Fictional backup note\n"

    func testAttachmentPreferenceDefaultsOffAndPersists() throws {
        let previous = UserDefaults.standard.object(forKey: preferenceKey)
        defer { restorePreference(previous) }
        UserDefaults.standard.removeObject(forKey: preferenceKey)
        let root = directory()
        let first = workspace(root)
        XCTAssertFalse(first.backupIncludesAttachments)
        first.setBackupIncludesAttachments(true)
        XCTAssertTrue(workspace(root).backupIncludesAttachments)
        first.setBackupIncludesAttachments(false)
        XCTAssertFalse(workspace(root).backupIncludesAttachments)
    }

    func testLocalAttachmentIsOptionalAndSettingIsCapturedBeforeAwait() async throws {
        let previous = UserDefaults.standard.object(forKey: preferenceKey)
        defer { restorePreference(previous) }
        let root = directory()
        let model = workspace(root)
        model.backupFrequency = .off
        model.setBackupIncludesAttachments(false)
        await model.start()
        defer { model.localStorageResetWasScheduled() }
        let replica = try XCTUnwrap(model.replica)
        let descriptor = try await importFile(into: replica, root: root)
        try await model.backupNow()
        let first = try XCTUnwrap(model.lastBackup)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: first.url.appending(path: "Files/sample.pdf").path
        ))
        model.setBackupIncludesAttachments(true)
        try await model.backupNow(beforeBackup: {
            model.setBackupIncludesAttachments(false)
        })
        let second = try XCTUnwrap(model.lastBackup)
        XCTAssertEqual(try Data(contentsOf: second.url.appending(path: "Files/sample.pdf")),
                       Data("fictional PDF bytes".utf8))
        XCTAssertNotEqual(first.url, second.url)
        XCTAssertFalse(model.backupIncludesAttachments)
        let storage = try await model.storageReport(for: replica)
        let backupBytes = try XCTUnwrap(storage.categories.first {
            $0.category == .backups
        }?.byteCount)
        var markers: Int64 = 0
        for backup in [first, second] {
            let data = try Data(contentsOf: backup.url.appending(
                path: ".meh-markdown-backup.json"))
            markers += Int64(data.count)
        }
        XCTAssertEqual(backupBytes,
                       markers + descriptor.content.byteCount
                           + Int64(noteText.utf8.count * 2),
                       "Backup storage includes the copied attachment bytes")
        let localFile = try await replica.attachmentFileURL(for: descriptor.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: localFile.path))
        try await replica.setTrashed(descriptor.id, true)
        try await replica.attachmentStore.remove(id: descriptor.id)
        model.setBackupIncludesAttachments(true)
        try await model.backupNow()
        let withoutTrash = try XCTUnwrap(model.lastBackup)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: withoutTrash.url.appending(path: "Files/sample.pdf").path
        ))
    }

    func testRemoteAttachmentDownloadsAndOfflineFailureKeepsCompletedBackup() async throws {
        let previous = UserDefaults.standard.object(forKey: preferenceKey)
        defer { restorePreference(previous) }
        let root = directory()
        let service = InMemoryAttachmentStore()
        let transport = InMemoryAttachmentTransport(scope: "backup-test", store: service)
        let model = workspace(root, attachmentTransport: transport)
        model.backupFrequency = .off
        model.backupRetentionCount = 1
        model.setBackupIncludesAttachments(false)
        await model.start()
        defer { model.localStorageResetWasScheduled() }
        let replica = try XCTUnwrap(model.replica)
        let descriptor = try await importFile(into: replica, root: root)
        await model.refresh(manual: true)
        let notebookID = try XCTUnwrap(replica.catalogSnapshot?.notebookID)
        let source = try await replica.attachmentFileURL(for: descriptor.id)
        try await transport.upload(descriptor, notebookID: notebookID, from: source)
        try await replica.attachmentStore.remove(id: descriptor.id)
        model.setBackupIncludesAttachments(true)
        try await model.backupNow()
        let completed = try XCTUnwrap(model.lastBackup)
        XCTAssertEqual(try Data(contentsOf: completed.url.appending(path: "Files/sample.pdf")),
                       Data("fictional PDF bytes".utf8))
        try await replica.attachmentStore.remove(id: descriptor.id)
        await service.setOffline(true)
        do {
            try await model.backupNow()
            XCTFail("An unavailable attachment must fail the complete backup")
        } catch { }
        XCTAssertNotNil(model.backupError)
        XCTAssertEqual(model.lastBackup, completed)
        let backups = try await NotebookMarkdownBackupStore(
            directory: model.backupDirectory
        ).listBackups()
        XCTAssertEqual(backups, [completed])
    }

    private func importFile(into replica: NotebookReplica, root: URL) async throws
        -> NotebookAttachmentDescriptor {
        _ = try await replica.createNote(name: "Notes.md", text: noteText)
        let folder = root.appending(path: "Files")
        try FileManager.default.createDirectory(at: folder,
            withIntermediateDirectories: true)
        try Data("fictional PDF bytes".utf8).write(to: folder.appending(path: "sample.pdf"))
        let scanner = NotebookImportScanner(attachmentStore: replica.attachmentStore)
        let plan = try await scanner.scan(urls: [folder])
        try await replica.importMarkdown(plan)
        return try XCTUnwrap(plan.entries.first { $0.attachment != nil }?.attachment)
    }

    private func workspace(_ root: URL,
        attachmentTransport: (any NotebookAttachmentTransport)? = nil) -> NotebookWorkspace {
        NotebookWorkspace(directory: root.appending(path: "Notebook"),
            documentsDirectory: root.appending(path: "Documents"),
            transport: InMemorySyncTransport(scope: "backup-notebook"),
            automaticSync: false, storageBoundary: root,
            attachmentTransport: attachmentTransport)
    }

    private func directory() -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "backup-test-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func restorePreference(_ value: Any?) {
        if let value { UserDefaults.standard.set(value, forKey: preferenceKey) }
        else { UserDefaults.standard.removeObject(forKey: preferenceKey) }
    }
}
