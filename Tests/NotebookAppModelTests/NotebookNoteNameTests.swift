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
}
