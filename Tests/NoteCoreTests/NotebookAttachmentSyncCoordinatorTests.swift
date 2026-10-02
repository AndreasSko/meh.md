import Foundation
import CloudKit
import XCTest

@testable import NoteCore

@MainActor
final class NotebookAttachmentSyncCoordinatorTests: XCTestCase {
    nonisolated(unsafe) private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "attachment-sync-test-\(UUID())")
        try FileManager.default.createDirectory(at: url,
            withIntermediateDirectories: false)
        roots.append(url)
        return url
    }

    private func importedAttachment(
        in replica: NotebookReplica, source: URL
    ) async throws -> NotebookAttachmentDescriptor {
        let plan = try await NotebookImportScanner(
            attachmentStore: replica.attachmentStore
        ).scan(urls: [source])
        let entry = try XCTUnwrap(plan.entries.first { $0.kind == .attachment })
        try await replica.importMarkdown(plan)
        return try XCTUnwrap(entry.attachment)
    }

    private func sourceFile(in root: URL) throws -> (URL, Data) {
        let data = Data((0..<250_000).map { UInt8($0 % 251) })
        let source = root.appending(path: "illustration.bin")
        try data.write(to: source)
        return (source, data)
    }

    func testMetadataArrivesBeforeBytesAndDownloadIsOnDemand() async throws {
        let root = try directory()
        let (source, bytes) = try sourceFile(in: root)
        let metadata = InMemorySyncTransport(
            scope: "metadata", store: InMemorySyncStore())
        let attachments = InMemoryAttachmentStore()
        let left = NotebookReplica(directory: root.appending(path: "left"))
        let right = NotebookReplica(directory: root.appending(path: "right"))
        let leftMetadata = NotebookSyncCoordinator(replica: left,
            transport: metadata)
        let rightMetadata = NotebookSyncCoordinator(replica: right,
            transport: metadata)
        await leftMetadata.synchronize()
        await rightMetadata.synchronize()
        let descriptor = try await importedAttachment(in: left, source: source)
        await leftMetadata.synchronize()
        await rightMetadata.synchronize()
        XCTAssertEqual(try right.attachmentDescriptor(for: descriptor.id),
            descriptor)
        do {
            _ = try await right.attachmentFileURL(for: descriptor.id)
            XCTFail("Metadata alone downloaded the file")
        } catch NotebookAttachmentError.missing {} catch {
            XCTFail("Unexpected error: \(error)")
        }

        let leftTransfer = try NotebookAttachmentSyncCoordinator(
            replica: left, transport: InMemoryAttachmentTransport(
                scope: "attachments", store: attachments))
        let rightTransfer = try NotebookAttachmentSyncCoordinator(
            replica: right, transport: InMemoryAttachmentTransport(
                scope: "attachments", store: attachments))
        defer { leftTransfer.stop(); rightTransfer.stop() }
        await leftTransfer.synchronize()
        await rightTransfer.synchronize()
        XCTAssertNil(rightTransfer.statuses[descriptor.id])
        let received = try await rightTransfer.prepareAttachment(descriptor.id)
        XCTAssertEqual(try Data(contentsOf: received), bytes)
        XCTAssertEqual(rightTransfer.statuses[descriptor.id], .available)

        rightTransfer.stop()
        let reopened = NotebookReplica(directory: right.directory)
        try await reopened.load()
        let restarted = try NotebookAttachmentSyncCoordinator(
            replica: reopened, transport: InMemoryAttachmentTransport(
                scope: "attachments", store: attachments))
        defer { restarted.stop() }
        let reopenedURL = try await reopened.attachmentFileURL(
            for: descriptor.id)
        XCTAssertEqual(try Data(contentsOf: reopenedURL), bytes)
    }

    func testLostUploadAcknowledgementRetriesAfterRestart() async throws {
        let root = try directory()
        let (source, bytes) = try sourceFile(in: root)
        let replica = NotebookReplica(directory: root.appending(path: "left"))
        try await replica.createLocalNotebook()
        let descriptor = try await importedAttachment(in: replica,
            source: source)
        let service = InMemoryAttachmentStore()
        let transport = InMemoryAttachmentTransport(scope: "attachments",
            store: service)
        await service.loseNextAcknowledgement()
        let first = try NotebookAttachmentSyncCoordinator(replica: replica,
            transport: transport)
        await first.synchronize()
        XCTAssertNotNil(first.errorMessage)
        first.stop()

        let reopened = NotebookReplica(directory: replica.directory)
        try await reopened.load()
        let restarted = try NotebookAttachmentSyncCoordinator(
            replica: reopened, transport: transport)
        defer { restarted.stop() }
        await restarted.synchronize(force: true)
        XCTAssertEqual(restarted.statuses[descriptor.id], .uploaded)
        let destination = root.appending(path: "received.bin")
        try await transport.download(descriptor,
            notebookID: try XCTUnwrap(reopened.catalogSnapshot?.notebookID),
            to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
    }

    func testTransferFailureDoesNotBlockMarkdownExchange() async throws {
        let root = try directory()
        let (source, _) = try sourceFile(in: root)
        let metadata = InMemorySyncTransport(
            scope: "metadata", store: InMemorySyncStore())
        let service = InMemoryAttachmentStore()
        let left = NotebookReplica(directory: root.appending(path: "left"))
        let right = NotebookReplica(directory: root.appending(path: "right"))
        let leftMetadata = NotebookSyncCoordinator(replica: left,
            transport: metadata)
        let rightMetadata = NotebookSyncCoordinator(replica: right,
            transport: metadata)
        await leftMetadata.synchronize()
        await rightMetadata.synchronize()
        _ = try await importedAttachment(in: left, source: source)
        let noteID = try await left.createNote(name: "still-syncs.md",
            text: "Markdown survives attachment outage")
        let transfer = try NotebookAttachmentSyncCoordinator(replica: left,
            transport: InMemoryAttachmentTransport(
                scope: "attachments", store: service))
        defer { transfer.stop() }
        await service.setOffline(true)
        await transfer.synchronize()
        XCTAssertNotNil(transfer.errorMessage)
        await leftMetadata.synchronize()
        await rightMetadata.synchronize()
        let receivedNote = try await right.openNote(noteID)
        XCTAssertEqual(receivedNote.text,
            "Markdown survives attachment outage")
    }

    func testRemoteTombstoneRequiresConfirmedCatalogDeletion() async throws {
        let root = try directory()
        let (source, _) = try sourceFile(in: root)
        let metadata = InMemorySyncTransport(
            scope: "metadata", store: InMemorySyncStore())
        let service = InMemoryAttachmentStore()
        let replica = NotebookReplica(directory: root.appending(path: "left"))
        let catalog = NotebookSyncCoordinator(replica: replica,
            transport: metadata)
        await catalog.synchronize()
        let descriptor = try await importedAttachment(in: replica,
            source: source)
        await catalog.synchronize()
        let transport = InMemoryAttachmentTransport(scope: "attachments",
            store: service)
        let transfer = try NotebookAttachmentSyncCoordinator(replica: replica,
            transport: transport)
        defer { transfer.stop() }
        await transfer.synchronize()
        try await replica.setTrashed(descriptor.id, true)
        try await replica.permanentlyDelete(
            replica.deletionSelection(rootID: descriptor.id))
        await transfer.synchronize()
        let notebookID = try XCTUnwrap(replica.catalogSnapshot?.notebookID)
        let before = root.appending(path: "before-delete.bin")
        try await transport.download(descriptor,
            notebookID: notebookID, to: before)

        await catalog.synchronize()
        let confirmed = try catalog.acknowledgedAttachmentDeletions()
        XCTAssertTrue(confirmed.contains(descriptor.id))
        await transfer.synchronize(confirmedDeletedIDs: confirmed, force: true)
        do {
            try await transport.upload(descriptor,
                notebookID: notebookID, from: source)
            XCTFail("Late upload resurrected a deleted file")
        } catch {
            XCTAssertEqual(error as? NotebookAttachmentTransferError, .deleted)
        }
    }

    func testPersistedStateRejectsDifferentTransferScope() async throws {
        let root = try directory()
        let replica = NotebookReplica(directory: root.appending(path: "left"))
        try await replica.createLocalNotebook()
        let service = InMemoryAttachmentStore()
        let first = try NotebookAttachmentSyncCoordinator(replica: replica,
            transport: InMemoryAttachmentTransport(scope: "account-one",
                store: service))
        await first.synchronize()
        first.stop()
        XCTAssertThrowsError(try NotebookAttachmentSyncCoordinator(
            replica: replica,
            transport: InMemoryAttachmentTransport(scope: "account-two",
                store: service))) {
            XCTAssertEqual($0 as? SyncError, .scopeChanged)
        }
    }

    func testServerDeadlineSurvivesManualRetryAndRestart() async throws {
        let root = try directory()
        let (source, _) = try sourceFile(in: root)
        let replica = NotebookReplica(directory: root.appending(path: "left"))
        try await replica.createLocalNotebook()
        let descriptor = try await importedAttachment(in: replica, source: source)
        let transport = ThrottledAttachmentTransport()
        let first = try NotebookAttachmentSyncCoordinator(
            replica: replica, transport: transport)
        await first.synchronize()
        XCTAssertNotNil(first.errorMessage)
        await first.synchronize(force: true)
        first.stop()

        let restarted = try NotebookAttachmentSyncCoordinator(
            replica: replica, transport: transport)
        defer { restarted.stop() }
        await restarted.synchronize(force: true)
        try await replica.attachmentStore.remove(id: descriptor.id)
        do {
            _ = try await restarted.prepareAttachment(descriptor.id)
            XCTFail("A requested download bypassed the server deadline")
        } catch {}
        let calls = await transport.callCount
        XCTAssertEqual(calls, 1)
    }
}

private actor ThrottledAttachmentTransport: NotebookAttachmentTransport {
    nonisolated let scope = "throttled"
    private(set) var callCount = 0

    func upload(_ descriptor: NotebookAttachmentDescriptor,
                notebookID: UUID, from: URL) async throws {
        try reject()
    }

    func download(_ descriptor: NotebookAttachmentDescriptor,
                  notebookID: UUID, to: URL) async throws {
        try reject()
    }

    func delete(attachmentIDs: Set<UUID>, notebookID: UUID) async throws {
        try reject()
    }

    private func reject() throws {
        callCount += 1
        throw CKError(.requestRateLimited,
                      userInfo: [CKErrorRetryAfterKey: 3_600.0])
    }
}
