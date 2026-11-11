import Foundation
import XCTest

@testable import NativeEditor

@MainActor
final class MissingNoteLinkTests: XCTestCase {
    override func tearDown() {
        MarkdownPresentation.knownLinkNames = nil
        super.tearDown()
    }

    private func isMissing(_ link: String) -> Bool {
        let source = link as NSString
        return MarkdownPresentation.isMissingNoteLink(
            NSRange(location: 0, length: source.length), in: source
        )
    }

    func testMarksOnlyWikiLinksToUnknownNotes() {
        MarkdownPresentation.knownLinkNames = [
            MarkdownPresentation.linkName("Lisbon in May.md"),
        ]
        XCTAssertFalse(isMissing("[[Lisbon in May]]"))
        XCTAssertFalse(isMissing("[[projects/lisbon in may#To do|trip]]"))
        XCTAssertFalse(isMissing("[[#To do]]"))
        XCTAssertTrue(isMissing("[[Garden plan]]"))
        XCTAssertFalse(isMissing("[Garden](Garden.md)"), "Only wiki links are checked")
        XCTAssertFalse(isMissing("[[Garden pl"), "Unfinished links stay as they are")
    }

    func testUnknownNamesLeaveEveryLinkAlike() {
        MarkdownPresentation.knownLinkNames = nil
        XCTAssertFalse(isMissing("[[Garden plan]]"))
    }
}
