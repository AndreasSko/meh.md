import CloudKit
import Foundation
@testable import NoteCore
import XCTest

final class CloudKitTransportStateTests: XCTestCase {
    override func tearDown() {
        for url in temporaryDirectories { try? FileManager.default.removeItem(at: url) }
        temporaryDirectories = []
        super.tearDown()
    }

    private var temporaryDirectories: [URL] = []
    func testStatePersistsInboxAndAccountBinding() async throws {
        let directory = temporaryDirectory()
        let record = try makeRecord(text: "saved")
        let store = try CloudKitTransportStateStore(
            directory: directory, accountRecordName: "account-a",
            zoneName: "zone-a"
        )
        try await store.update { try $0.appendToInbox(record) }

        let reopened = try CloudKitTransportStateStore(
            directory: directory, accountRecordName: "account-a",
            zoneName: "zone-a"
        )
        let reopenedState = await reopened.snapshot()
        XCTAssertEqual(reopenedState.inbox, [record])
        XCTAssertThrowsError(
            try CloudKitTransportStateStore(
                directory: directory, accountRecordName: "account-b",
                zoneName: "zone-a"
            )
        ) { XCTAssertEqual($0 as? SyncError, .scopeChanged) }
    }

    func testStateCannotBeReusedForAnotherZone() async throws {
        let directory = temporaryDirectory()
        let store = try CloudKitTransportStateStore(
            directory: directory, accountRecordName: "account",
            zoneName: "ordinary-notes"
        )
        let record = try makeRecord(text: "ordinary note")
        try await store.update { try $0.appendToInbox(record) }
        XCTAssertThrowsError(
            try CloudKitTransportStateStore(
                directory: directory, accountRecordName: "account",
                zoneName: "smoke-test"
            )
        ) { XCTAssertEqual($0 as? SyncError, .scopeChanged) }
        let reopened = try CloudKitTransportStateStore(
            directory: directory, accountRecordName: "account",
            zoneName: "ordinary-notes"
        )
        let state = await reopened.snapshot()
        XCTAssertEqual(state.inbox, [record])
    }

    func testReplayIsPagedAndRejectsInvalidCursor() throws {
        var state = CloudKitTransportState(
            accountRecordName: "account", zoneName: "zone"
        )
        let records = try (0..<3).map { try makeRecord(text: "note \($0)") }
        for record in records { try state.appendToInbox(record) }
        let first = try state.page(after: nil, limit: 2)
        XCTAssertEqual(first.records, Array(records.prefix(2)))
        XCTAssertTrue(first.hasMore)
        XCTAssertEqual(
            try state.page(after: first.cursor, limit: 2).records,
            [records[2]]
        )
        XCTAssertThrowsError(try state.page(after: "bad", limit: 2))
    }

    func testBufferedReplayDefersCloudFetchUntilInboxIsDrained() throws {
        var state = CloudKitTransportState(
            accountRecordName: "account", zoneName: "zone"
        )
        let records = try (0..<3).map { try makeRecord(text: "note \($0)") }
        for record in records { try state.appendToInbox(record) }

        let first = try XCTUnwrap(state.bufferedPage(after: nil, limit: 2))
        XCTAssertEqual(first.records, Array(records.prefix(2)))
        XCTAssertTrue(first.hasMore)
        let second = try XCTUnwrap(
            state.bufferedPage(after: first.cursor, limit: 2)
        )
        XCTAssertEqual(second.records, [records[2]])
        XCTAssertTrue(second.hasMore)
        XCTAssertNil(try state.bufferedPage(after: second.cursor, limit: 2))
    }

    func testDuplicateInboxDeliveryIsIdempotent() throws {
        var state = CloudKitTransportState(
            accountRecordName: "account", zoneName: "zone"
        )
        let record = try makeRecord(text: "same")
        try state.appendToInbox(record)
        try state.appendToInbox(record)
        XCTAssertEqual(state.inbox, [record])
    }

    func testCleanupTombstonesInboxAndOutboxWithoutMovingCursor() throws {
        let notebookID = UUID()
        let deletedID = UUID()
        let retainedID = UUID()
        var state = CloudKitTransportState(
            accountRecordName: "account",
            zoneName: "meh-md-notebook-v2",
            protocolVersion: 2
        )
        let catalog = try makeCatalog(notebookID: notebookID)
        let deleted = try makeNotebookRecord(
            text: "deleted", noteID: deletedID, notebookID: notebookID
        )
        let retained = try makeNotebookRecord(
            text: "retained", noteID: retainedID, notebookID: notebookID
        )
        try state.appendToInbox(catalog)
        try state.appendToInbox(deleted)
        let catalogCursor = try state.page(after: nil, limit: 1).cursor
        try state.appendToInbox(retained)
        state.outbox[deleted.id] = deleted

        let pending = try state.purgeDeletedNotes(
            [deletedID], notebookID: notebookID
        )

        let tombstonePage = try state.page(
            after: catalogCursor, limit: 1
        )
        let retainedPage = try state.page(
            after: tombstonePage.cursor, limit: 1
        )
        XCTAssertTrue(tombstonePage.records.isEmpty)
        XCTAssertTrue(tombstonePage.hasMore)
        XCTAssertEqual(retainedPage.records, [retained])
        XCTAssertEqual(pending, [deleted.id])
        XCTAssertTrue(state.outbox.isEmpty)
        XCTAssertEqual(state.inbox, [catalog, retained])
    }

    func testCleanupStatePersistsAndLateBodyQueuesOneNewDeletion()
        async throws
    {
        let directory = temporaryDirectory()
        let notebookID = UUID()
        let noteID = UUID()
        let catalog = try makeCatalog(notebookID: notebookID)
        let original = try makeNotebookRecord(
            text: "original", noteID: noteID, notebookID: notebookID
        )
        let late = try makeNotebookRecord(
            text: "late", noteID: noteID, notebookID: notebookID
        )
        let store = try CloudKitTransportStateStore(
            directory: directory,
            accountRecordName: "account",
            zoneName: "meh-md-notebook-v2",
            protocolVersion: 2
        )
        try await store.update {
            try $0.appendToInbox(catalog)
            try $0.appendToInbox(original)
            _ = try $0.purgeDeletedNotes([noteID], notebookID: notebookID)
            $0.pendingRemoteDeletionIDs.remove(original.id)
            try $0.appendToInbox(original)
            XCTAssertEqual($0.pendingRemoteDeletionIDs, [original.id])
            $0.pendingRemoteDeletionIDs.remove(original.id)
            try $0.appendToInbox(late)
            try $0.appendToInbox(late)
        }

        let reopened = try CloudKitTransportStateStore(
            directory: directory,
            accountRecordName: "account",
            zoneName: "meh-md-notebook-v2",
            protocolVersion: 2
        )
        let state = await reopened.snapshot()
        XCTAssertEqual(state.inbox, [catalog])
        XCTAssertEqual(state.deletedNoteIDs, [noteID])
        XCTAssertEqual(state.pendingRemoteDeletionIDs, [late.id])
        XCTAssertEqual(state.purgedRecordIDs, [original.id, late.id])
    }

    func testKnownActiveNoteDeletionRemainsRetryableUntilResolved() throws {
        let notebookID = UUID()
        let noteID = UUID()
        var state = CloudKitTransportState(
            accountRecordName: "account",
            zoneName: "meh-md-notebook-v2",
            protocolVersion: 2
        )
        let catalog = try makeCatalog(notebookID: notebookID)
        let note = try makeNotebookRecord(
            text: "peer-purged", noteID: noteID,
            notebookID: notebookID
        )
        try state.appendToInbox(catalog)
        try state.appendToInbox(note)

        state.observeRemoteDeletions(
            [note.id, String(repeating: "f", count: 64)],
            bootstrapRecordName: "canonical-notebook-v2"
        )

        XCTAssertFalse(state.hasUnexpectedDeletion)
        XCTAssertEqual(
            state.unresolvedRemoteDeletionRecordIDs, [note.id]
        )
        try state.resolveRemoteNoteDeletions()
        XCTAssertThrowsError(try state.validateRemoteDeletions()) {
            XCTAssertEqual(
                $0 as? CloudKitSyncTransportError,
                .unexpectedDeletion
            )
        }
    }

    func testPermanentMarkerResolvesPeerDeletionInEitherOrder() throws {
        let notebookID = UUID()
        let noteID = UUID()
        let catalogs = try makeCatalogHistory(
            notebookID: notebookID, deletedNoteID: noteID
        )
        let note = try makeNotebookRecord(
            text: "peer-purged", noteID: noteID,
            notebookID: notebookID
        )
        var deletionFirst = CloudKitTransportState(
            accountRecordName: "account",
            zoneName: "meh-md-notebook-v2",
            protocolVersion: 2
        )
        try deletionFirst.appendToInbox(catalogs.active)
        try deletionFirst.appendToInbox(note)
        deletionFirst.observeRemoteDeletions(
            [note.id], bootstrapRecordName: "canonical-notebook-v2"
        )
        try deletionFirst.appendToInbox(catalogs.marked)
        try deletionFirst.resolveRemoteNoteDeletions()
        XCTAssertNoThrow(try deletionFirst.validateRemoteDeletions())

        var markerFirst = CloudKitTransportState(
            accountRecordName: "account",
            zoneName: "meh-md-notebook-v2",
            protocolVersion: 2
        )
        try markerFirst.appendToInbox(catalogs.active)
        try markerFirst.appendToInbox(note)
        try markerFirst.appendToInbox(catalogs.marked)
        markerFirst.observeRemoteDeletions(
            [note.id], bootstrapRecordName: "canonical-notebook-v2"
        )
        try markerFirst.resolveRemoteNoteDeletions()
        XCTAssertNoThrow(try markerFirst.validateRemoteDeletions())
    }

    func testExactReuploadResolvesKnownNoteDeletion() throws {
        let notebookID = UUID()
        let noteID = UUID()
        var state = CloudKitTransportState(
            accountRecordName: "account",
            zoneName: "meh-md-notebook-v2",
            protocolVersion: 2
        )
        let catalog = try makeCatalog(notebookID: notebookID)
        let note = try makeNotebookRecord(
            text: "recreated", noteID: noteID,
            notebookID: notebookID
        )
        try state.appendToInbox(catalog)
        try state.appendToInbox(note)
        state.observeRemoteDeletions(
            [note.id], bootstrapRecordName: "canonical-notebook-v2"
        )

        try state.appendToInbox(note)

        XCTAssertNoThrow(try state.validateRemoteDeletions())
    }

    func testUnresolvedKnownNoteDeletionPersistsAcrossRestart()
        async throws
    {
        let directory = temporaryDirectory()
        let notebookID = UUID()
        let noteID = UUID()
        let catalog = try makeCatalog(notebookID: notebookID)
        let note = try makeNotebookRecord(
            text: "missing", noteID: noteID,
            notebookID: notebookID
        )
        let store = try CloudKitTransportStateStore(
            directory: directory,
            accountRecordName: "account",
            zoneName: "meh-md-notebook-v2",
            protocolVersion: 2
        )
        try await store.update {
            try $0.appendToInbox(catalog)
            try $0.appendToInbox(note)
            $0.observeRemoteDeletions(
                [note.id],
                bootstrapRecordName: "canonical-notebook-v2"
            )
        }

        let reopened = try CloudKitTransportStateStore(
            directory: directory,
            accountRecordName: "account",
            zoneName: "meh-md-notebook-v2",
            protocolVersion: 2
        )
        let state = await reopened.snapshot()
        XCTAssertEqual(
            state.unresolvedRemoteDeletionRecordIDs, [note.id]
        )
        XCTAssertThrowsError(try state.validateRemoteDeletions())
    }

    func testCanonicalNotebookDeletionStillPoisonsTransport() throws {
        var state = CloudKitTransportState(
            accountRecordName: "account",
            zoneName: "meh-md-notebook-v2",
            protocolVersion: 2
        )
        state.observeRemoteDeletions(
            ["canonical-notebook-v2"],
            bootstrapRecordName: "canonical-notebook-v2"
        )
        XCTAssertTrue(state.hasUnexpectedDeletion)

        let notebookID = UUID()
        let catalog = try makeCatalog(notebookID: notebookID)
        var catalogState = CloudKitTransportState(
            accountRecordName: "account",
            zoneName: "meh-md-notebook-v2",
            protocolVersion: 2
        )
        try catalogState.appendToInbox(catalog)
        catalogState.observeRemoteDeletions(
            [catalog.id],
            bootstrapRecordName: "canonical-notebook-v2"
        )
        XCTAssertTrue(catalogState.hasUnexpectedDeletion)
    }

    func testRetryDeadlineAndPendingOutboxPersistTogether() async throws {
        let directory = temporaryDirectory()
        let record = try makeRecord(text: "pending")
        let deadline = Date().addingTimeInterval(30)
        let store = try CloudKitTransportStateStore(
            directory: directory, accountRecordName: "account",
            zoneName: "zone"
        )
        try await store.update {
            $0.outbox[record.id] = record
            $0.retryNotBefore = deadline
        }

        let reopened = try CloudKitTransportStateStore(
            directory: directory, accountRecordName: "account",
            zoneName: "zone"
        )
        let state = await reopened.snapshot()
        XCTAssertEqual(state.outbox, [record.id: record])
        XCTAssertEqual(state.retryNotBefore, deadline)
    }

    func testRetryThrottleKeepsLongestActiveCooldown() {
        let now = Date(timeIntervalSince1970: 1_000)
        var throttle = CloudKitRetryThrottle()
        XCTAssertTrue(throttle.observe(retryAfter: 10, now: now))
        XCTAssertFalse(throttle.observe(retryAfter: 2, now: now))
        XCTAssertEqual(throttle.remaining(at: now), 10)
        XCTAssertNil(throttle.remaining(at: now.addingTimeInterval(10)))
    }

    func testRetryMetadataIncludesNestedPerItemErrors() {
        let child = NSError(
            domain: CKErrorDomain,
            code: CKError.requestRateLimited.rawValue,
            userInfo: [CKErrorRetryAfterKey: 12.0]
        )
        let parent = NSError(
            domain: CKErrorDomain,
            code: CKError.partialFailure.rawValue,
            userInfo: [CKPartialErrorsByItemIDKey: ["record": child]]
        )

        XCTAssertEqual(CloudKitRetryMetadata.seconds(in: parent), 12)
    }

    func testRetryMetadataFallsBackForThrottleWithoutValidDelay() {
        for value: Any? in [nil, -1.0, Double.nan] {
            var userInfo: [String: Any] = [:]
            if let value { userInfo[CKErrorRetryAfterKey] = value }
            let error = NSError(
                domain: CKErrorDomain,
                code: CKError.serviceUnavailable.rawValue,
                userInfo: userInfo
            )
            XCTAssertEqual(
                CloudKitRetryMetadata.seconds(in: error),
                CloudKitRetryMetadata.fallbackSeconds
            )
        }
    }

    func testStartupCooldownGatesRequestsAndPersistsWithoutIdentity() async throws {
        let directory = temporaryDirectory()
        let start = Date(timeIntervalSince1970: 1_000)
        var store = try CloudKitAvailabilityCooldownStore(directory: directory)
        try store.merge(retryAfter: 10, now: start)
        var now = start
        var requestCount = 0
        var sleepCount = 0

        try await store.wait(
            now: { now },
            sleep: { interval in
                XCTAssertEqual(requestCount, 0)
                sleepCount += 1
                now.addTimeInterval(interval)
            }
        )
        requestCount += 1

        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(sleepCount, 1)
        let reopened = try CloudKitAvailabilityCooldownStore(
            directory: directory
        )
        XCTAssertEqual(reopened.notBefore, start.addingTimeInterval(10))
        let persisted = try String(
            contentsOf: directory.appendingPathComponent(
                "cloudkit-availability-retry.json"
            ),
            encoding: .utf8
        )
        XCTAssertFalse(persisted.contains("account"))
        XCTAssertFalse(persisted.contains("zone"))
    }

    func testTransportReadsPersistedStartupRetryDeadline() throws {
        let directory = temporaryDirectory()
        let deadline = Date(timeIntervalSince1970: 2_000)
        var store = try CloudKitAvailabilityCooldownStore(
            directory: directory
        )
        try store.merge(notBefore: deadline)

        let persisted = try CloudKitSyncTransport.persistedRetryNotBefore(
            stateDirectory: directory
        )

        XCTAssertEqual(persisted, deadline)
    }

    func testRebuiltInboxRejectsCursorFromPreviousGeneration() throws {
        let record = try makeRecord(text: "same-length rebuilt inbox")
        var old = CloudKitTransportState(
            accountRecordName: "account", zoneName: "zone"
        )
        try old.appendToInbox(record)
        let cursor = try old.page(after: nil, limit: 10).cursor
        var rebuilt = CloudKitTransportState(
            accountRecordName: "account", zoneName: "zone"
        )
        try rebuilt.appendToInbox(record)
        XCTAssertThrowsError(try rebuilt.page(after: cursor, limit: 10)) {
            XCTAssertEqual($0 as? SyncError, .invalidCursor)
        }
    }

    func testCorruptPersistedStateIsRejected() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(
            to: directory.appendingPathComponent("cloudkit-sync-state.json")
        )
        XCTAssertThrowsError(
            try CloudKitTransportStateStore(
                directory: directory, accountRecordName: "account",
                zoneName: "zone"
            )
        ) {
            XCTAssertEqual(
                $0 as? CloudKitSyncTransportError,
                .corruptState
            )
        }
    }

    func testRemoteSnapshotIDRejectsPathsAndUppercase() {
        XCTAssertThrowsError(
            try CloudKitRemoteRecordValidator.validateSnapshotID("../note")
        )
        XCTAssertThrowsError(
            try CloudKitRemoteRecordValidator.validateSnapshotID(
                String(repeating: "A", count: 64)
            )
        )
        XCTAssertNoThrow(
            try CloudKitRemoteRecordValidator.validateSnapshotID(
                String(repeating: "a", count: 64)
            )
        )
    }

    func testInboxFailurePreventsLaterEngineStateAdvance() async throws {
        let directory = temporaryDirectory()
        let store = try CloudKitTransportStateStore(
            directory: directory, accountRecordName: "account",
            zoneName: "zone"
        )
        let committer = CloudKitEventCommitter(store: store)
        try FileManager.default.removeItem(at: directory)
        try Data().write(to: directory)

        do {
            try await committer.commitFetched([try makeRecord(text: "remote")])
            XCTFail("Expected the inbox commit to fail")
        } catch {}
        do {
            try await committer.commitEngineState(Data("advanced".utf8))
            XCTFail("Expected the poisoned committer to reject state")
        } catch {}
        let finalState = await store.snapshot()
        XCTAssertNil(finalState.engineState)
    }

    func testSentBatchCommitsAllAcknowledgementsTogether() async throws {
        let directory = temporaryDirectory()
        let records = try [
            makeRecord(text: "first acknowledged"),
            makeRecord(text: "second acknowledged"),
        ]
        let store = try CloudKitTransportStateStore(
            directory: directory,
            accountRecordName: "account",
            zoneName: "zone"
        )
        try await store.update { state in
            for record in records { state.outbox[record.id] = record }
        }
        let committer = CloudKitEventCommitter(store: store)

        try await committer.commitSent(records.map {
            CloudKitAcknowledgedRecord(id: $0.id, record: $0)
        })

        let state = await store.snapshot()
        XCTAssertTrue(state.outbox.isEmpty)
        XCTAssertEqual(Set(state.inbox.map(\.id)), Set(records.map(\.id)))
    }

    func testLateSentAcknowledgementRequeuesPurgedSnapshot() async throws {
        let directory = temporaryDirectory()
        let notebookID = UUID()
        let noteID = UUID()
        let catalog = try makeCatalog(notebookID: notebookID)
        let note = try makeNotebookRecord(
            text: "late sent", noteID: noteID,
            notebookID: notebookID
        )
        let store = try CloudKitTransportStateStore(
            directory: directory,
            accountRecordName: "account",
            zoneName: "meh-md-notebook-v2",
            protocolVersion: 2
        )
        try await store.update {
            try $0.appendToInbox(catalog)
            try $0.appendToInbox(note)
            _ = try $0.purgeDeletedNotes([noteID], notebookID: notebookID)
            $0.pendingRemoteDeletionIDs.removeAll()
        }
        let committer = CloudKitEventCommitter(store: store)

        try await committer.commitSent([
            CloudKitAcknowledgedRecord(id: note.id, record: note)
        ])

        let state = await store.snapshot()
        XCTAssertEqual(state.inbox, [catalog])
        XCTAssertEqual(state.pendingRemoteDeletionIDs, [note.id])
    }

    func testAssetIsRemovedOnlyAfterCompletedUploadAndLastUser() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        var staging = CloudKitAssetStaging(directory: directory)
        let record = try makeRecord(text: "asset")
        let first = try staging.retain(record)
        let second = try staging.retain(record)

        staging.release(first, uploadCompleted: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        staging.release(second, uploadCompleted: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
    }

    func testAssetIsPreservedForRetryAfterFailedUpload() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        var staging = CloudKitAssetStaging(directory: directory)
        let record = try makeRecord(text: "retry")
        let url = try staging.retain(record)

        staging.release(url, uploadCompleted: false)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let retryURL = try staging.retain(record)
        staging.release(retryURL, uploadCompleted: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testBatchStagesIndependentAssetsAndKeepsOnlyFailedUpload() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        var staging = CloudKitAssetStaging(directory: directory)
        let sent = try makeRecord(text: "sent")
        let failed = try makeRecord(text: "failed")
        let sentURL = try staging.retain(sent)
        let failedURL = try staging.retain(failed)

        staging.release(sentURL, uploadCompleted: true)
        staging.release(failedURL, uploadCompleted: false)

        XCTAssertFalse(FileManager.default.fileExists(atPath: sentURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: failedURL.path))
    }

    func testBatchScopeAndPartialFailurePreserveAcknowledgements() throws {
        let zoneID = CKRecordZone.ID(zoneName: "zone")
        let records = try [
            makeRecord(text: "first"),
            makeRecord(text: "second"),
        ]
        let batch = CloudKitUploadBatch(records: records, zoneID: zoneID)
        XCTAssertEqual(Set(batch.recordIDs.map(\.recordName)), batch.ids)
        XCTAssertTrue(batch.recordIDs.allSatisfy { $0.zoneID == zoneID })

        let failure = NSError(domain: "batch-test", code: 7)
        let result = CloudKitBatchResultResolver.resolve(
            records: records,
            acknowledgedIDs: [records[0].id],
            failures: [records[1].id: failure],
            delegateFailure: nil,
            sendError: nil
        )
        XCTAssertEqual(result.acknowledgedIDs, [records[0].id])
        XCTAssertEqual((result.error as NSError?)?.domain, "batch-test")
        XCTAssertEqual((result.error as NSError?)?.code, 7)
    }

    func testUnacknowledgedBatchWithoutExplicitErrorStillFails() throws {
        let records = try [makeRecord(text: "unconfirmed")]
        let result = CloudKitBatchResultResolver.resolve(
            records: records,
            acknowledgedIDs: [],
            failures: [:],
            delegateFailure: nil,
            sendError: nil
        )
        XCTAssertEqual(
            result.error as? CloudKitSyncTransportError,
            .uploadNotAcknowledged
        )
    }

    func testBatchPartialFailureKeepsTransientChildRetryable() throws {
        let records = try [
            makeRecord(text: "acknowledged"),
            makeRecord(text: "retry"),
        ]
        let recordID = CKRecord.ID(
            recordName: records[1].id,
            zoneID: CKRecordZone.ID(zoneName: "zone")
        )
        let error = partialFailure([
            recordID: cloudError(.networkFailure),
        ])
        let result = CloudKitBatchResultResolver.resolve(
            records: records,
            acknowledgedIDs: [records[0].id],
            failures: [:],
            delegateFailure: nil,
            sendError: error
        )

        XCTAssertEqual(result.acknowledgedIDs, [records[0].id])
        XCTAssertEqual(
            result.error as? CloudKitSyncTransportError,
            .uploadFailed(code: CKError.networkFailure.rawValue)
        )
        XCTAssertTrue(NotebookSyncRetryPolicy.isTransient(result.error!))
    }

    func testBatchPartialFailurePrefersPermanentChild() throws {
        let records = try [
            makeRecord(text: "acknowledged"),
            makeRecord(text: "retry"),
            makeRecord(text: "stop"),
        ]
        let error = partialFailure([
            records[1].id: cloudError(.requestRateLimited),
            records[2].id: cloudError(.permissionFailure),
        ])
        let result = CloudKitBatchResultResolver.resolve(
            records: records,
            acknowledgedIDs: [records[0].id],
            failures: [:],
            delegateFailure: nil,
            sendError: error
        )

        XCTAssertEqual(result.acknowledgedIDs, [records[0].id])
        XCTAssertEqual(
            result.error as? CloudKitSyncTransportError,
            .uploadFailed(code: CKError.permissionFailure.rawValue)
        )
        XCTAssertFalse(NotebookSyncRetryPolicy.isTransient(result.error!))
    }

    func testBatchCombinesRecordedAndRawPartialFailures() throws {
        let records = try [
            makeRecord(text: "recorded retry"),
            makeRecord(text: "raw stop"),
        ]
        let result = CloudKitBatchResultResolver.resolve(
            records: records,
            acknowledgedIDs: [],
            failures: [
                records[0].id: partialFailure([
                    "retry": cloudError(.networkFailure),
                ]),
            ],
            delegateFailure: nil,
            sendError: partialFailure([
                records[1].id: cloudError(.permissionFailure),
            ])
        )

        XCTAssertEqual(
            result.error as? CloudKitSyncTransportError,
            .uploadFailed(code: CKError.permissionFailure.rawValue)
        )
        XCTAssertFalse(NotebookSyncRetryPolicy.isTransient(result.error!))
    }

    func testBatchEmptyPartialFailureDoesNotRetryForever() throws {
        let records = try [makeRecord(text: "unacknowledged")]
        let result = CloudKitBatchResultResolver.resolve(
            records: records,
            acknowledgedIDs: [],
            failures: [:],
            delegateFailure: nil,
            sendError: partialFailure([:])
        )

        XCTAssertEqual(
            result.error as? CloudKitSyncTransportError,
            .uploadFailed(code: CKError.partialFailure.rawValue)
        )
        XCTAssertFalse(NotebookSyncRetryPolicy.isTransient(result.error!))
    }

    func testBatchConfirmedAcknowledgementIgnoresRawPartialFailure() throws {
        let records = try [makeRecord(text: "acknowledged")]
        let result = CloudKitBatchResultResolver.resolve(
            records: records,
            acknowledgedIDs: [records[0].id],
            failures: [:],
            delegateFailure: nil,
            sendError: partialFailure([
                records[0].id: cloudError(.networkFailure),
            ])
        )

        XCTAssertEqual(result.acknowledgedIDs, [records[0].id])
        XCTAssertNil(result.error)
    }

    func testBatchNestedPartialFailureUsesLeafPolicy() throws {
        let records = try [makeRecord(text: "nested")]
        let nested = partialFailure([
            records[0].id: cloudError(.zoneBusy),
        ])
        let zoneID = CKRecordZone.ID(zoneName: "zone")
        let result = CloudKitBatchResultResolver.resolve(
            records: records,
            acknowledgedIDs: [],
            failures: [:],
            delegateFailure: nil,
            sendError: partialFailure([zoneID: nested])
        )

        XCTAssertEqual(
            result.error as? CloudKitSyncTransportError,
            .uploadFailed(code: CKError.zoneBusy.rawValue)
        )
        XCTAssertTrue(NotebookSyncRetryPolicy.isTransient(result.error!))
    }

    func testBatchDeepPartialFailureStopsAtBound() throws {
        let records = try [makeRecord(text: "deep")]
        var nested: Error = cloudError(.networkFailure)
        for level in 0..<10 {
            nested = partialFailure(["level-\(level)": nested])
        }
        let result = CloudKitBatchResultResolver.resolve(
            records: records,
            acknowledgedIDs: [],
            failures: [:],
            delegateFailure: nil,
            sendError: partialFailure([records[0].id: nested])
        )

        XCTAssertEqual(
            result.error as? CloudKitSyncTransportError,
            .uploadFailed(code: CKError.partialFailure.rawValue)
        )
        XCTAssertFalse(NotebookSyncRetryPolicy.isTransient(result.error!))
    }

    private func cloudError(_ code: CKError.Code) -> NSError {
        NSError(domain: CKErrorDomain, code: code.rawValue)
    }

    private func partialFailure(
        _ itemErrors: [AnyHashable: Error]
    ) -> NSError {
        NSError(
            domain: CKErrorDomain,
            code: CKError.partialFailure.rawValue,
            userInfo: [CKPartialErrorsByItemIDKey: itemErrors]
        )
    }

    private func makeRecord(text: String) throws -> SyncRecord {
        let document = try NoteDocument(noteID: UUID())
        try document.replaceAll(with: text)
        return SyncRecord(snapshot: document.snapshot())
    }

    private func makeCatalog(notebookID: UUID) throws -> SyncRecord {
        SyncRecord(
            catalog: try NotebookCatalogDocument(
                notebookID: notebookID
            ).snapshot()
        )
    }

    private func makeCatalogHistory(
        notebookID: UUID, deletedNoteID: UUID
    ) throws -> (active: SyncRecord, marked: SyncRecord) {
        let catalog = try NotebookCatalogDocument(notebookID: notebookID)
        try catalog.add(
            id: deletedNoteID, kind: .note, name: "Deleted.md"
        )
        let active = SyncRecord(catalog: catalog.snapshot())
        try catalog.markPermanentlyDeleted([deletedNoteID])
        return (active, SyncRecord(catalog: catalog.snapshot()))
    }

    private func makeNotebookRecord(
        text: String, noteID: UUID, notebookID: UUID
    ) throws -> SyncRecord {
        let document = try NoteDocument(noteID: noteID)
        try document.replaceAll(with: text)
        return SyncRecord(
            snapshot: document.snapshot(), notebookID: notebookID
        )
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CloudKitTransportTests-\(UUID().uuidString)"
        )
        temporaryDirectories.append(url)
        return url
    }
}
