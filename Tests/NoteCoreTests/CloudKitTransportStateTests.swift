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

    private func makeRecord(text: String) throws -> SyncRecord {
        let document = try NoteDocument(noteID: UUID())
        try document.replaceAll(with: text)
        return SyncRecord(snapshot: document.snapshot())
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CloudKitTransportTests-\(UUID().uuidString)"
        )
        temporaryDirectories.append(url)
        return url
    }
}
