import Automerge
import Foundation
import XCTest

@testable import AutomergeSpike

final class KnownGoodFileStoreTests: XCTestCase {
    private enum InjectedFailure: Error {
        case stop
    }

    private let noteID = UUID(
        uuidString: "9C86E52A-7037-4107-B7AA-148E3308A52D"
    )!

    func testSuccessfulReplacementRetainsPreviousDocument() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = KnownGoodFileStore(directory: directory)

        let original = try SpikeNoteDocument(noteID: noteID, text: "old")
        try store.write(original.serializedData())
        let originalHeads = original.headsSnapshot

        let edited = try document(at: store.currentURL)
        try edited.replaceAll(with: "new 👨‍👩‍👧‍👦 e\u{301}")
        try store.write(edited.serializedData())

        let current = try document(at: store.currentURL)
        let previous = try document(at: store.previousURL)
        XCTAssertEqual(try current.text, "new 👨‍👩‍👧‍👦 e\u{301}")
        XCTAssertEqual(try text(at: store.previousURL), "old")
        XCTAssertEqual(previous.headsSnapshot, originalHeads)
        XCTAssertTrue(originalHeads.isSubset(of: current.historyHashes))
        XCTAssertGreaterThan(current.historyCount, previous.historyCount)
        XCTAssertEqual(
            Array(try current.text.utf8),
            Array("new 👨‍👩‍👧‍👦 e\u{301}".utf8)
        )
    }

    func testInjectedFailuresLeaveRecoverableDocument() throws {
        for stage in FileWriteStage.allCases {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = KnownGoodFileStore(directory: directory)
            let original = try SpikeNoteDocument(noteID: noteID, text: "old")
            try store.write(original.serializedData())
            let edited = try document(at: store.currentURL)
            try edited.replaceAll(with: "new")

            XCTAssertThrowsError(
                try store.write(edited.serializedData()) {
                    reachedStage in
                    if reachedStage == stage {
                        throw InjectedFailure.stop
                    }
                }
            )

            let expectedCurrent = stage == .tempSynced
                || stage == .previousReplaced ? "old" : "new"
            XCTAssertEqual(try text(at: store.currentURL), expectedCurrent)
            if stage == .tempSynced {
                XCTAssertFalse(
                    FileManager.default.fileExists(
                        atPath: store.previousURL.path
                    )
                )
            } else {
                XCTAssertEqual(try text(at: store.previousURL), "old")
            }
        }
    }

    func testRecoveryFallsBackToPreviousKnownGoodDocument() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = KnownGoodFileStore(directory: directory)
        try store.write(try documentData(text: "old"))
        let edited = try document(at: store.currentURL)
        try edited.replaceAll(with: "new")
        try store.write(edited.serializedData())
        try Data("damaged".utf8).write(to: store.currentURL)

        let recovered = store.recover()
        guard case let .previous(data, currentFailure) = recovered else {
            return XCTFail("Expected the previous document")
        }
        XCTAssertEqual(currentFailure, .corrupt)
        XCTAssertEqual(try SpikeNoteDocument(serializedData: data).text, "old")
    }

    func testInvalidCurrentDoesNotReplacePreviousKnownGoodDocument() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = KnownGoodFileStore(directory: directory)
        try store.write(try documentData(text: "old"))
        let edited = try document(at: store.currentURL)
        try edited.replaceAll(with: "new")
        try store.write(edited.serializedData())
        try Data("damaged".utf8).write(to: store.currentURL)

        let next = try document(at: store.previousURL)
        try next.replaceAll(with: "next")
        XCTAssertThrowsError(try store.write(next.serializedData())) {
            error in
            XCTAssertEqual(
                error as? KnownGoodFileStoreError,
                .invalidCurrentDocument
            )
        }
        XCTAssertEqual(try text(at: store.previousURL), "old")
    }

    func testDifferentNoteIdentityCannotReplaceCurrentDocument() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = KnownGoodFileStore(directory: directory)
        try store.write(try documentData(text: "old"))
        let other = try SpikeNoteDocument(text: "other")

        XCTAssertThrowsError(try store.write(other.serializedData())) { error in
            XCTAssertEqual(
                error as? KnownGoodFileStoreError,
                .noteIdentityMismatch
            )
        }
        XCTAssertEqual(try text(at: store.currentURL), "old")
    }

    func testSameUUIDWithoutSharedHistoryCannotReplaceCurrentDocument() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = KnownGoodFileStore(directory: directory)
        try store.write(try documentData(text: "old"))
        let unrelated = try SpikeNoteDocument(noteID: noteID, text: "new")

        XCTAssertThrowsError(try store.write(unrelated.serializedData())) {
            error in
            XCTAssertEqual(
                error as? KnownGoodFileStoreError,
                .disconnectedHistory
            )
        }
        XCTAssertEqual(try text(at: store.currentURL), "old")
    }

    func testRecoveryDistinguishesAbsentCorruptAndUnreadableFiles() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = KnownGoodFileStore(directory: directory)

        XCTAssertEqual(store.recover(), .absent)

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data("damaged".utf8).write(to: store.currentURL)
        XCTAssertEqual(
            store.recover(),
            .unrecoverable(current: .corrupt, previous: nil)
        )

        try FileManager.default.removeItem(at: store.currentURL)
        try FileManager.default.createDirectory(
            at: store.currentURL,
            withIntermediateDirectories: false
        )
        XCTAssertEqual(
            store.recover(),
            .unrecoverable(current: .unreadable, previous: nil)
        )
    }

    func testUnsupportedCurrentDoesNotOfferOlderPreviousFile() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = KnownGoodFileStore(directory: directory)
        try store.write(try documentData(text: "old"))
        let edited = try document(at: store.currentURL)
        try edited.replaceAll(with: "new")
        try store.write(edited.serializedData())
        try unsupportedSchemaData().write(to: store.currentURL)

        XCTAssertEqual(store.recover(), .incompatibleCurrent)
        XCTAssertEqual(try text(at: store.previousURL), "old")
    }

    func testWrongTypedSchemaFallsBackToPreviousDocument() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = KnownGoodFileStore(directory: directory)
        try store.write(try documentData(text: "old"))
        let edited = try document(at: store.currentURL)
        try edited.replaceAll(with: "new")
        try store.write(edited.serializedData())
        try schemaData(.String("1")).write(to: store.currentURL)

        guard case let .previous(data, currentFailure) = store.recover() else {
            return XCTFail("Expected fallback to the previous document")
        }
        XCTAssertEqual(currentFailure, .corrupt)
        XCTAssertEqual(try SpikeNoteDocument(serializedData: data).text, "old")
    }

    private func documentData(text: String) throws -> Data {
        try SpikeNoteDocument(noteID: noteID, text: text).serializedData()
    }

    private func unsupportedSchemaData() throws -> Data {
        try schemaData(.Uint(2))
    }

    private func schemaData(_ schemaVersion: ScalarValue) throws -> Data {
        let document = Document(textEncoding: .unicodeScalar)
        try document.put(
            obj: .ROOT,
            key: "noteID",
            value: .String(noteID.uuidString)
        )
        try document.put(
            obj: .ROOT,
            key: "schemaVersion",
            value: schemaVersion
        )
        _ = try document.putObject(obj: .ROOT, key: "text", ty: .Text)
        return document.save()
    }

    private func text(at url: URL) throws -> String {
        try document(at: url).text
    }

    private func document(at url: URL) throws -> SpikeNoteDocument {
        try SpikeNoteDocument(serializedData: Data(contentsOf: url))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "AutomergeSpike-\(UUID().uuidString)",
            isDirectory: true
        )
    }
}
