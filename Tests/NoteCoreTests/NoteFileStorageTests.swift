import Automerge
import Foundation
import XCTest

@testable import NoteCore

final class NoteFileStorageTests: XCTestCase {
    private enum InjectedFailure: Error {
        case stop
    }

    private let noteID = UUID(
        uuidString: "9C86E52A-7037-4107-B7AA-148E3308A52D"
    )!

    func testReplacementKeepsPreviousAndContinuousHistory() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NoteFileStorage(directory: directory)
        let original = try NoteDocument(noteID: noteID, text: "old")
        let originalHeads = original.heads
        try await store.save(original.snapshot())

        let edited = try NoteDocument(
            serializedData: Data(contentsOf: store.currentURL)
        )
        try edited.replaceAll(with: "new 👨‍👩‍👧‍👦 e\u{301}")
        try await store.save(edited.snapshot())

        let current = try document(at: store.currentURL)
        let previous = try document(at: store.previousURL)
        XCTAssertEqual(try current.text, "new 👨‍👩‍👧‍👦 e\u{301}")
        XCTAssertEqual(try previous.text, "old")
        XCTAssertEqual(previous.heads, originalHeads)
        XCTAssertTrue(originalHeads.isSubset(of: current.historyHeads))
    }

    func testInterruptedWritesAlwaysLeaveRecoverableCurrent() async throws {
        for stage in NoteFileWriteStage.allCases {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = NoteFileStorage(directory: directory)
            try await store.save(
                try NoteDocument(noteID: noteID, text: "old").snapshot()
            )
            let edited = try document(at: store.currentURL)
            try edited.replaceAll(with: "new")

            do {
                try await store.write(edited.snapshot()) { reached in
                    if reached == stage { throw InjectedFailure.stop }
                }
                XCTFail("Expected the injected failure")
            } catch InjectedFailure.stop {
                // Expected interruption boundary.
            }

            let expected = stage == .temporarySynced
                || stage == .previousReplaced ? "old" : "new"
            XCTAssertEqual(try document(at: store.currentURL).text, expected)
        }
    }

    func testLoadDistinguishesFirstLaunchMissingCurrentAndDamage() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NoteFileStorage(directory: directory)
        let firstLoad = await store.load()
        XCTAssertEqual(firstLoad, .firstLaunch)

        try await store.save(
            try NoteDocument(noteID: noteID, text: "old").snapshot()
        )
        let edited = try document(at: store.currentURL)
        try edited.replaceAll(with: "new")
        try await store.save(edited.snapshot())
        try FileManager.default.removeItem(at: store.currentURL)

        guard case let .recoveryRequired(missing) = await store.load() else {
            return XCTFail("A missing current file must require recovery")
        }
        XCTAssertEqual(missing.currentFailure, .absent)

        try Data("damaged".utf8).write(to: store.currentURL)
        guard case let .recoveryRequired(damaged) = await store.load() else {
            return XCTFail("A damaged current file must offer recovery")
        }
        XCTAssertEqual(damaged.currentFailure, .corrupt)
    }

    func testRecoveryQuarantinesCurrentAndRetainsPrevious() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NoteFileStorage(directory: directory)
        try await store.save(
            try NoteDocument(noteID: noteID, text: "old").snapshot()
        )
        let edited = try document(at: store.currentURL)
        try edited.replaceAll(with: "new")
        try await store.save(edited.snapshot())
        let damaged = Data("damaged current bytes".utf8)
        try damaged.write(to: store.currentURL)

        guard case let .recoveryRequired(recovery) = await store.load() else {
            return XCTFail("Expected recovery")
        }
        let restored = try await store.recover(recovery)

        XCTAssertEqual(try NoteDocument(snapshot: restored).text, "old")
        XCTAssertEqual(try document(at: store.currentURL).text, "old")
        XCTAssertEqual(try document(at: store.previousURL).text, "old")

        let quarantines = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("note.quarantine-") }
        XCTAssertEqual(quarantines.count, 1)
        XCTAssertEqual(try Data(contentsOf: quarantines[0]), damaged)
    }

    func testFailedRecoveryRetainsSourcesAndCanRetry() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NoteFileStorage(directory: directory)
        try await store.save(
            try NoteDocument(noteID: noteID, text: "old").snapshot()
        )
        let edited = try document(at: store.currentURL)
        try edited.replaceAll(with: "new")
        try await store.save(edited.snapshot())
        let damaged = Data("damaged".utf8)
        try damaged.write(to: store.currentURL)
        guard case let .recoveryRequired(recovery) = await store.load() else {
            return XCTFail("Expected recovery")
        }

        do {
            _ = try await store.recover(recovery) { stage in
                if stage == .sourceRetained { throw InjectedFailure.stop }
            }
            XCTFail("Expected injected recovery failure")
        } catch InjectedFailure.stop {
            // The original current and previous sources must remain usable.
        }
        XCTAssertEqual(try Data(contentsOf: store.currentURL), damaged)
        XCTAssertEqual(try document(at: store.previousURL).text, "old")
        XCTAssertEqual(try quarantineURLs(in: directory).count, 1)

        let restored = try await store.recover(recovery)
        XCTAssertEqual(try NoteDocument(snapshot: restored).text, "old")
        XCTAssertEqual(try quarantineURLs(in: directory).count, 1)

        let retried = try await store.recover(recovery)
        XCTAssertEqual(try NoteDocument(snapshot: retried).text, "old")
        XCTAssertEqual(try quarantineURLs(in: directory).count, 1)
    }

    func testRecoveryRetriesAfterCurrentWasRestored() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NoteFileStorage(directory: directory)
        try await store.save(
            try NoteDocument(noteID: noteID, text: "old").snapshot()
        )
        let edited = try document(at: store.currentURL)
        try edited.replaceAll(with: "new")
        try await store.save(edited.snapshot())
        try Data("damaged".utf8).write(to: store.currentURL)
        guard case let .recoveryRequired(recovery) = await store.load() else {
            return XCTFail("Expected recovery")
        }

        do {
            _ = try await store.recover(recovery) { stage in
                if stage == .currentRestored { throw InjectedFailure.stop }
            }
            XCTFail("Expected injected recovery failure")
        } catch InjectedFailure.stop {
            // The replacement happened, but it was not acknowledged.
        }

        let restored = try await store.recover(recovery)
        XCTAssertEqual(try NoteDocument(snapshot: restored).text, "old")
    }

    func testUnreadableCurrentRecoveryCanRetryAfterQuarantine() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NoteFileStorage(directory: directory)
        try await store.save(
            try NoteDocument(noteID: noteID, text: "old").snapshot()
        )
        let edited = try document(at: store.currentURL)
        try edited.replaceAll(with: "new")
        try await store.save(edited.snapshot())
        try FileManager.default.removeItem(at: store.currentURL)
        try FileManager.default.createDirectory(
            at: store.currentURL,
            withIntermediateDirectories: false
        )
        guard case let .recoveryRequired(recovery) = await store.load() else {
            return XCTFail("Expected recovery")
        }

        do {
            _ = try await store.recover(recovery) { stage in
                if stage == .sourceRetained { throw InjectedFailure.stop }
            }
            XCTFail("Expected injected recovery failure")
        } catch InjectedFailure.stop {
            // The unreadable source has moved to quarantine.
        }

        let restored = try await store.recover(recovery)
        XCTAssertEqual(try NoteDocument(snapshot: restored).text, "old")
    }

    func testMissingCurrentRecoveryCanRetryAfterRestore() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NoteFileStorage(directory: directory)
        try await store.save(
            try NoteDocument(noteID: noteID, text: "old").snapshot()
        )
        let edited = try document(at: store.currentURL)
        try edited.replaceAll(with: "new")
        try await store.save(edited.snapshot())
        try FileManager.default.removeItem(at: store.currentURL)
        guard case let .recoveryRequired(recovery) = await store.load() else {
            return XCTFail("Expected recovery")
        }

        do {
            _ = try await store.recover(recovery) { stage in
                if stage == .currentRestored { throw InjectedFailure.stop }
            }
            XCTFail("Expected injected recovery failure")
        } catch InjectedFailure.stop {
            // The missing current has already been restored.
        }

        let restored = try await store.recover(recovery)
        XCTAssertEqual(try NoteDocument(snapshot: restored).text, "old")
    }

    func testRecoveryRefusesChangedCurrentFile() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NoteFileStorage(directory: directory)
        try await store.save(
            try NoteDocument(noteID: noteID, text: "old").snapshot()
        )
        let edited = try document(at: store.currentURL)
        try edited.replaceAll(with: "new")
        try await store.save(edited.snapshot())
        try Data("damaged".utf8).write(to: store.currentURL)
        guard case let .recoveryRequired(recovery) = await store.load() else {
            return XCTFail("Expected recovery")
        }
        try futureSchemaData().write(to: store.currentURL)

        do {
            _ = try await store.recover(recovery)
            XCTFail("Expected changed current to be refused")
        } catch let error as NoteFileStorageError {
            XCTAssertEqual(error, .recoverySourceChanged)
        }
    }

    func testExistingUnreadablePathIsNotFirstLaunch() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NoteFileStorage(directory: directory)
        try FileManager.default.createDirectory(
            at: store.currentURL,
            withIntermediateDirectories: true
        )

        let result = await store.load()
        XCTAssertEqual(
            result,
            .blocked(
                NoteLoadFailure(current: .unreadable, previous: .absent)
            )
        )
    }

    func testUnsupportedCurrentNeverDowngradesToPrevious() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NoteFileStorage(directory: directory)
        try await store.save(
            try NoteDocument(noteID: noteID, text: "old").snapshot()
        )
        let edited = try document(at: store.currentURL)
        try edited.replaceAll(with: "new")
        try await store.save(edited.snapshot())
        try futureSchemaData().write(to: store.currentURL)

        let result = await store.load()
        XCTAssertEqual(
            result,
            .blocked(
                NoteLoadFailure(
                    current: .unsupportedSchemaVersion,
                    previous: .valid
                )
            )
        )
        XCTAssertEqual(try document(at: store.previousURL).text, "old")

        try futureSchemaData(includeNoteID: false).write(
            to: store.currentURL
        )
        let missingFutureField = await store.load()
        guard case let .blocked(failure) = missingFutureField else {
            return XCTFail("A newer schema must remain incompatible")
        }
        XCTAssertEqual(failure.current, .unsupportedSchemaVersion)
    }

    func testSnapshotMetadataMustMatchSerializedDocument() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NoteFileStorage(directory: directory)
        let valid = try NoteDocument(noteID: noteID, text: "text").snapshot()
        let forged = NoteSnapshot(
            data: valid.data,
            heads: ["not-a-document-head"],
            noteID: valid.noteID
        )

        do {
            try await store.save(forged)
            XCTFail("Expected invalid snapshot metadata")
        } catch let error as NoteFileStorageError {
            XCTAssertEqual(error, .invalidIncomingDocument)
        }
    }

    private func futureSchemaData(includeNoteID: Bool = true) throws -> Data {
        let document = Document(textEncoding: .unicodeScalar)
        if includeNoteID {
            try document.put(
                obj: .ROOT,
                key: "noteID",
                value: .String(noteID.uuidString)
            )
        }
        try document.put(
            obj: .ROOT,
            key: "schemaVersion",
            value: .Uint(2)
        )
        _ = try document.putObject(obj: .ROOT, key: "text", ty: .Text)
        return document.save()
    }

    private func document(at url: URL) throws -> NoteDocument {
        try NoteDocument(serializedData: Data(contentsOf: url))
    }

    private func quarantineURLs(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("note.quarantine-") }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "NoteCoreTests-\(UUID().uuidString)",
            isDirectory: true
        )
    }
}
