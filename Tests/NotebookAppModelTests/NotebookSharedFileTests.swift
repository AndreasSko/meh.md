import Foundation
import XCTest

@testable import NotebookAppModel

final class NotebookSharedFileTests: XCTestCase {
    func testSharingKeepsExactMarkdownAndIndependentCopies() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = "# Café 👋\r\n\r\n- Item\r\n  > **Quote**\r\n\r\n- [x] Done\r\n"
        let first = try NotebookSharedFile.markdown(
            text: text, filename: "Café.MARKDOWN", temporaryDirectory: root
        )
        let second = try NotebookSharedFile.markdown(
            text: "Later edits", filename: "Café.MARKDOWN", temporaryDirectory: root
        )
        XCTAssertEqual(first.url.lastPathComponent, "Café.MARKDOWN")
        XCTAssertNotEqual(first.url, second.url)
        XCTAssertEqual(try Data(contentsOf: first.url), Data(text.utf8))
        XCTAssertEqual(try Data(contentsOf: second.url), Data("Later edits".utf8))
    }

    func testAddsMarkdownExtensionAndRejectsPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try NotebookSharedFile.markdown(
            text: "", filename: "Trip notes", temporaryDirectory: root
        )
        XCTAssertEqual(file.url.lastPathComponent, "Trip notes.md")
        XCTAssertEqual(try Data(contentsOf: file.url), Data())
        for name in ["../escape.md", "folder/note.md", "folder\\note.md"] {
            XCTAssertThrowsError(try NotebookSharedFile.markdown(
                text: "secret", filename: name, temporaryDirectory: root
            ))
        }
    }
}
