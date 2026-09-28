import Darwin
import Foundation
import XCTest

@testable import NoteCore

final class DurableFileIOTests: XCTestCase {
    private enum CallbackFailure: Error, Equatable { case stopped }

    func testExistingFileRejectsBeforeCallbackWithoutChangingIt() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        let file = root.appending(path: "foreign.md")
        try Data("foreign".utf8).write(to: file)
        let originalDate = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: originalDate], ofItemAtPath: file.path
        )
        let originalAttributes = try FileManager.default.attributesOfItem(
            atPath: file.path
        )
        var callbackCalled = false

        XCTAssertThrowsError(
            try DurableFileIO.writeAndSync(Data("replacement".utf8), to: file) {
                callbackCalled = true
            }
        ) { error in
            let posix = error as NSError
            XCTAssertEqual(posix.domain, NSPOSIXErrorDomain)
            XCTAssertEqual(posix.code, Int(EEXIST))
        }
        XCTAssertFalse(callbackCalled)
        XCTAssertEqual(try Data(contentsOf: file), Data("foreign".utf8))
        let currentAttributes = try FileManager.default.attributesOfItem(
            atPath: file.path
        )
        XCTAssertEqual(
            currentAttributes[.modificationDate] as? Date,
            originalAttributes[.modificationDate] as? Date
        )
    }

    func testBeforeSyncFailurePropagates() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        let file = root.appending(path: "staged.md")
        var callbackCount = 0

        XCTAssertThrowsError(
            try DurableFileIO.writeAndSync(Data("staged".utf8), to: file) {
                callbackCount += 1
                throw CallbackFailure.stopped
            }
        ) { error in
            XCTAssertEqual(error as? CallbackFailure, .stopped)
        }
        XCTAssertEqual(callbackCount, 1)
        XCTAssertEqual(try Data(contentsOf: file), Data("staged".utf8))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "DurableFileIOTests-\(UUID().uuidString)"
        )
    }
}
