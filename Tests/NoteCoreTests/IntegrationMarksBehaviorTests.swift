import Automerge
import Foundation
import XCTest

/// The integration design (docs/readwise-sync.md) relies on how Automerge
/// text marks behave. These tests pin that behavior in plain Automerge, so
/// an Automerge update that changes it fails here first.
final class IntegrationMarksBehaviorTests: XCTestCase {
    private let markName = "integration"

    func testTypingInsideABlockJoinsItButTypingAtItsEdgesDoesNot() throws {
        let (document, text) = try makeDocument("before")
        try insertBlock(document, text, at: 6, "> quote", value: "a")
        try document.spliceText(obj: text, start: 14, delete: 0, value: "\nafter")
        try document.spliceText(obj: text, start: 11, delete: 0, value: "INSIDE ")
        try document.spliceText(obj: text, start: 7, delete: 0, value: "START")
        let end = try ranges(document, text, value: "a").last!.upperBound
        try document.spliceText(obj: text, start: end, delete: 0, value: "END")

        XCTAssertEqual(try marked(document, text, value: "a"), ["> quINSIDE ote"])
        XCTAssertEqual(try document.text(obj: text), "before\nSTART> quINSIDE oteEND\nafter")
    }

    /// Automerge anchors the start of a mark to the character in front of
    /// it. Two copies inserted at the same place by two devices then bleed
    /// into each other, unless each insertion brings its own character in
    /// front of the marked text.
    func testCopiesStayApartOnlyWithTheirOwnLeadingCharacter() throws {
        var bledWithout = 0
        for _ in 0..<100 {
            for ownLead in [true, false] {
                let (base, text) = try makeDocument("mine")
                try insertBlock(base, text, at: 4, "old", value: "base")
                try base.spliceText(obj: text, start: 8, delete: 0, value: "\nmine")
                let left = base.fork()
                let right = base.fork()
                for (device, value) in [(left, "left"), (right, "right")] {
                    try device.spliceText(obj: text, start: 5, delete: 3)
                    if ownLead {
                        try device.spliceText(obj: text, start: 4, delete: 1)
                        try insertBlock(device, text, at: 4, value, value: value)
                    } else {
                        try device.spliceText(obj: text, start: 5, delete: 0, value: value)
                        try device.mark(obj: text, start: 5, end: 5 + UInt64(value.count),
                                        expand: .none, name: markName, value: .String(value))
                    }
                }
                try left.merge(other: right)
                let apart = try marked(left, text, value: "left") == ["left"]
                    && marked(left, text, value: "right") == ["right"]
                if ownLead {
                    XCTAssertTrue(apart)
                } else if !apart {
                    bledWithout += 1
                }
            }
        }
        XCTAssertGreaterThan(bledWithout, 0, "copies without their own lead stopped bleeding")
    }

    func testTypingThatArrivesAfterABlockWasReplacedKeepsTheOldMark() throws {
        let (base, text) = try makeDocument("")
        try insertBlock(base, text, at: 0, "old quote", value: "old")
        let syncing = base.fork()
        let typing = base.fork()
        try syncing.spliceText(obj: text, start: 1, delete: 9)
        try syncing.spliceText(obj: text, start: 0, delete: 1)
        try insertBlock(syncing, text, at: 0, "new quote", value: "new")
        try typing.spliceText(obj: text, start: 4, delete: 0, value: " mine")
        try syncing.merge(other: typing)

        XCTAssertEqual(try marked(syncing, text, value: "old"), [" mine"])
        XCTAssertEqual(try marked(syncing, text, value: "new"), ["new quote"])
    }

    /// Only one value of a mark name shows at a position, so overlapping
    /// marks with the same name hide each other. Leads use one name each.
    func testOverlappingMarksWithOneNameShowOneValue() throws {
        let (document, text) = try makeDocument("abcdef")
        try document.mark(obj: text, start: 0, end: 4, expand: .none, name: "lead", value: .String("x"))
        try document.mark(obj: text, start: 2, end: 6, expand: .none, name: "lead", value: .String("y"))
        let values = try document.marks(obj: text).filter { $0.name == "lead" }
            .flatMap { mark in (mark.start..<mark.end).map { _ in mark.value } }
        XCTAssertEqual(values.count, 6)
    }

    /// `updateText` diffs characters: here it keeps the final "e" of the
    /// quote for "more", so the new text lands inside the mark. Linked
    /// notes therefore never replace their whole text this way.
    func testACharacterDiffCanPullNewTextIntoAMark() throws {
        let (document, text) = try makeDocument("intro")
        try insertBlock(document, text, at: 5, "> quote", value: "a")
        try document.updateText(obj: text, value: "intro edited\n> quote\nmore")
        XCTAssertNotEqual(try marked(document, text, value: "a"), ["> quote"])
    }

    func testMarksSurviveSavingAndLoading() throws {
        let (document, text) = try makeDocument("")
        try insertBlock(document, text, at: 0, "> quote", value: "a")
        let loaded = try Document(document.save())
        XCTAssertEqual(try marked(loaded, text, value: "a"), ["> quote"])
    }

    func testMarkingWithNullClearsAMark() throws {
        let (document, text) = try makeDocument("")
        try insertBlock(document, text, at: 0, "abcdef", value: "a")
        try document.mark(obj: text, start: 1, end: 7, expand: .none, name: markName, value: .Null)
        XCTAssertTrue(try marked(document, text, value: "a").isEmpty)
    }

    // MARK: - Helpers

    private func makeDocument(_ initial: String) throws -> (Document, ObjId) {
        let document = Document(textEncoding: .unicodeScalar)
        let text = try document.putObject(obj: .ROOT, key: "text", ty: .Text)
        if !initial.isEmpty {
            try document.spliceText(obj: text, start: 0, delete: 0, value: initial)
        }
        return (document, text)
    }

    /// Inserts a line break and the block after it, marking only the block.
    private func insertBlock(
        _ document: Document, _ text: ObjId, at position: UInt64,
        _ value: String, value mark: String
    ) throws {
        try document.spliceText(obj: text, start: position, delete: 0, value: "\n" + value)
        try document.mark(
            obj: text, start: position + 1,
            end: position + 1 + UInt64(value.unicodeScalars.count),
            expand: .none, name: markName, value: .String(mark))
    }

    private func ranges(_ document: Document, _ text: ObjId, value: String) throws -> [Range<UInt64>] {
        try document.marks(obj: text)
            .filter { $0.name == markName && $0.value == .String(value) }
            .map { $0.start..<$0.end }
    }

    private func marked(_ document: Document, _ text: ObjId, value: String) throws -> [String] {
        let scalars = Array(try document.text(obj: text).unicodeScalars)
        return try ranges(document, text, value: value).map {
            String(String.UnicodeScalarView(scalars[Int($0.lowerBound)..<Int($0.upperBound)]))
        }
    }
}
