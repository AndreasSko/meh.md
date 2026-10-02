import Foundation
import XCTest

@testable import NoteCore

final class NotebookAttachmentTests: XCTestCase {
    func testContentRequiresCanonicalSHA256AndNonnegativeLength() throws {
        XCTAssertThrowsError(try NotebookAttachmentContent(sha256: "A" + String(repeating: "0", count: 63), byteCount: 1))
        XCTAssertThrowsError(try NotebookAttachmentContent(sha256: String(repeating: "g", count: 64), byteCount: 1))
        XCTAssertThrowsError(try NotebookAttachmentContent(sha256: String(repeating: "0", count: 63), byteCount: 1))
        XCTAssertThrowsError(try NotebookAttachmentContent(sha256: String(repeating: "0", count: 64), byteCount: -1))

        let empty = try NotebookAttachmentContent(
            sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            byteCount: 0
        )
        XCTAssertEqual(empty.byteCount, 0)
    }

    func testDecodingInvalidContentMetadataFails() throws {
        let json = #"{"sha256":"not-a-digest","byteCount":-3}"#
        XCTAssertThrowsError(try JSONDecoder().decode(
            NotebookAttachmentContent.self,
            from: Data(json.utf8)
        ))
    }
}
