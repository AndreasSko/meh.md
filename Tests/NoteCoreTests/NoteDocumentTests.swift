import Automerge
import Foundation
import XCTest

@testable import NoteCore

final class NoteDocumentTests: XCTestCase {
    private let noteID = UUID(
        uuidString: "9C86E52A-7037-4107-B7AA-148E3308A52D"
    )!

    func testSerializationPreservesHistoryIdentityAndUnicode() throws {
        let original = "# Café\n\ne\u{301} 👋🏽 👨‍👩‍👧‍👦\n"
        let note = try NoteDocument(noteID: noteID, text: original)
        let firstHeads = note.heads
        try note.replaceAll(with: original + "saved\n")

        let reloaded = try NoteDocument(snapshot: note.snapshot())

        XCTAssertEqual(reloaded.noteID, noteID)
        XCTAssertEqual(try reloaded.text, original + "saved\n")
        XCTAssertEqual(reloaded.heads, note.heads)
        XCTAssertTrue(firstHeads.isSubset(of: reloaded.historyHeads))
        XCTAssertGreaterThan(reloaded.historyCount, 1)
    }

    func testReloadedOfflineForkStillMerges() throws {
        let base = try NoteDocument(noteID: noteID, text: "one two")
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

        let savedLeft = try NoteDocument(snapshot: left.snapshot())
        try savedLeft.merge(right)

        XCTAssertEqual(try savedLeft.text, "ONE TWO")
        XCTAssertEqual(savedLeft.noteID, noteID)
    }

    func testExplicitMetadataRoundTripsAtMillisecondPrecision() throws {
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000.123_9)
        let modifiedAt = Date(timeIntervalSince1970: 1_710_000_000.987_9)
        let note = try NoteDocument(
            noteID: noteID,
            text: "body",
            metadata: NoteMetadata(
                createdAt: createdAt,
                modifiedAt: modifiedAt
            )
        )

        XCTAssertEqual(
            try note.snapshot().metadata,
            NoteMetadata(
                createdAt: createdAt.noteTimestamp,
                modifiedAt: modifiedAt.noteTimestamp
            )
        )
    }

    func testTimestampNormalizationIsIdempotentAcrossJSONAndAutomerge()
        throws
    {
        let source = Date(timeIntervalSince1970: 1_789_383_817.456_789)
        let normalized = try XCTUnwrap(source.noteTimestamp)
        let encoded = try JSONEncoder().encode(
            NoteMetadata(createdAt: normalized, modifiedAt: normalized)
        )
        let decoded = try JSONDecoder().decode(
            NoteMetadata.self,
            from: encoded
        )
        let note = try NoteDocument(metadata: decoded)

        XCTAssertEqual(normalized.noteTimestamp, normalized)
        XCTAssertEqual(try note.metadata.createdAt, normalized)
        XCTAssertEqual(try note.metadata.modifiedAt, normalized)
    }

    func testLegacyDocumentKeepsUnknownDates() throws {
        let snapshot = try rawSnapshot()

        XCTAssertEqual(try snapshot.metadata, .unknown)
        let reopened = try NoteDocument(snapshot: snapshot)
        XCTAssertEqual(try reopened.metadata, .unknown)
    }

    func testInvalidTimestampTypesAreRejected() throws {
        let data = try rawData { document in
            try document.put(
                obj: .ROOT,
                key: "modifiedAt",
                value: .String("not a timestamp")
            )
        }

        XCTAssertThrowsError(try NoteDocument(serializedData: data)) {
            XCTAssertEqual(
                $0 as? NoteDocumentError,
                .invalidModifiedAt
            )
        }
        XCTAssertThrowsError(
            try NoteDocument(
                metadata: NoteMetadata(
                    createdAt: Date(timeIntervalSince1970: .infinity),
                    modifiedAt: nil
                )
            )
        ) {
            XCTAssertEqual($0 as? NoteDocumentError, .invalidCreatedAt)
        }
    }

    func testConcurrentModifiedDateUsesMaximumWithoutMergeTime() throws {
        let createdAt = Date(timeIntervalSince1970: 100)
        let initialModifiedAt = Date(timeIntervalSince1970: 200)
        let earlier = Date(timeIntervalSince1970: 300)
        let later = Date(timeIntervalSince1970: 400)
        let base = try NoteDocument(
            noteID: noteID,
            text: "one two",
            metadata: NoteMetadata(
                createdAt: createdAt,
                modifiedAt: initialModifiedAt
            )
        )
        let left = try base.fork()
        let right = try base.fork()
        try left.replaceUTF16(
            range: NSRange(location: 0, length: 3),
            with: "ONE",
            at: earlier
        )
        try right.replaceUTF16(
            range: NSRange(location: 4, length: 3),
            with: "TWO",
            at: later
        )

        try left.merge(right)

        XCTAssertEqual(try left.text, "ONE TWO")
        XCTAssertEqual(try left.metadata.createdAt, createdAt)
        XCTAssertEqual(try left.metadata.modifiedAt, later)
    }

    func testExactNoOpsDoNotChangeHeadsOrModifiedDate() throws {
        let modifiedAt = Date(timeIntervalSince1970: 200)
        let note = try NoteDocument(
            text: "same",
            metadata: NoteMetadata(
                createdAt: Date(timeIntervalSince1970: 100),
                modifiedAt: modifiedAt
            )
        )
        let heads = note.heads

        try note.replaceAll(
            with: "same",
            at: Date(timeIntervalSince1970: 300)
        )
        try note.replaceUTF16(
            range: NSRange(location: 0, length: 4),
            with: "same",
            at: Date(timeIntervalSince1970: 400)
        )

        XCTAssertEqual(note.heads, heads)
        XCTAssertEqual(try note.metadata.modifiedAt, modifiedAt)
    }

    func testCanonicallyEquivalentByteEditIsNotANoOp() throws {
        let composed = "é"
        let decomposed = "e\u{301}"
        let note = try NoteDocument(
            text: composed,
            metadata: .now(Date(timeIntervalSince1970: 100))
        )
        let heads = note.heads
        let changedAt = Date(timeIntervalSince1970: 200)

        try note.replaceUTF16(
            range: NSRange(location: 0, length: composed.utf16.count),
            with: decomposed,
            at: changedAt
        )

        XCTAssertEqual(Array((try note.text).utf8), Array(decomposed.utf8))
        XCTAssertNotEqual(note.heads, heads)
        XCTAssertEqual(try note.metadata.modifiedAt, changedAt)
    }

    private func rawSnapshot() throws -> NoteSnapshot {
        let data = try rawData { _ in }
        let note = try NoteDocument(serializedData: data)
        return note.snapshot()
    }

    private func rawData(
        configure: (Document) throws -> Void
    ) throws -> Data {
        let document = Document(textEncoding: .unicodeScalar)
        try document.put(
            obj: .ROOT,
            key: "noteID",
            value: .String(noteID.uuidString)
        )
        try document.put(
            obj: .ROOT,
            key: "schemaVersion",
            value: .Uint(1)
        )
        _ = try document.putObject(
            obj: .ROOT,
            key: "text",
            ty: .Text
        )
        try configure(document)
        return document.save()
    }
}
