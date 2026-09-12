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
            directory: directory, accountRecordName: "account-a"
        )
        try await store.update { try $0.appendToInbox(record) }

        let reopened = try CloudKitTransportStateStore(
            directory: directory, accountRecordName: "account-a"
        )
        let reopenedState = await reopened.snapshot()
        XCTAssertEqual(reopenedState.inbox, [record])
        XCTAssertThrowsError(
            try CloudKitTransportStateStore(
                directory: directory, accountRecordName: "account-b"
            )
        ) { XCTAssertEqual($0 as? SyncError, .scopeChanged) }
    }

    func testReplayIsPagedAndRejectsInvalidCursor() throws {
        var state = CloudKitTransportState(accountRecordName: "account")
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

    func testDuplicateInboxDeliveryIsIdempotent() throws {
        var state = CloudKitTransportState(accountRecordName: "account")
        let record = try makeRecord(text: "same")
        try state.appendToInbox(record)
        try state.appendToInbox(record)
        XCTAssertEqual(state.inbox, [record])
    }

    func testRebuiltInboxRejectsCursorFromPreviousGeneration() throws {
        let record = try makeRecord(text: "same-length rebuilt inbox")
        var old = CloudKitTransportState(accountRecordName: "account")
        try old.appendToInbox(record)
        let cursor = try old.page(after: nil, limit: 10).cursor
        var rebuilt = CloudKitTransportState(accountRecordName: "account")
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
                directory: directory, accountRecordName: "account"
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
            directory: directory, accountRecordName: "account"
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
