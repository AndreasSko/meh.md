import Foundation
import XCTest

@testable import NoteCore

@MainActor
final class NotebookSyncEventLogTests: XCTestCase {
    nonisolated(unsafe) private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }

    func testPersistsOnlyNewestFiveHundredEntriesAndClears() async throws {
        let root = directory()
        let log = NotebookSyncEventLog(directory: root)
        for index in 0..<505 {
            log.record("event", counts: ["index": index])
        }

        XCTAssertEqual(log.entries.count, 500)
        XCTAssertEqual(log.entries.first?.counts["index"], 5)
        await log.flush()
        let reopened = NotebookSyncEventLog(directory: root)
        XCTAssertEqual(reopened.entries, log.entries)
        XCTAssertTrue(reopened.exportText.contains("index=504"))

        reopened.clear()
        await reopened.flush()
        XCTAssertTrue(reopened.entries.isEmpty)
        XCTAssertTrue(NotebookSyncEventLog(directory: root).entries.isEmpty)
    }

    func testBurstWritesAreCoalescedAndFlushPersistsLatestSnapshot() async {
        let root = directory()
        let writeCount = LockedCounter()
        let log = NotebookSyncEventLog(directory: root) { data, url in
            writeCount.increment()
            try SyncFileIO.replace(data, at: url)
        }
        for index in 0..<505 {
            log.record("event", counts: ["index": index])
        }

        await log.flush()

        XCTAssertEqual(writeCount.value, 1)
        let reopened = NotebookSyncEventLog(directory: root)
        XCTAssertEqual(reopened.entries.count, 500)
        XCTAssertEqual(reopened.entries.first?.counts["index"], 5)
        XCTAssertEqual(reopened.entries.last?.counts["index"], 504)
    }

    func testClearDuringQueuedWriteCannotBeUndoneByOldSnapshot() async {
        let root = directory()
        let started = expectation(description: "first write started")
        let release = DispatchSemaphore(value: 0)
        let firstWrite = LockedCounter()
        let log = NotebookSyncEventLog(directory: root) { data, url in
            if firstWrite.incrementAndGet() == 1 {
                started.fulfill()
                release.wait()
            }
            try SyncFileIO.replace(data, at: url)
        }
        log.record("old")
        let firstFlush = Task { await log.flush() }
        await fulfillment(of: [started], timeout: 5)

        log.clear()
        let clearFlush = Task { await log.flush() }
        release.signal()
        await firstFlush.value
        await clearFlush.value

        XCTAssertTrue(NotebookSyncEventLog(directory: root).entries.isEmpty)
    }

    func testCorruptOrUnwritableLogNeverThrowsAndReportsPersistenceError()
        async throws
    {
        let corruptRoot = directory()
        try FileManager.default.createDirectory(
            at: corruptRoot,
            withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(
            to: corruptRoot.appending(path: "notebook-sync-events.json")
        )
        let corrupt = NotebookSyncEventLog(directory: corruptRoot)
        XCTAssertTrue(corrupt.entries.isEmpty)
        XCTAssertTrue(corrupt.persistenceError)
        corrupt.record("pass_start")
        XCTAssertEqual(corrupt.entries.count, 1)

        let blockedRoot = directory()
        try Data("file".utf8).write(to: blockedRoot)
        let blocked = NotebookSyncEventLog(directory: blockedRoot)
        blocked.record("pass_start")
        XCTAssertEqual(blocked.entries.count, 1)
        await blocked.flush()
        XCTAssertTrue(blocked.persistenceError)
    }

    func testErrorCodesDoNotExposeMessagesPathsOrIdentifiers() {
        let secret = "/private/user/secret-note.md"
        let identifier = UUID()
        let codes = [
            NotebookSyncEventLog.errorCode(SyncError.unavailable(secret)),
            NotebookSyncEventLog.errorCode(
                NotebookReplicaError.noteUnavailable(identifier)
            ),
            NotebookSyncEventLog.errorCode(
                NSError(domain: secret, code: 47)
            ),
        ]

        XCTAssertEqual(codes[0], "SyncError.unavailable")
        XCTAssertEqual(codes[1], "NotebookReplicaError.noteUnavailable")
        XCTAssertEqual(codes[2], "NSError.47")
        XCTAssertFalse(codes.joined().contains(secret))
        XCTAssertFalse(codes.joined().contains(identifier.uuidString))
    }

    func testStorageFailureKeepsDiagnosticCauseWithoutFilePaths() {
        let secret = "/private/user/secret-note.md"
        let error = CloudKitStateWriteFailure(underlyingError: NSError(
            domain: NSPOSIXErrorDomain, code: Int(ENOSPC),
            userInfo: [NSFilePathErrorKey: secret]
        ))
        let code = NotebookSyncEventLog.errorCode(error)
        XCTAssertTrue(code.hasPrefix("CloudKitStateWriteFailure."))
        XCTAssertTrue(code.hasSuffix(".\(ENOSPC)"))
        XCTAssertFalse(code.contains(secret))
    }

    private func directory() -> URL {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "NotebookSyncEventLogTests-\(UUID().uuidString)"
        )
        roots.append(root)
        return root
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() { _ = incrementAndGet() }

    func incrementAndGet() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}
