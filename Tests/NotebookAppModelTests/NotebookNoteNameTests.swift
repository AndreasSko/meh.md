import Foundation
import XCTest

@testable import NotebookAppModel

final class NotebookNoteNameTests: XCTestCase {
    func testTitleHidesOnlyMarkdownExtensions() {
        XCTAssertEqual(NotebookNoteName.title(from: "Long title.md"), "Long title")
        XCTAssertEqual(NotebookNoteName.title(from: "Draft.MARKDOWN"), "Draft")
        XCTAssertEqual(NotebookNoteName.title(from: "Reference.txt"), "Reference.txt")
    }

    func testExtensionOnlyLegacyNamesRemainVisibleAndUnchanged() {
        for filename in [".md", ".MARKDOWN"] {
            XCTAssertEqual(NotebookNoteName.title(from: filename), filename)
            XCTAssertEqual(
                NotebookNoteName.filename(for: filename, preservingExtensionFrom: filename),
                filename
            )
        }
    }

    func testRenamePreservesOriginalMarkdownExtension() {
        XCTAssertEqual(
            NotebookNoteName.filename(
                for: "New title", preservingExtensionFrom: "Old.MARKDOWN"
            ),
            "New title.MARKDOWN"
        )
        XCTAssertEqual(
            NotebookNoteName.filename(
                for: "New title.md", preservingExtensionFrom: "Old.markdown"
            ),
            "New title.markdown"
        )
    }

    func testUntouchedTitleKeepsANameWithoutMarkdownExtension() {
        for filename in ["Hi •_•", "Reference.txt", "Note.md"] {
            XCTAssertEqual(
                NotebookNoteName.filename(
                    for: NotebookNoteName.title(from: filename),
                    preservingExtensionFrom: filename
                ),
                filename
            )
        }
        XCTAssertEqual(
            NotebookNoteName.filename(for: "Hello", preservingExtensionFrom: "Hi •_•"),
            "Hello.md"
        )
        XCTAssertEqual(
            NotebookNoteName.filename(
                for: "Reference.txt.md", preservingExtensionFrom: "Reference.txt"),
            "Reference.txt.md"
        )
    }

    func testRenameDoesNotTurnAnEmptyTitleIntoAnExtension() {
        XCTAssertEqual(
            NotebookNoteName.filename(for: "", preservingExtensionFrom: "Old.md"),
            ""
        )
        XCTAssertEqual(
            NotebookNoteName.filename(for: ".md", preservingExtensionFrom: "Old.md"),
            ""
        )
        XCTAssertEqual(
            NotebookNoteName.filename(for: "   ", preservingExtensionFrom: "Old.md"),
            "   "
        )
        XCTAssertEqual(
            NotebookNoteName.filename(for: "..", preservingExtensionFrom: "Old.md"),
            ".."
        )
    }

    func testDefaultFilenameUsesDateAndNextAvailableSuffix() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(
            from: DateComponents(year: 2026, month: 9, day: 14)
        )!
        XCTAssertEqual(
            NotebookNoteName.defaultFilename(
                on: date,
                existingNames: ["2026-09-14.md", "2026-09-14 2.MD"],
                calendar: calendar
            ),
            "2026-09-14 3.md"
        )
    }

    func testRestoredFilenameUsesCatalogCollisionRules() {
        XCTAssertEqual(
            NotebookNoteName.restoredFilename(
                for: "Café",
                existingNames: [
                    "Cafe\u{301} (Restored).md",
                    "CAFÉ (RESTORED) 2.MD"
                ]
            ),
            "Café (Restored) 3.md"
        )
    }
}
