import Automerge
import Foundation
import XCTest

@testable import NoteCore

final class NoteHistoryTests: XCTestCase {
    func testPastTextStatesRoundTripWithoutChangingLiveNote() throws {
        let original = "# Café\n\ne\u{301} 👋🏽\n"
        let note = try NoteDocument(
            text: original, metadata: NoteMetadata(createdAt: Self.at(0), modifiedAt: Self.at(0))
        )
        _ = note.snapshot()
        try note.replaceAll(with: original + "Second\n", at: Self.at(600))
        _ = note.snapshot()
        try note.replaceAll(with: original + "Third\n", at: Self.at(1_200))
        let saved = note.snapshot()
        let reopened = try NoteDocument(snapshot: saved)

        let versions = try reopened.historyVersions()
        try assertDetailsMatchOracle(reopened)

        XCTAssertEqual(versions.count, 2)
        XCTAssertTrue(versions.allSatisfy(\.isOverviewStop))
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
        try assertDetailsMatchOracle(reopened)
        let texts = try versions.map(reopened.historicalText(for:))

        XCTAssertEqual(try reopened.text, "ONE TWO")
        XCTAssertTrue(texts.contains("one two"))
        XCTAssertTrue(texts.contains("ONE two") || texts.contains("one TWO"))
        XCTAssertEqual(Set(versions.map(\.id)).count, versions.count)
        // Each device's edit is its own session.
        XCTAssertEqual(versions.count, 2)
    }

    func testUnknownMetadataUsesRecordedChangeDate() throws {
        let note = try NoteDocument(text: "first", metadata: .unknown)
        _ = note.snapshot()
        try note.replaceAll(with: "second", at: Self.at(600))
        _ = note.snapshot()
        try note.replaceAll(with: "third", at: Self.at(1_200))

        let versions = try note.historyVersions()
        try assertDetailsMatchOracle(note)

        XCTAssertEqual(versions.count, 2)
        XCTAssertNotNil(versions[0].date)
        XCTAssertEqual(versions[1].date, Self.at(600))
        XCTAssertEqual(try versions.map(note.historicalText(for:)), ["first", "second"])
    }

    func testSavedEditDatesDescribeTheirOwnTextState() throws {
        let note = try NoteDocument(
            text: "first",
            metadata: NoteMetadata(createdAt: Self.at(0), modifiedAt: Self.at(0))
        )
        _ = note.snapshot()
        try note.replaceAll(with: "second", at: Self.at(600))
        _ = note.snapshot()
        try note.replaceAll(with: "third", at: Self.at(1_200))
        _ = note.snapshot()

        XCTAssertEqual(try note.historyVersions().map(\.date), [Self.at(0), Self.at(600)])
        try assertDetailsMatchOracle(note)
    }

    func testClockSkewStartsASessionAndUsesTheChangeDate() throws {
        let note = try NoteDocument(
            text: "first",
            metadata: NoteMetadata(createdAt: Self.at(0), modifiedAt: Self.at(0))
        )
        _ = note.snapshot()
        try note.replaceAll(with: "second", at: Self.at(-50))
        _ = note.snapshot()
        try note.replaceAll(with: "third", at: Self.at(600))
        _ = note.snapshot()

        XCTAssertEqual(try note.historyVersions().map(\.date), [Self.at(0), Self.at(-50)])
        try assertDetailsMatchOracle(note)
    }

    func testRapidEditsWithUnchangedMetadataStillHaveDates() throws {
        let first = Self.at(0)
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
        try note.replaceAll(with: "later", at: Self.at(600))

        let reopened = try NoteDocument(snapshot: note.snapshot())
        // Edits without a pause between them are one step.
        let detailed = try reopened.historyVersions(detailed: true)
        XCTAssertEqual(detailed.map(\.date), [first])
        XCTAssertEqual(try detailed.map(reopened.historicalText(for:)), ["fourth"])
    }

    func testTypingWithoutShortPausesIsOneStep() throws {
        let note = try NoteDocument(
            text: "A", metadata: NoteMetadata(createdAt: Self.at(0), modifiedAt: Self.at(0))
        )
        _ = note.snapshot()
        for time in Array(600 ... 609) + Array(620 ... 624) {
            try note.replaceUTF16(
                range: NSRange(location: (try note.text).utf16.count, length: 0),
                with: "b", at: Self.at(Double(time))
            )
        }
        try note.replaceAll(with: "Later", at: Self.at(1_300))

        let detailed = try note.historyVersions(detailed: true)
        XCTAssertEqual(detailed.map(\.isOverviewStop), [true, false, true])
        XCTAssertEqual(detailed.map(\.addedCharacters), [1, 10, 5])
        XCTAssertEqual(detailed.map(\.date), [Self.at(0), Self.at(609), Self.at(624)])
    }

    func testChangesWithoutTimeUseTheModifiedDateWithFewReads() throws {
        let raw = Document(textEncoding: .unicodeScalar)
        try raw.put(obj: .ROOT, key: "noteID", value: .String(UUID().uuidString))
        try raw.put(obj: .ROOT, key: "schemaVersion", value: .Uint(1))
        let body = try raw.putObject(obj: .ROOT, key: "text", ty: .Text)
        // Old app versions saved changes without a time.
        for seconds in [0] + Array(600 ..< 1_100) + [2_000] {
            try raw.spliceText(obj: body, start: raw.length(obj: body), delete: 0, value: "x")
            try raw.put(obj: .ROOT, key: "modifiedAt", value: .Timestamp(Self.at(Double(seconds))))
            raw.commitWith(timestamp: Date(timeIntervalSince1970: 0))
        }
        let note = try NoteDocument(serializedData: raw.save())

        let builder = try note.makeHistoryBuilder()
        while !builder.isComplete { try builder.advance(batchSize: 128) }
        XCTAssertEqual(builder.sessionCount, 3)
        XCTAssertLessThan(builder.timeReadCount, 60)
        note.installHistoryIndex(builder)
        let versions = try note.historyVersions()
        XCTAssertEqual(versions.map(\.date), [Self.at(0), Self.at(1_099)])
        XCTAssertEqual(versions.map(\.sessionAddedCharacters), [1, 500])
    }

    func testTypingWithoutLongPausesIsOneSession() throws {
        let note = try NoteDocument(
            text: "A", metadata: NoteMetadata(createdAt: Self.at(0), modifiedAt: Self.at(0))
        )
        _ = note.snapshot()
        // Pauses up to three minutes stay inside one session.
        var time = 600.0
        for index in 0 ..< 100 {
            try note.replaceUTF16(
                range: NSRange(location: index + 1, length: 0), with: index == 50 ? "\n" : "b",
                at: Self.at(time)
            )
            time += index == 30 ? 180 : 10
        }
        try note.replaceAll(with: "Later", at: Self.at(time + 600))

        let versions = try note.historyVersions()
        XCTAssertEqual(versions.count, 2)
        XCTAssertTrue(versions.allSatisfy(\.isOverviewStop))
        XCTAssertEqual(try note.historicalText(for: versions[0]), "A")
        XCTAssertEqual(try note.historicalText(for: versions[1]).count, 101)
        // Until its details load, a stop compares with the previous stop.
        XCTAssertEqual(versions[1].addedCharacters, 100)
        XCTAssertEqual(versions[1].sessionAddedCharacters, 100)

        let detailed = try note.historyVersions(detailed: true)
        XCTAssertEqual(detailed.count, 101)
        XCTAssertEqual(detailed.filter(\.isOverviewStop).map(\.id), versions.map(\.id))
        XCTAssertEqual(detailed[100].addedCharacters, 1)
        XCTAssertEqual(detailed[100].sessionAddedCharacters, 100)
        try assertDetailsMatchOracle(note)
    }

    func testPauseLongerThanThreeMinutesStartsSession() throws {
        let note = try NoteDocument(
            text: "A", metadata: NoteMetadata(createdAt: Self.at(0), modifiedAt: Self.at(0))
        )
        _ = note.snapshot()
        for (character, time) in [
            ("b", 600.0), ("c", 610.0), ("d", 791.0), ("e", 801.0),
        ] {
            try note.replaceUTF16(
                range: NSRange(location: (try note.text).utf16.count, length: 0),
                with: character, at: Self.at(time)
            )
            _ = note.snapshot()
        }

        let versions = try note.historyVersions()
        XCTAssertEqual(try versions.map(note.historicalText(for:)), ["A", "Abc"])
        XCTAssertEqual(versions.map(\.sessionAddedCharacters), [1, 2])
        XCTAssertEqual(try note.historyVersions(detailed: true).map(\.isOverviewStop),
                       [true, false, true, false])
        try assertDetailsMatchOracle(note)
    }

    func testUnknownDatesKeepEveryChangeASession() throws {
        let raw = Document(textEncoding: .unicodeScalar)
        try raw.put(obj: .ROOT, key: "noteID", value: .String(UUID().uuidString))
        try raw.put(obj: .ROOT, key: "schemaVersion", value: .Uint(1))
        let body = try raw.putObject(obj: .ROOT, key: "text", ty: .Text)
        for (index, character) in ["A", "b", "c"].enumerated() {
            try raw.spliceText(obj: body, start: UInt64(index), delete: 0, value: character)
            raw.commitWith(timestamp: Date(timeIntervalSince1970: 0))
        }
        let note = try NoteDocument(serializedData: raw.save())

        let versions = try note.historyVersions()
        XCTAssertEqual(try versions.map(note.historicalText(for:)), ["A", "Ab"])
        XCTAssertEqual(versions.map(\.date), [nil, nil])
        try assertDetailsMatchOracle(note)
    }

    func testRestoreIsItsOwnSessionEvenForOneCharacterChange() throws {
        let note = try NoteDocument(
            text: "A", metadata: NoteMetadata(createdAt: Self.at(0), modifiedAt: Self.at(0))
        )
        _ = note.snapshot()
        for (character, time) in [("b", 600.0), ("c", 610.0)] {
            try note.replaceUTF16(
                range: NSRange(location: (try note.text).utf16.count, length: 0),
                with: character, at: Self.at(time)
            )
            _ = note.snapshot()
        }
        let previous = try XCTUnwrap(note.historyVersions(detailed: true).last)
        XCTAssertEqual(try note.historicalText(for: previous), "Ab")

        try note.restoreHistoryVersion(previous, at: Self.at(611))
        _ = note.snapshot()

        let versions = try note.historyVersions()
        XCTAssertEqual(try versions.map(note.historicalText(for:)), ["A", "Abc"])
        try assertDetailsMatchOracle(note)
    }

    func testMetadataOnlyChangeDoesNotAddTextVersion() throws {
        let note = try NoteDocument(
            text: "first", metadata: NoteMetadata(createdAt: Self.at(0), modifiedAt: Self.at(0))
        )
        _ = note.snapshot()
        try note.replaceAll(with: "second", at: Self.at(600))
        let second = note.snapshot()
        let raw = try Document(second.data)
        try raw.put(obj: .ROOT, key: "modifiedAt", value: .Timestamp(Self.at(1_200)))
        raw.commitWith(timestamp: Self.at(1_200))
        let changed = try NoteDocument(serializedData: raw.save())

        let versions = try changed.historyVersions()
        XCTAssertEqual(versions.count, 1)
        XCTAssertEqual(try changed.historicalText(for: versions[0]), "first")
        try assertDetailsMatchOracle(changed)
    }

    func testSessionWithoutNetTextChangeExtendsThePreviousState() throws {
        let note = try NoteDocument(
            text: "first", metadata: NoteMetadata(createdAt: Self.at(0), modifiedAt: Self.at(0))
        )
        _ = note.snapshot()
        try note.replaceAll(with: "first!", at: Self.at(600))
        try note.replaceAll(with: "first", at: Self.at(610))
        try note.replaceAll(with: "second", at: Self.at(1_200))

        let versions = try note.historyVersions()
        XCTAssertEqual(try versions.map(note.historicalText(for:)), ["first"])
        XCTAssertEqual(versions[0].sessionAddedCharacters, 5)
        let detailed = try note.historyVersions(detailed: true)
        XCTAssertEqual(try detailed.map(note.historicalText(for:)), ["first", "first!", "first"])
        XCTAssertEqual(detailed.last?.id, versions[0].id)
    }

    func testDetailsRefineTheDateOfASessionEndingInMetadata() throws {
        let raw = Document(textEncoding: .unicodeScalar)
        try raw.put(obj: .ROOT, key: "noteID", value: .String(UUID().uuidString))
        try raw.put(obj: .ROOT, key: "schemaVersion", value: .Uint(1))
        let body = try raw.putObject(obj: .ROOT, key: "text", ty: .Text)
        func commit(_ seconds: Double, text: String?) throws {
            if let text {
                try raw.spliceText(obj: body, start: raw.length(obj: body), delete: 0, value: text)
            }
            try raw.put(obj: .ROOT, key: "modifiedAt", value: .Timestamp(Self.at(seconds)))
            raw.commitWith(timestamp: Self.at(seconds))
        }
        try commit(0, text: "first")
        try commit(600, text: "!")
        // Metadata only, in the same session.
        try commit(700, text: nil)
        try commit(1_500, text: "?")
        let note = try NoteDocument(serializedData: raw.save())

        let sessions = try note.historyVersions()
        XCTAssertEqual(sessions.map(\.date), [Self.at(0), Self.at(700)])
        let detailed = try note.historyVersions(detailed: true)
        XCTAssertEqual(detailed.map(\.id), sessions.map(\.id))
        XCTAssertEqual(detailed.map(\.date), [Self.at(0), Self.at(600)])
        try assertDetailsMatchOracle(note)
    }

    func testRestoreAppendsAnEditAndRetainsPreRestoreText() throws {
        let note = try NoteDocument(
            text: "first", metadata: NoteMetadata(createdAt: Self.at(0), modifiedAt: Self.at(0))
        )
        _ = note.snapshot()
        try note.replaceAll(with: "second", at: Self.at(600))
        _ = note.snapshot()
        let priorHeads = note.heads
        let version = try XCTUnwrap(note.historyVersions().first)

        try note.restoreHistoryVersion(version, at: Self.at(1_200))

        XCTAssertEqual(try note.text, "first")
        XCTAssertNotEqual(note.heads, priorHeads)
        XCTAssertTrue(priorHeads.isSubset(of: note.historyHeads))
        let reopened = try NoteDocument(snapshot: note.snapshot())
        XCTAssertTrue(try reopened.historyVersions().contains {
            try reopened.historicalText(for: $0) == "second"
        })
    }

    func testVersionsRecordTheCharactersEachEditAddedAndRemoved() throws {
        let start = Self.at(0)
        let note = try NoteDocument(
            text: "Hello",
            metadata: NoteMetadata(createdAt: start, modifiedAt: start)
        )
        try note.replaceUTF16(
            range: NSRange(location: 5, length: 0), with: " world 👋🏽",
            at: start.addingTimeInterval(10)
        )
        try note.replaceUTF16(
            range: NSRange(location: 5, length: 6), with: "",
            at: start.addingTimeInterval(20)
        )
        try note.replaceAll(with: "Bye", at: start.addingTimeInterval(600))

        let detailed = try note.historyVersions(detailed: true)
        XCTAssertEqual(detailed.map(\.addedCharacters), [5, 9, 0])
        XCTAssertEqual(detailed.map(\.removedCharacters), [0, 0, 6])
        // The session counts its net change, not the sum of its edits.
        let stop = try XCTUnwrap(detailed.last)
        XCTAssertEqual(stop.sessionAddedCharacters, 8)
        XCTAssertEqual(stop.sessionRemovedCharacters, 0)
        try assertDetailsMatchOracle(note)
    }

    func testIndexComparesOncePerSession() throws {
        let note = try NoteDocument(
            text: "A", metadata: NoteMetadata(createdAt: Self.at(0), modifiedAt: Self.at(0))
        )
        for session in 0 ..< 4 {
            for index in 0 ..< 50 {
                try note.replaceUTF16(
                    range: NSRange(location: (try note.text).utf16.count, length: 0),
                    with: "x", at: Self.at(Double(1_000 * (session + 1) + 10 * index))
                )
            }
        }
        let builder = try note.makeHistoryBuilder()
        while !builder.isComplete { try builder.advance(batchSize: 32) }
        XCTAssertEqual(builder.sessionCount, 5)
        XCTAssertEqual(builder.processedChangeCount, note.historyCount)
        XCTAssertEqual(builder.detailChangeCount, 0)
        XCTAssertFalse(try builder.advanceDetails(ofSession: 2, batchSize: 25))
        XCTAssertEqual(builder.detailChangeCount, 25)
        XCTAssertTrue(try builder.advanceDetails(ofSession: 2, batchSize: 25))
        XCTAssertEqual(builder.detailChangeCount, 50)
        XCTAssertEqual(builder.versions.count, 4 + 49)
    }

    func testCancelledBatchesResumeWithoutSkippingChanges() async throws {
        let bytes = try NoteHistoryPerformanceTests().makeFixture(lines: 3, edits: 120)
        let note = try NoteDocument(serializedData: bytes)
        nonisolated(unsafe) let builder = try note.makeHistoryBuilder()
        try builder.advance(batchSize: 16)
        let cancelled = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try builder.advance(batchSize: 16)
        }.result
        XCTAssertThrowsError(try cancelled.get())
        XCTAssertEqual(builder.processedChangeCount, 16)
        while !builder.isComplete { try builder.advance(batchSize: 16) }
        XCTAssertEqual(builder.processedChangeCount, note.historyCount)

        let cancelledDetails = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try builder.advanceDetails(ofSession: 1, batchSize: 4)
        }.result
        XCTAssertThrowsError(try cancelledDetails.get())
        XCTAssertEqual(builder.detailChangeCount, 0)
        while try !builder.advanceDetails(ofSession: 1, batchSize: 4) {}
        XCTAssertEqual(builder.detailChangeCount, 40)
        note.installHistoryIndex(builder)
        XCTAssertEqual(try note.historyVersions().filter(\.isOverviewStop).map(\.id),
                       try NoteDocument(serializedData: bytes).historyVersions().map(\.id))
    }

    // MARK: Helpers

    private static func at(_ seconds: Double) -> Date {
        Date(timeIntervalSince1970: 10_000 + seconds)
    }

    /// With every session's details loaded and no edits closer than a
    /// step's pause, the index lists exactly the text states the previous
    /// per-change index did.
    private func assertDetailsMatchOracle(
        _ note: NoteDocument, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let detailed = try note.historyVersions(detailed: true)
        let oracle = try NoteHistoryLegacyOracle(snapshot: note.snapshot()).historyVersions()
        XCTAssertEqual(detailed.map(Self.state), oracle.map(Self.state), file: file, line: line)
    }

    static func state(_ version: NoteHistoryVersion) -> String {
        let date = version.date.map { "\($0.timeIntervalSince1970)" } ?? "nil"
        return "\(version.id)|\(date)|+\(version.addedCharacters)|-\(version.removedCharacters)"
    }
}
