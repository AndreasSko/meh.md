import Foundation
import XCTest

@testable import NoteCore

/// The update rules for integration notes, from docs/readwise-sync.md.
final class NoteIntegrationTests: XCTestCase {
    private let link = NotebookIntegrationLink(connection: UUID(), item: "book-1")
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    func testANewNoteShowsTheHeaderAndEachHighlightSeparatedByABlankLine() throws {
        let note = try created(["# Book", "> one", "> two"])
        XCTAssertEqual(try note.text, "# Book\n\n> one\n\n> two")
        XCTAssertEqual(note.integrationLink, link)
    }

    func testTheSameBlocksAgainChangeNothing() throws {
        let note = try created(["# Book", "> one"])
        let heads = note.heads
        XCTAssertFalse(try note.applyIntegration(blocks(["# Book", "> one"]), link: link, at: date))
        XCTAssertEqual(note.heads, heads)
    }

    func testAChangedHighlightIsReplacedAndTextAroundItStays() throws {
        let note = try created(["# Book", "> one", "> two"])
        try insert(note, "## Mine\n\n", before: "> two")
        try note.applyIntegration(blocks(["# Book", "> one changed", "> two"]), link: link, at: date)
        XCTAssertEqual(try note.text, "# Book\n\n> one changed\n\n## Mine\n\n> two")
    }

    func testAnEditInsideAnUnchangedHighlightStays() throws {
        let note = try created(["# Book", "> one", "> two"])
        try insert(note, "-really-", after: "> o")
        try note.applyIntegration(blocks(["# Book", "> one", "> two changed"]), link: link, at: date)
        XCTAssertEqual(try note.text, "# Book\n\n> o-really-ne\n\n> two changed")
    }

    func testAnEditInsideAChangedHighlightIsReplaced() throws {
        let note = try created(["# Book", "> one", "> two"])
        try insert(note, "-really-", after: "> o")
        try note.applyIntegration(blocks(["# Book", "> one changed", "> two"]), link: link, at: date)
        XCTAssertEqual(try note.text, "# Book\n\n> one changed\n\n> two")
    }

    func testTextTypedAtTheVeryStartOrEndOfAHighlightStays() throws {
        let note = try created(["# Book", "> one", "> two"])
        try insert(note, " after", after: "> one")
        try insert(note, "Before ", before: "> one")
        try note.applyIntegration(blocks(["# Book", "> ONE", "> two"]), link: link, at: date)
        XCTAssertEqual(try note.text, "# Book\n\nBefore \n\n> ONE after\n\n> two")
    }

    func testADeletedHighlightStaysDeletedUntilItChanges() throws {
        let note = try created(["# Book", "> one", "> two", "> three"])
        try delete(note, "\n\n> two")
        XCTAssertFalse(try note.applyIntegration(
            blocks(["# Book", "> one", "> two", "> three"]), link: link, at: date))
        XCTAssertEqual(try note.text, "# Book\n\n> one\n\n> three")

        try note.applyIntegration(
            blocks(["# Book", "> one", "> two changed", "> three"]), link: link, at: date)
        XCTAssertEqual(try note.text, "# Book\n\n> one\n\n> two changed\n\n> three")
    }

    func testANewHighlightGoesDirectlyAfterTheOneBeforeIt() throws {
        let note = try created(["# Book", "> one", "> three"])
        try insert(note, "Mine\n\n", before: "> three")
        try note.applyIntegration(
            blocks(["# Book", "> one", "> two", "> three"]), link: link, at: date)
        XCTAssertEqual(try note.text, "# Book\n\n> one\n\n> two\n\nMine\n\n> three")
    }

    func testARemovedHighlightGoesWithItsBlankLine() throws {
        let note = try created(["# Book", "> one", "> two", "> three"])
        try insert(note, "\nMine", after: "> two")
        try note.applyIntegration(blocks(["# Book", "> one", "> three"]), link: link, at: date)
        XCTAssertEqual(try note.text, "# Book\n\n> one\nMine\n\n> three")
    }

    func testTheHeaderIsEditedInPlaceAtTheTop() throws {
        let note = try created(["---\nauthor: A\n---\n# Book", "> one"])
        try note.applyIntegration(
            blocks(["---\nauthor: B\n---\n# Book", "> one"]), link: link, at: date)
        XCTAssertEqual(try note.text, "---\nauthor: B\n---\n# Book\n\n> one")
        XCTAssertEqual(try note.integrationBlockTexts()["header"], "---\nauthor: B\n---\n# Book")
    }

    func testRestoredTextIsYoursAndAChangeAddsTheNewVersion() throws {
        let note = try created(["# Book", "> one", "> two"])
        try delete(note, "\n\n> one")
        try note.restoreHistoricalText("# Book\n\n> one\n\n> two")
        try note.applyIntegration(blocks(["# Book", "> one changed", "> two"]), link: link, at: date)
        XCTAssertEqual(try note.text, "# Book\n\n> one changed\n\n> one\n\n> two")
    }

    /// A whole-text replacement, as Restore and a stale editor commit
    /// make, must not hand a character of one highlight to its neighbour.
    /// "> two" and "> three" share "> t"; the replaced region is widened to
    /// whole blocks, so "> three" becomes the person's text, intact.
    func testAWholeTextReplacementLeavesNeighboursIntact() throws {
        let note = try created(["# Book", "> one", "> two", "> three"])
        try note.replaceAll(with: "# Book\n\n> one\n\n> three", at: date)
        XCTAssertNil(try note.integrationBlockTexts()["three"])
        try note.applyIntegration(
            blocks(["# Book", "> one", "> two changed", "> three"]), link: link, at: date)
        XCTAssertEqual(try note.text, "# Book\n\n> one\n\n> two changed\n\n> three")
    }

    func testANoteStartingWithAByteOrderMarkUpdates() throws {
        let note = try NoteDocument(text: "\u{FEFF}", metadata: .now(date))
        try note.applyIntegration(blocks(["# Book", "> one", "> two", "> three"]), link: link, at: date)
        try note.applyIntegration(
            blocks(["# Book", "> one changed", "> two", "> three"]), link: link, at: date)
        XCTAssertEqual(try note.integrationBlockTexts()["one"], "> one changed")
        try note.replaceAll(with: "# Book\n\n> one changed\n\n> three\u{FEFF}", at: date)
        XCTAssertNil(try note.integrationBlockTexts()["three"])
        XCTAssertEqual(try note.integrationBlockTexts()["one"], "> one changed")
    }

    func testAnEmptyHighlightIsNotWritten() throws {
        let note = try created(["# Book", "> one"])
        let empty = NotebookIntegrationBlock(key: "two", text: "")
        try note.applyIntegration(blocks(["# Book", "> one"]) + [empty], link: link, at: date)
        XCTAssertEqual(try note.text, "# Book\n\n> one")
        try note.applyIntegration(blocks(["# Book", "> one", "> two"]), link: link, at: date)
        try note.applyIntegration(blocks(["# Book", "> one"]) + [empty], link: link, at: date)
        XCTAssertEqual(try note.text, "# Book\n\n> one")
        try note.applyIntegration(blocks(["# Book", "> one", "> two"]), link: link, at: date)
        try note.applyIntegration(blocks(["# Book", "> one"]), link: link, at: date)
        XCTAssertEqual(try note.text, "# Book\n\n> one")
    }

    func testAnotherLinkIsRefused() throws {
        let note = try created(["# Book"])
        let other = NotebookIntegrationLink(connection: UUID(), item: "book-1")
        XCTAssertThrowsError(try note.applyIntegration(blocks(["# Book"]), link: other, at: date))
        let plain = try NoteDocument(text: "mine")
        XCTAssertNil(plain.integrationLink)
    }

    // MARK: - Several devices

    func testTwoDevicesUpdatingTheSameHighlightEndWithOneCopy() throws {
        for attempt in 0..<100 {
            let base = try created(["# Book", "> one", "> two"])
            try insert(base, "Mine\n\n", before: "> one")
            try insert(base, "\n\nAlso mine", after: "> two")
            let left = try base.fork()
            let right = try base.fork()
            try left.applyIntegration(blocks(["# Book", "> one left", "> two"]), link: link, at: date)
            try right.applyIntegration(blocks(["# Book", "> one right", "> two"]), link: link, at: date)
            try left.merge(right)
            let expected = try left.integrationBlockTexts()["one"]!
            XCTAssertTrue(["> one left", "> one right"].contains(expected), "attempt \(attempt)")

            // The next sync on either device brings the newest text.
            try left.applyIntegration(blocks(["# Book", "> one right", "> two"]), link: link, at: date)
            XCTAssertEqual(try left.text, "# Book\n\nMine\n\n> one right\n\n> two\n\nAlso mine",
                           "attempt \(attempt)")
        }
    }

    func testTwoDevicesCleaningUpAtOnceAgree() throws {
        for attempt in 0..<100 {
            let base = try created(["# Book", "> one"])
            try insert(base, "Mine\n\n", before: "> one")
            let left = try base.fork()
            let right = try base.fork()
            try left.applyIntegration(blocks(["# Book", "> one new"]), link: link, at: date)
            try right.applyIntegration(blocks(["# Book", "> one new"]), link: link, at: date)
            try left.merge(right)
            let cleaners = [try left.fork(), try left.fork()]
            for cleaner in cleaners {
                try cleaner.applyIntegration(blocks(["# Book", "> one new"]), link: link, at: date)
            }
            try cleaners[0].merge(cleaners[1])
            XCTAssertEqual(try cleaners[0].text, "# Book\n\nMine\n\n> one new", "attempt \(attempt)")
        }
    }

    func testThreeDevicesWithPartialDeliveryEndWithOneCopy() throws {
        for attempt in 0..<60 {
            let base = try created(["# Book", "> one"])
            try insert(base, "Mine\n\n", before: "> one")
            try insert(base, "\n\nEnd", after: "> one")
            let devices = [try base.fork(), try base.fork(), try base.fork()]
            for (device, text) in zip(devices, ["> one a", "> one b", "> one c"]) {
                try device.applyIntegration(blocks(["# Book", text]), link: link, at: date)
            }
            // Each pair meets and cleans up before everything meets.
            let ab = try devices[0].fork(); try ab.merge(devices[1])
            let bc = try devices[1].fork(); try bc.merge(devices[2])
            let ac = try devices[0].fork(); try ac.merge(devices[2])
            for (pair, text) in [(ab, "> one a"), (bc, "> one b"), (ac, "> one c")] {
                try pair.applyIntegration(blocks(["# Book", text]), link: link, at: date)
            }
            try ab.merge(bc); try ab.merge(ac)
            try ab.applyIntegration(blocks(["# Book", "> one c"]), link: link, at: date)
            XCTAssertEqual(try ab.text, "# Book\n\nMine\n\n> one c\n\nEnd", "attempt \(attempt)")
        }
    }

    func testTypingInsideALosingCopyGoesWithItAndTextOutsideStays() throws {
        for attempt in 0..<60 {
            let base = try created(["# Book", "> one"])
            try insert(base, "Mine\n\n", before: "> one")
            try insert(base, "\n\nEnd", after: "> one")
            let left = try base.fork()
            let right = try base.fork()
            try left.applyIntegration(blocks(["# Book", "> one left"]), link: link, at: date)
            try right.applyIntegration(blocks(["# Book", "> one right"]), link: link, at: date)
            try left.merge(right)
            let typist = try left.fork()
            let cleaner = try left.fork()
            // The typist adds a word inside each copy and a line outside.
            try insert(typist, " typed ", after: "> one le")
            try insert(typist, " typed ", after: "> one ri")
            try insert(typist, "\nOutside", after: "End")
            try cleaner.applyIntegration(blocks(["# Book", "> one right"]), link: link, at: date)
            try cleaner.merge(typist)
            try cleaner.applyIntegration(blocks(["# Book", "> one right"]), link: link, at: date)

            let result = try cleaner.text
            XCTAssertTrue(result.hasPrefix("# Book\n\nMine\n\n"), "attempt \(attempt): \(result)")
            XCTAssertTrue(result.hasSuffix("\n\nEnd\nOutside"), "attempt \(attempt): \(result)")
            XCTAssertEqual(result.components(separatedBy: " typed ").count, 2,
                           "attempt \(attempt): \(result)")
            XCTAssertEqual(try cleaner.integrationBlockTexts().count, 2, "attempt \(attempt)")
        }
    }

    // MARK: - Helpers

    /// The first text is the header; each highlight's key is its first
    /// word, so "> one changed" updates the block "> one" created.
    private func blocks(_ texts: [String]) -> [NotebookIntegrationBlock] {
        texts.enumerated().map { index, text in
            let key = index == 0 ? NotebookIntegrationBlock.headerKey
                : String(text.split(separator: " ")[1]).lowercased()
            return NotebookIntegrationBlock(key: key, text: text)
        }
    }

    private func created(_ texts: [String]) throws -> NoteDocument {
        let note = try NoteDocument(text: "", metadata: .now(date))
        try note.applyIntegration(blocks(texts), link: link, at: date)
        return note
    }

    /// Typing at one place, as the editor writes it.
    private func insert(_ note: NoteDocument, _ text: String, before anchor: String) throws {
        let range = (try note.text as NSString).range(of: anchor)
        XCTAssertNotEqual(range.location, NSNotFound, anchor)
        try note.replaceUTF16(range: NSRange(location: range.location, length: 0), with: text, at: date)
    }

    private func insert(_ note: NoteDocument, _ text: String, after anchor: String) throws {
        let range = (try note.text as NSString).range(of: anchor)
        XCTAssertNotEqual(range.location, NSNotFound, anchor)
        try note.replaceUTF16(range: NSRange(location: NSMaxRange(range), length: 0), with: text, at: date)
    }

    /// Selecting text and deleting it.
    private func delete(_ note: NoteDocument, _ text: String) throws {
        let range = (try note.text as NSString).range(of: text)
        XCTAssertNotEqual(range.location, NSNotFound, text)
        try note.replaceUTF16(range: range, with: "", at: date)
    }
}
