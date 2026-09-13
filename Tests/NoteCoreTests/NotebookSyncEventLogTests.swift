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

    func testPersistsOnlyNewestFiveHundredEntriesAndClears() throws {
        let root = directory()
        let log = NotebookSyncEventLog(directory: root)
        for index in 0..<505 {
            log.record("event", counts: ["index": index])
        }

        XCTAssertEqual(log.entries.count, 500)
        XCTAssertEqual(log.entries.first?.counts["index"], 5)
        let reopened = NotebookSyncEventLog(directory: root)
        XCTAssertEqual(reopened.entries, log.entries)
        XCTAssertTrue(reopened.exportText.contains("index=504"))

        reopened.clear()
        XCTAssertTrue(reopened.entries.isEmpty)
        XCTAssertTrue(NotebookSyncEventLog(directory: root).entries.isEmpty)
    }

    func testCorruptOrUnwritableLogNeverThrowsAndReportsPersistenceError()
        throws
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

    private func directory() -> URL {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "NotebookSyncEventLogTests-\(UUID().uuidString)"
        )
        roots.append(root)
        return root
    }
}
