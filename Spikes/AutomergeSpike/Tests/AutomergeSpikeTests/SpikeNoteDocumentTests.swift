import Automerge
import Foundation
import XCTest

@testable import AutomergeSpike

final class SpikeNoteDocumentTests: XCTestCase {
    private let noteID = UUID(
        uuidString: "9C86E52A-7037-4107-B7AA-148E3308A52D"
    )!

    func testUTF16EditsPreserveMarkdownAndUnicode() throws {
        let initial = "# Café\n\ne\u{301} 👋🏽\nline three"
        let note = try SpikeNoteDocument(noteID: noteID, text: initial)

        let emojiRange = (initial as NSString).range(of: "👋🏽")
        try note.replaceUTF16(range: emojiRange, with: "👨‍👩‍👧‍👦")

        let withFamily = try note.text
        let accentRange = (withFamily as NSString).range(of: "\u{301}")
        try note.replaceUTF16(range: accentRange, with: "")

        XCTAssertEqual(try note.text, "# Café\n\ne 👨‍👩‍👧‍👦\nline three")
    }

    func testRejectsRangeInsideSurrogatePair() throws {
        let note = try SpikeNoteDocument(noteID: noteID, text: "a😀b")
        let emojiRange = (try note.text as NSString).range(of: "😀")
        let splitPair = NSRange(location: emojiRange.location + 1, length: 0)

        XCTAssertThrowsError(
            try note.replaceUTF16(range: splitPair, with: "x")
        ) { error in
            XCTAssertEqual(
                error as? AutomergeTextIndexError,
                .invalidUTF16Range(splitPair)
            )
        }
        XCTAssertEqual(try note.text, "a😀b")
    }

    func testIndexConversionRoundTripsNativeAndAutomergeRanges() throws {
        let text = "e\u{301} 👋🏽 family 👨‍👩‍👧‍👦"
        let nativeRange = (text as NSString).range(of: "\u{301} 👋🏽")

        let scalarRange = try AutomergeTextIndex.unicodeScalarRange(
            forUTF16Range: nativeRange,
            in: text
        )
        let roundTrip = try AutomergeTextIndex.utf16Range(
            forUnicodeScalarStart: scalarRange.start,
            length: scalarRange.length,
            in: text
        )

        XCTAssertEqual(roundTrip, nativeRange)
    }

    func testSerializationPreservesIdentityTextAndHistory() throws {
        let note = try SpikeNoteDocument(
            noteID: noteID,
            text: "# Durable\n\nnaïve 👋🏽"
        )
        try note.replaceAll(with: "# Durable\n\nnaïve 👋🏽\n\nSaved.")
        let originalHistoryCount = note.historyCount
        let originalHeads = note.headsSnapshot
        let originalActor = note.actorID

        let data = note.serializedData()
        let reloaded = try SpikeNoteDocument(serializedData: data)

        XCTAssertEqual(reloaded.noteID, noteID)
        XCTAssertEqual(try reloaded.text, try note.text)
        XCTAssertEqual(reloaded.historyCount, originalHistoryCount)
        XCTAssertEqual(reloaded.headsSnapshot, originalHeads)
        XCTAssertTrue(originalHeads.isSubset(of: reloaded.historyHashes))
        XCTAssertNotEqual(reloaded.actorID, originalActor)
        XCTAssertFalse(data.isEmpty)
    }

    func testReloadPreservesExactUnicodeBytesAndAcceptsFurtherEdits() throws {
        let original = "# Café\n\ne\u{301} 👋🏽 👨‍👩‍👧‍👦\n"
        let note = try SpikeNoteDocument(noteID: noteID, text: original)
        let savedHeads = note.headsSnapshot
        let reloaded = try SpikeNoteDocument(
            serializedData: note.serializedData()
        )

        XCTAssertEqual(Array(try reloaded.text.utf8), Array(original.utf8))
        XCTAssertEqual(reloaded.headsSnapshot, savedHeads)

        try reloaded.replaceAll(with: original + "after reload\n")
        let savedAgain = try SpikeNoteDocument(
            serializedData: reloaded.serializedData()
        )
        XCTAssertEqual(
            Array(try savedAgain.text.utf8),
            Array((original + "after reload\n").utf8)
        )
        XCTAssertTrue(savedHeads.isSubset(of: savedAgain.historyHashes))
        XCTAssertNotEqual(savedAgain.headsSnapshot, savedHeads)
    }

    func testRejectsMissingAndUnsupportedSchemaVersions() throws {
        XCTAssertThrowsError(
            try SpikeNoteDocument(
                serializedData: rawDocument(schemaVersion: nil)
            )
        ) { error in
            XCTAssertEqual(error as? SpikeNoteError, .missingSchemaVersion)
        }
        XCTAssertThrowsError(
            try SpikeNoteDocument(
                serializedData: rawDocument(schemaVersion: .Uint(2))
            )
        ) { error in
            XCTAssertEqual(
                error as? SpikeNoteError,
                .unsupportedSchemaVersion
            )
        }
        XCTAssertThrowsError(
            try SpikeNoteDocument(
                serializedData: rawDocument(schemaVersion: .String("1"))
            )
        ) { error in
            XCTAssertEqual(
                error as? SpikeNoteError,
                .unexpectedSchemaVersion
            )
        }
    }

    func testIndependentEditsMergeAndConverge() throws {
        let original = "alpha\nbeta\n"
        let base = try SpikeNoteDocument(noteID: noteID, text: original)
        let left = try base.fork()
        let right = try base.fork()

        try left.replaceUTF16(
            range: NSRange(location: 0, length: 0),
            with: "left: "
        )
        try right.replaceUTF16(
            range: NSRange(
                location: (original as NSString).length,
                length: 0
            ),
            with: "right\n"
        )

        XCTAssertNotEqual(left.actorID, right.actorID)
        try left.merge(right)
        try right.merge(left)

        XCTAssertEqual(try left.text, "left: alpha\nbeta\nright\n")
        XCTAssertEqual(try right.text, try left.text)

        let historyCount = left.historyCount
        try left.merge(right)
        XCTAssertEqual(try left.text, try right.text)
        XCTAssertEqual(left.historyCount, historyCount)
    }

    func testReloadedReplicasMergeAndConverge() throws {
        let base = try SpikeNoteDocument(noteID: noteID, text: "one two")
        let left = try base.fork()
        let right = try base.fork()
        try left.replaceUTF16(
            range: NSRange(location: 0, length: 3),
            with: "ONE"
        )
        try right.replaceUTF16(
            range: NSRange(location: 4, length: 3),
            with: "TWO"
        )

        let reloadedLeft = try SpikeNoteDocument(
            serializedData: left.serializedData()
        )
        let reloadedRight = try SpikeNoteDocument(
            serializedData: right.serializedData()
        )
        XCTAssertNotEqual(reloadedLeft.actorID, reloadedRight.actorID)

        try reloadedLeft.merge(reloadedRight)
        try reloadedRight.merge(reloadedLeft)

        XCTAssertEqual(try reloadedLeft.text, "ONE TWO")
        XCTAssertEqual(try reloadedRight.text, try reloadedLeft.text)
        XCTAssertEqual(reloadedLeft.noteID, noteID)
        XCTAssertEqual(reloadedRight.noteID, noteID)
    }

    func testSamePositionInsertionsHaveStableConvergentOrder() throws {
        let base = try SpikeNoteDocument(noteID: noteID, text: "ab")
        let left = try base.fork()
        let right = try base.fork()

        try left.replaceUTF16(
            range: NSRange(location: 1, length: 0),
            with: "L"
        )
        try right.replaceUTF16(
            range: NSRange(location: 1, length: 0),
            with: "R"
        )
        try left.merge(right)
        try right.merge(left)

        let merged = try left.text
        XCTAssertEqual(try right.text, merged)
        XCTAssertTrue(merged == "aLRb" || merged == "aRLb")
    }

    func testEditorSnapshotsRepresentTypingUndoAndRedo() throws {
        let note = try SpikeNoteDocument(noteID: noteID, text: "hello")

        try note.replaceAll(with: "hello!")
        XCTAssertEqual(try note.text, "hello!")

        try note.replaceAll(with: "hello")
        XCTAssertEqual(try note.text, "hello")

        try note.replaceAll(with: "hello!")
        XCTAssertEqual(try note.text, "hello!")
        XCTAssertFalse(note.serializedData().isEmpty)
    }

    func testRepresentativeSerializationCost() throws {
        let initial = (0 ..< 1_000).map { index in
            "# Heading \(index)\n\nCafé 👋🏽 and `code` in note \(index).\n\n"
        }.joined()
        let note = try SpikeNoteDocument(noteID: noteID, text: initial)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AutomergeMetric-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = KnownGoodFileStore(directory: directory)
        try store.write(note.serializedData())

        var editDuration = Duration.zero
        var serializationDuration = Duration.zero
        var storageWriteDuration = Duration.zero
        var data = Data()
        for autosave in 0 ..< 25 {
            let editStart = ContinuousClock.now
            for offset in 0 ..< 10 {
                let index = autosave * 10 + offset
                let length = (try note.text as NSString).length
                try note.replaceUTF16(
                    range: NSRange(location: length, length: 0),
                    with: "edit \(index)\n"
                )
            }
            editDuration += editStart.duration(to: .now)

            let saveStart = ContinuousClock.now
            data = note.serializedData()
            serializationDuration += saveStart.duration(to: .now)

            let storageStart = ContinuousClock.now
            try store.write(data)
            storageWriteDuration += storageStart.duration(to: .now)
        }

        print(
            "AUTOMERGE_METRIC sourceBytes=\(initial.utf8.count) "
                + "savedBytes=\(data.count) "
                + "edits=250 autosaves=25 "
                + "editDuration=\(editDuration) "
                + "serializationDuration=\(serializationDuration) "
                + "storageWriteDuration=\(storageWriteDuration)"
        )
        XCTAssertFalse(data.isEmpty)
        XCTAssertEqual(
            try SpikeNoteDocument(serializedData: data).text,
            try note.text
        )
    }

    private func rawDocument(schemaVersion: ScalarValue?) throws -> Data {
        let document = Document(textEncoding: .unicodeScalar)
        try document.put(
            obj: .ROOT,
            key: "noteID",
            value: .String(noteID.uuidString)
        )
        if let schemaVersion {
            try document.put(
                obj: .ROOT,
                key: "schemaVersion",
                value: schemaVersion
            )
        }
        _ = try document.putObject(obj: .ROOT, key: "text", ty: .Text)
        return document.save()
    }
}
