import Automerge
import Foundation
import XCTest

@testable import NoteCore

final class NoteHistoryTests: XCTestCase {
    func testPastTextStatesRoundTripWithoutChangingLiveNote() throws {
        let original = "# Café\n\ne\u{301} 👋🏽\n"
        let note = try NoteDocument(text: original)
        _ = note.snapshot()
        try note.replaceAll(
            with: original + "Second\n",
            at: Date(timeIntervalSince1970: 200)
        )
        _ = note.snapshot()
        try note.replaceAll(
            with: original + "Third\n",
            at: Date(timeIntervalSince1970: 300)
        )
        let saved = note.snapshot()
        let reopened = try NoteDocument(snapshot: saved)

        let versions = try reopened.historyVersions()
        XCTAssertEqual(versions, try NoteHistoryLegacyOracle(
            snapshot: reopened.snapshot()).historyVersions())

        XCTAssertEqual(versions.count, 2)
        XCTAssertEqual(versions.map(\.ordinal), [1, 2])
        XCTAssertEqual(try versions.map(reopened.historicalText(for:)), [
            original, original + "Second\n"
        ])
        XCTAssertEqual(reopened.snapshot(), saved)
        XCTAssertEqual(try reopened.historyVersions().map(\.id), versions.map(\.id))
    }

    func testConcurrentChangesRemainReconstructableAfterMerge() throws {
        let base = try NoteDocument(text: "one two")
        _ = base.snapshot()
        let left = try base.fork()
        let right = try base.fork()
        try left.replaceUTF16(
            range: NSRange(location: 0, length: 3),
            with: "ONE",
            at: Date(timeIntervalSince1970: 300)
        )
        try right.replaceUTF16(
            range: NSRange(location: 4, length: 3),
            with: "TWO",
            at: Date(timeIntervalSince1970: 200)
        )
        try left.merge(right)
        let reopened = try NoteDocument(snapshot: left.snapshot())

        let versions = try reopened.historyVersions()
        XCTAssertEqual(versions, try NoteHistoryLegacyOracle(
            snapshot: reopened.snapshot()).historyVersions())
        let texts = try versions.map(reopened.historicalText(for:))

        XCTAssertEqual(try reopened.text, "ONE TWO")
        XCTAssertTrue(texts.contains("one two"))
        XCTAssertTrue(texts.contains("ONE two") || texts.contains("one TWO"))
        XCTAssertEqual(Set(versions.map(\.id)).count, versions.count)
        XCTAssertTrue(versions.allSatisfy(\.isOverviewStop))
    }

    func testUnknownMetadataUsesRecordedChangeDate()
        throws
    {
        let note = try NoteDocument(
            text: "first",
            metadata: .unknown
        )
        _ = note.snapshot()
        try note.replaceAll(
            with: "second",
            at: Date(timeIntervalSince1970: 200)
        )
        _ = note.snapshot()
        try note.replaceAll(
            with: "third",
            at: Date(timeIntervalSince1970: 300)
        )

        let versions = try note.historyVersions()
        XCTAssertEqual(versions, try NoteHistoryLegacyOracle(
            snapshot: note.snapshot()).historyVersions())

        XCTAssertEqual(versions.count, 2)
        XCTAssertNotNil(versions[0].date)
        XCTAssertEqual(versions[1].date, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(
            try versions.map(note.historicalText(for:)),
            ["first", "second"]
        )
    }

    func testSavedEditDatesDescribeTheirOwnTextState() throws {
        let first = Date(timeIntervalSince1970: 100)
        let second = Date(timeIntervalSince1970: 200)
        let third = Date(timeIntervalSince1970: 300)
        let note = try NoteDocument(
            text: "first",
            metadata: NoteMetadata(createdAt: first, modifiedAt: first)
        )
        _ = note.snapshot()
        try note.replaceAll(with: "second", at: second)
        _ = note.snapshot()
        try note.replaceAll(with: "third", at: third)
        _ = note.snapshot()

        XCTAssertEqual(try note.historyVersions().map(\.date), [first, second])
    }

    func testClockSkewUsesTheChangeDateForTheLaterVersion() throws {
        let first = Date(timeIntervalSince1970: 100)
        let note = try NoteDocument(
            text: "first",
            metadata: NoteMetadata(createdAt: first, modifiedAt: first)
        )
        _ = note.snapshot()
        try note.replaceAll(
            with: "second", at: Date(timeIntervalSince1970: 50)
        )
        _ = note.snapshot()
        try note.replaceAll(
            with: "third", at: Date(timeIntervalSince1970: 200)
        )
        _ = note.snapshot()

        let dates = try note.historyVersions().map(\.date)

        XCTAssertEqual(dates.count, 2)
        XCTAssertEqual(dates[0], first)
        XCTAssertEqual(dates[1], Date(timeIntervalSince1970: 50))
    }

    func testRapidEditsWithUnchangedMetadataStillHaveDates() throws {
        let first = Date(timeIntervalSince1970: 100)
        let note = try NoteDocument(
            text: "first",
            metadata: NoteMetadata(createdAt: first, modifiedAt: first)
        )
        _ = note.snapshot()
        try note.replaceAll(with: "second", at: first)
        _ = note.snapshot()
        try note.replaceAll(with: "third", at: first)
        _ = note.snapshot()
        try note.replaceAll(with: "fourth", at: first)

        let reopened = try NoteDocument(snapshot: note.snapshot())
        let dates = try reopened.historyVersions().map(\.date)

        XCTAssertEqual(dates, [first, first, first])
    }

    func testRapidTypingHasOnePriorOverviewStopAndRawDetail()
        throws
    {
        let start = Date(timeIntervalSince1970: 100)
        let note = try NoteDocument(
            text: "A",
            metadata: NoteMetadata(createdAt: start, modifiedAt: start)
        )
        _ = note.snapshot()
        for index in 0 ..< 100 {
            try note.replaceUTF16(
                range: NSRange(location: index + 1, length: 0),
                with: "b",
                at: Date(timeIntervalSince1970: 200 + Double(index))
            )
            _ = note.snapshot()
        }

        let versions = try note.historyVersions()
        XCTAssertEqual(versions, try NoteHistoryLegacyOracle(
            snapshot: note.snapshot()).historyVersions())
        let overview = versions.enumerated().compactMap {
            $0.element.isOverviewStop ? $0.offset : nil
        } + [versions.count] // Synthetic Current stop.

        XCTAssertEqual(versions.count, 100)
        XCTAssertEqual(overview, [0, 100])
        XCTAssertEqual(try note.historicalText(for: versions[0]), "A")
        XCTAssertEqual(try note.historicalText(for: versions[99]).count, 100)
    }

    func testSeparateTypingRunsExposeLastStateOfEarlierRun() throws {
        let start = Date(timeIntervalSince1970: 100)
        let note = try NoteDocument(
            text: "A",
            metadata: NoteMetadata(createdAt: start, modifiedAt: start)
        )
        _ = note.snapshot()
        for (character, time) in [
            ("b", 200.0), ("c", 201.0),
            ("d", 300.0), ("e", 301.0)
        ] {
            try note.replaceUTF16(
                range: NSRange(location: (try note.text).utf16.count,
                               length: 0),
                with: character,
                at: Date(timeIntervalSince1970: time)
            )
            _ = note.snapshot()
        }

        let versions = try note.historyVersions()
        XCTAssertEqual(versions, try NoteHistoryLegacyOracle(
            snapshot: note.snapshot()).historyVersions())
        let overview = versions.enumerated().compactMap {
            $0.element.isOverviewStop ? $0.offset : nil
        } + [versions.count]

        XCTAssertEqual(overview, [0, 2, 4])
        XCTAssertEqual(try note.historicalText(for: versions[2]), "Abc")
    }

    func testNewlineStartsRunAndKeepsPriorCompleteText() throws {
        let start = Date(timeIntervalSince1970: 100)
        let note = try NoteDocument(
            text: "A",
            metadata: NoteMetadata(createdAt: start, modifiedAt: start)
        )
        _ = note.snapshot()
        for (character, time) in [
            ("b", 200.0), ("c", 201.0),
            ("\n", 202.0), ("d", 203.0)
        ] {
            try note.replaceUTF16(
                range: NSRange(location: (try note.text).utf16.count,
                               length: 0),
                with: character,
                at: Date(timeIntervalSince1970: time)
            )
            _ = note.snapshot()
        }

        let versions = try note.historyVersions()
        XCTAssertEqual(versions, try NoteHistoryLegacyOracle(
            snapshot: note.snapshot()).historyVersions())
        let overview = versions.enumerated().compactMap {
            $0.element.isOverviewStop ? $0.offset : nil
        } + [versions.count]

        XCTAssertEqual(overview, [0, 2, 4])
        XCTAssertEqual(try note.historicalText(for: versions[2]), "Abc")
    }

    func testUnknownDatesKeepEveryRawVersionInOverview() throws {
        let note = try NoteDocument(text: "A", metadata: .unknown)
        _ = note.snapshot()
        for (character, time) in [("b", 200.0), ("c", 100.0)] {
            try note.replaceUTF16(
                range: NSRange(location: (try note.text).utf16.count,
                               length: 0),
                with: character,
                at: Date(timeIntervalSince1970: time)
            )
            _ = note.snapshot()
        }

        XCTAssertTrue(try note.historyVersions().allSatisfy(\.isOverviewStop))
    }

    func testPasteEndsTypingRunAndPreservesItsCompleteState() throws {
        let start = Date(timeIntervalSince1970: 100)
        let note = try NoteDocument(
            text: "A",
            metadata: NoteMetadata(createdAt: start, modifiedAt: start)
        )
        _ = note.snapshot()
        for (character, time) in [("b", 200.0), ("c", 201.0)] {
            try note.replaceUTF16(
                range: NSRange(location: (try note.text).utf16.count,
                               length: 0),
                with: character,
                at: Date(timeIntervalSince1970: time)
            )
            _ = note.snapshot()
        }
        try note.replaceAll(
            with: "Abc pasted paragraph",
            at: Date(timeIntervalSince1970: 202)
        )
        _ = note.snapshot()

        let versions = try note.historyVersions()
        XCTAssertEqual(versions, try NoteHistoryLegacyOracle(
            snapshot: note.snapshot()).historyVersions())

        XCTAssertEqual(versions.map(\.isOverviewStop), [true, false, true])
        XCTAssertEqual(try note.historicalText(for: versions[2]), "Abc")
    }

    func testRestoreIsBoundaryEvenForOneCharacterChange() throws {
        let start = Date(timeIntervalSince1970: 100)
        let note = try NoteDocument(
            text: "A",
            metadata: NoteMetadata(createdAt: start, modifiedAt: start)
        )
        _ = note.snapshot()
        for (character, time) in [("b", 200.0), ("c", 201.0)] {
            try note.replaceUTF16(
                range: NSRange(location: (try note.text).utf16.count,
                               length: 0),
                with: character,
                at: Date(timeIntervalSince1970: time)
            )
            _ = note.snapshot()
        }
        let previous = try XCTUnwrap(note.historyVersions().last)

        try note.restoreHistoryVersion(
            previous, at: Date(timeIntervalSince1970: 202)
        )
        _ = note.snapshot()

        let versions = try note.historyVersions()
        XCTAssertEqual(versions, try NoteHistoryLegacyOracle(
            snapshot: note.snapshot()).historyVersions())
        XCTAssertEqual(versions.map(\.isOverviewStop), [true, false, true])
        XCTAssertEqual(try note.historicalText(for: versions[2]), "Abc")
    }

    func testMetadataOnlyChangeDoesNotAddTextVersion() throws {
        let note = try NoteDocument(text: "first")
        _ = note.snapshot()
        try note.replaceAll(with: "second")
        let second = note.snapshot()
        let raw = try Document(second.data)
        try raw.put(
            obj: .ROOT, key: "modifiedAt",
            value: .Timestamp(Date(timeIntervalSince1970: 200))
        )
        let changed = try NoteDocument(serializedData: raw.save())

        let versions = try changed.historyVersions()
        XCTAssertEqual(versions, try NoteHistoryLegacyOracle(
            snapshot: changed.snapshot()).historyVersions())

        XCTAssertEqual(versions.count, 1)
        XCTAssertEqual(try changed.historicalText(for: versions[0]), "first")
    }

    func testRestoreAppendsAnEditAndRetainsPreRestoreText() throws {
        let note = try NoteDocument(text: "first")
        _ = note.snapshot()
        try note.replaceAll(with: "second")
        _ = note.snapshot()
        let priorHeads = note.heads
        let version = try XCTUnwrap(note.historyVersions().first)

        try note.restoreHistoryVersion(version)

        XCTAssertEqual(try note.text, "first")
        XCTAssertNotEqual(note.heads, priorHeads)
        XCTAssertTrue(priorHeads.isSubset(of: note.historyHeads))
        let reopened = try NoteDocument(snapshot: note.snapshot())
        XCTAssertTrue(try reopened.historyVersions().contains {
            try reopened.historicalText(for: $0) == "second"
        })
    }
}
