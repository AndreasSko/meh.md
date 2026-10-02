import Foundation
import NoteCore
import XCTest

@testable import NotebookAppModel

@MainActor
final class NotebookAttachmentWorkspaceTests: XCTestCase {
    private enum TestError: Error { case coordinatorDidNotStart }

    func testAccountChangeStopsEstablishedAttachmentCoordinator() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "attachment-workspace-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root,
            withIntermediateDirectories: true)

        let service = InMemoryAttachmentStore()
        let attachmentTransport = InMemoryAttachmentTransport(
            scope: "account-one", store: service
        )
        let workspace = NotebookWorkspace(
            directory: root.appending(path: "Notebook"),
            documentsDirectory: root.appending(path: "Documents"),
            transport: InMemorySyncTransport(scope: "notebook-account-one"),
            automaticSync: false,
            attachmentTransport: attachmentTransport
        )
        await workspace.start()
        let replica = try XCTUnwrap(workspace.replica)
        let notebookID = try XCTUnwrap(replica.catalogSnapshot?.notebookID)
        let first = try await importFile(
            named: "before.pdf", into: replica, beneath: root
        )
        await workspace.refresh(manual: true)
        let old = try await coordinator(in: workspace)
        await old.synchronize(force: true)
        let beforeDownload = root.appending(path: "before-downloaded.pdf")
        try await attachmentTransport.download(
            first, notebookID: notebookID, to: beforeDownload
        )

        await workspace.receiveCloudActivity(.accountChanged)
        XCTAssertNil(workspace.attachmentTransfers)

        let second = try await importFile(
            named: "after.pdf", into: replica, beneath: root
        )
        await old.synchronize(force: true)
        do {
            _ = try await old.prepareAttachment(second.id)
            XCTFail("Stopped coordinator should reject new work")
        } catch is CancellationError {
            // Account change permanently stops this coordinator.
        }
        do {
            try await attachmentTransport.download(
                second, notebookID: notebookID,
                to: root.appending(path: "after-downloaded.pdf")
            )
            XCTFail("Old coordinator uploaded after the account changed")
        } catch NotebookAttachmentTransferError.notUploaded {
            // The previously injected transport received no new upload.
        }
    }

    func testScheduledResetStopsTransfersEvenForLocalFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "attachment-reset-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root,
            withIntermediateDirectories: true)

        let transport = InMemoryAttachmentTransport(
            scope: "reset-account", store: InMemoryAttachmentStore()
        )
        let workspace = NotebookWorkspace(
            directory: root.appending(path: "Notebook"),
            documentsDirectory: root.appending(path: "Documents"),
            transport: InMemorySyncTransport(scope: "reset-notebook"),
            automaticSync: false,
            attachmentTransport: transport
        )
        await workspace.start()
        let replica = try XCTUnwrap(workspace.replica)
        let notebookID = try XCTUnwrap(replica.catalogSnapshot?.notebookID)
        let uploaded = try await importFile(
            named: "uploaded.pdf", into: replica, beneath: root
        )
        await workspace.refresh(manual: true)
        let old = try await coordinator(in: workspace)
        await old.synchronize(force: true)
        let received = root.appending(path: "uploaded-received.pdf")
        try await transport.download(uploaded,
            notebookID: notebookID, to: received)
        XCTAssertTrue(FileManager.default.fileExists(atPath: received.path))

        // This file remains local, but has never reached the remote service.
        let pending = try await importFile(
            named: "pending.pdf", into: replica, beneath: root
        )
        workspace.localStorageResetWasScheduled()
        XCTAssertNil(workspace.attachmentTransfers)
        XCTAssertTrue(replica.localEditsSuspended)
        do {
            _ = try await workspace.prepareAttachment(uploaded.id)
            XCTFail("Reset should reject even an existing local file")
        } catch NotebookReplicaError.resetPending {}

        await old.synchronize(force: true)
        do {
            _ = try await old.prepareAttachment(pending.id)
            XCTFail("Discarded coordinator should reject new work")
        } catch is CancellationError {}
        do {
            try await transport.download(pending,
                notebookID: notebookID,
                to: root.appending(path: "pending-received.pdf"))
            XCTFail("Discarded coordinator uploaded after reset")
        } catch NotebookAttachmentTransferError.notUploaded {}
    }

    private func importFile(
        named name: String, into replica: NotebookReplica, beneath root: URL
    ) async throws -> NotebookAttachmentDescriptor {
        let source = root.appending(path: name)
        try Data("fictional attachment \(name)".utf8).write(to: source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(try Data(contentsOf: source).isEmpty)
        let scanner = NotebookImportScanner(
            attachmentStore: replica.attachmentStore
        )
        let plan = try await scanner.scan(urls: [source])
        try await replica.importMarkdown(plan)
        return try XCTUnwrap(plan.entries.first?.attachment)
    }

    private func coordinator(
        in workspace: NotebookWorkspace
    ) async throws -> NotebookAttachmentSyncCoordinator {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if let coordinator = workspace.attachmentTransfers {
                return coordinator
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TestError.coordinatorDidNotStart
    }
}
