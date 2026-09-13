import Foundation
import XCTest

@testable import NoteCore

final class CloudKitSyncActivityTests: XCTestCase {
    func testEmptyAndDuplicateFetchesDoNotProduceActivity() throws {
        var tracker = CloudKitSyncActivityTracker()

        tracker.recordFetch(recordCount: 0, deletionCount: 0)

        XCTAssertNil(tracker.finishFetch(reason: .scheduled))
        XCTAssertNil(tracker.finishFetch(reason: .manual))
    }

    func testFetchActivityAccumulatesDurableChangesUntilCompletion() {
        var tracker = CloudKitSyncActivityTracker()
        tracker.recordFetch(recordCount: 2, deletionCount: 0)
        tracker.recordFetch(recordCount: 1, deletionCount: 1)

        XCTAssertEqual(
            tracker.finishFetch(reason: .manual),
            .remoteChanges(
                recordCount: 3,
                deletionCount: 1,
                reason: .manual
            )
        )
        XCTAssertNil(tracker.finishFetch(reason: .scheduled))
    }

    func testOnlyScheduledAcknowledgementsProduceActivity() {
        var tracker = CloudKitSyncActivityTracker()
        tracker.recordAcknowledgements(2)

        XCTAssertNil(tracker.finishSend(wasScheduled: false))

        tracker.recordAcknowledgements(3)
        XCTAssertEqual(
            tracker.finishSend(wasScheduled: true),
            .uploadsAcknowledged(recordCount: 3)
        )
        XCTAssertNil(tracker.finishSend(wasScheduled: true))
    }

    func testActivityChannelPreservesBufferedOrder() async {
        let channel = CloudKitSyncActivityChannel()
        channel.yield([
            .remoteChanges(
                recordCount: 1,
                deletionCount: 0,
                reason: .scheduled
            ),
            .uploadsAcknowledged(recordCount: 2),
        ])
        var iterator = channel.stream.makeAsyncIterator()

        let first = await iterator.next()
        let second = await iterator.next()

        XCTAssertEqual(
            first,
            .remoteChanges(
                recordCount: 1,
                deletionCount: 0,
                reason: .scheduled
            )
        )
        XCTAssertEqual(
            second,
            .uploadsAcknowledged(recordCount: 2)
        )
    }

    func testActivityChannelCoalescesFloodWithoutDroppingControls() async {
        let channel = CloudKitSyncActivityChannel()
        var iterator = channel.stream.makeAsyncIterator()
        channel.yield([.uploadsAcknowledged(recordCount: 1)])
        let initial = await iterator.next()
        XCTAssertEqual(
            initial,
            .uploadsAcknowledged(recordCount: 1)
        )

        for _ in 0..<100 {
            channel.yield([
                .remoteChanges(
                    recordCount: 1,
                    deletionCount: 1,
                    reason: .scheduled
                ),
                .uploadsAcknowledged(recordCount: 1),
            ])
        }
        channel.yield([
            .accountChanged,
            .failed("first failure"),
            .remoteChanges(
                recordCount: 2,
                deletionCount: 0,
                reason: .manual
            ),
            .failed("newest failure"),
            .accountChanged,
        ])
        for _ in 0..<100 {
            channel.yield([
                .remoteChanges(
                    recordCount: 1,
                    deletionCount: 1,
                    reason: .scheduled
                ),
                .uploadsAcknowledged(recordCount: 1),
            ])
        }

        let scheduled = await iterator.next()
        let upload = await iterator.next()
        let account = await iterator.next()
        let failure = await iterator.next()
        let manual = await iterator.next()
        XCTAssertEqual(
            scheduled,
            .remoteChanges(
                recordCount: 200,
                deletionCount: 200,
                reason: .scheduled
            )
        )
        XCTAssertEqual(
            upload,
            .uploadsAcknowledged(recordCount: 200)
        )
        XCTAssertEqual(account, .accountChanged)
        XCTAssertEqual(failure, .failed("newest failure"))
        XCTAssertEqual(
            manual,
            .remoteChanges(
                recordCount: 2,
                deletionCount: 0,
                reason: .manual
            )
        )
    }

    func testActivityChannelSaturatesCoalescedCounts() async {
        let channel = CloudKitSyncActivityChannel()
        channel.yield([
            .remoteChanges(
                recordCount: Int.max,
                deletionCount: Int.max,
                reason: .scheduled
            ),
            .remoteChanges(
                recordCount: 1,
                deletionCount: 1,
                reason: .scheduled
            ),
            .uploadsAcknowledged(recordCount: Int.max),
            .uploadsAcknowledged(recordCount: 1),
        ])
        var iterator = channel.stream.makeAsyncIterator()

        let remote = await iterator.next()
        let upload = await iterator.next()
        XCTAssertEqual(
            remote,
            .remoteChanges(
                recordCount: Int.max,
                deletionCount: Int.max,
                reason: .scheduled
            )
        )
        XCTAssertEqual(
            upload,
            .uploadsAcknowledged(recordCount: Int.max)
        )
    }

    func testActivityChannelOwnerDeinitFinishesWaitingStream() async throws {
        var channel: CloudKitSyncActivityChannel? =
            CloudKitSyncActivityChannel()
        let stream = try XCTUnwrap(channel).stream
        channel = nil
        var iterator = stream.makeAsyncIterator()

        let next = await iterator.next()
        XCTAssertNil(next)
    }

    func testActivityChannelCancellationFinishesWaitingStream() async {
        let channel = CloudKitSyncActivityChannel()
        let task = Task { () -> CloudKitSyncActivity? in
            var iterator = channel.stream.makeAsyncIterator()
            return await iterator.next()
        }
        await Task.yield()

        task.cancel()

        let next = await task.value
        XCTAssertNil(next)
    }

    func testFetchedCommitReportsOnlyNewDurableRecords() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = try SyncRecord(
            catalog: NotebookCatalogDocument().snapshot()
        )
        let store = try CloudKitTransportStateStore(
            directory: directory,
            accountRecordName: "account",
            zoneName: CloudKitTransportMode.notebook.zoneName,
            protocolVersion: 2
        )
        let committer = CloudKitEventCommitter(store: store)

        let first = try await committer.commitFetched([record])
        let duplicate = try await committer.commitFetched([record])

        XCTAssertEqual(first, CloudKitFetchedCommit(recordCount: 1))
        XCTAssertEqual(duplicate, CloudKitFetchedCommit())
        let reopened = try CloudKitTransportStateStore(
            directory: directory,
            accountRecordName: "account",
            zoneName: CloudKitTransportMode.notebook.zoneName,
            protocolVersion: 2
        )
        let reopenedState = await reopened.snapshot()
        XCTAssertEqual(reopenedState.inbox, [record])
    }

    func testRepeatedSendAcknowledgementProducesNoNewActivity() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let notebookID = UUID()
        let record = SyncRecord(
            snapshot: try NoteDocument(text: "sent").snapshot(),
            notebookID: notebookID
        )
        let store = try CloudKitTransportStateStore(
            directory: directory,
            accountRecordName: "account",
            zoneName: CloudKitTransportMode.notebook.zoneName,
            protocolVersion: 2
        )
        try await store.update { $0.outbox[record.id] = record }
        let committer = CloudKitEventCommitter(store: store)
        let acknowledgement = CloudKitAcknowledgedRecord(
            id: record.id,
            record: record
        )

        let first = try await committer.commitSent([acknowledgement])
        let duplicate = try await committer.commitSent([acknowledgement])

        XCTAssertEqual(first, 1)
        XCTAssertEqual(duplicate, 0)
    }

    func testFetchCompletionReconcilesDeletionAfterCatalogArrives()
        async throws
    {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let notebookID = UUID()
        let note = try NoteDocument(text: "removed")
        let catalog = try NotebookCatalogDocument(notebookID: notebookID)
        try catalog.add(id: note.noteID, kind: .note, name: "removed.md")
        let activeCatalog = SyncRecord(catalog: catalog.snapshot())
        let noteRecord = SyncRecord(
            snapshot: note.snapshot(),
            notebookID: notebookID
        )
        let deletedCatalog = try catalog.fork()
        try deletedCatalog.markPermanentlyDeleted([note.noteID])
        let marker = SyncRecord(catalog: deletedCatalog.snapshot())
        let store = try CloudKitTransportStateStore(
            directory: directory,
            accountRecordName: "account",
            zoneName: CloudKitTransportMode.notebook.zoneName,
            protocolVersion: 2
        )
        let committer = CloudKitEventCommitter(store: store)
        _ = try await committer.commitFetched([activeCatalog, noteRecord])

        let deletion = try await committer.commitFetched(
            [],
            deleting: [noteRecord.id],
            bootstrapRecordName: CloudKitTransportMode.notebook.bootstrapName
        )
        do {
            try await committer.finishFetch()
            XCTFail("Expected the deletion to await its catalog marker")
        } catch {
            XCTAssertEqual(
                error as? CloudKitSyncTransportError,
                .unexpectedDeletion
            )
        }

        let markerCommit = try await committer.commitFetched([marker])
        try await committer.finishFetch()

        XCTAssertEqual(
            deletion,
            CloudKitFetchedCommit(recordCount: 0, deletionCount: 1)
        )
        XCTAssertEqual(markerCommit, CloudKitFetchedCommit(recordCount: 1))
        let state = await store.snapshot()
        XCTAssertTrue(state.unresolvedRemoteDeletionRecordIDs.isEmpty)
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }
}
