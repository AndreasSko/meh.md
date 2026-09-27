import Automerge
import Foundation
import XCTest

@testable import NoteCore

final class NoteFileReadReuseTests: XCTestCase {
    private let noteID = UUID(
        uuidString: "9C86E52A-7037-4107-B7AA-148E3308A52D"
    )!

    func testByteIdenticalAtomicReplacementStillLoadsCurrentSnapshot() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = NoteFileStorage(directory: directory)
        let expected = try NoteDocument(noteID: noteID, text: "same").snapshot()
        try await storage.save(expected)

        let initial = await storage.load(reusing: nil)
        guard case let .current(initialSnapshot) = initial.result,
              let token = initial.validated else {
            return XCTFail("Expected a validated current snapshot")
        }
        XCTAssertEqual(initialSnapshot, expected)

        // Atomic replacement changes the file identity while preserving its
        // contents; a token must be validated by bytes, not inode or mtime.
        try expected.data.write(to: storage.currentURL, options: .atomic)
        let repeated = await storage.load(reusing: token)
        guard case let .current(repeatedSnapshot) = repeated.result else {
            return XCTFail("Expected the replacement current file to load")
        }
        XCTAssertEqual(repeatedSnapshot, expected)
        XCTAssertNotNil(repeated.validated)
    }

    func testMissingCurrentStillRequiresRecoveryFromPrevious() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = NoteFileStorage(directory: directory)
        let old = try NoteDocument(noteID: noteID, text: "old").snapshot()
        try await storage.save(old)
        let edited = try NoteDocument(serializedData: old.data)
        try edited.replaceAll(with: "new")
        try await storage.save(edited.snapshot())

        let warmed = await storage.load(reusing: nil)
        guard case .current = warmed.result, let token = warmed.validated else {
            return XCTFail("Expected a validated current snapshot")
        }
        try FileManager.default.removeItem(at: storage.currentURL)

        let missing = await storage.load(reusing: token)
        guard case let .recoveryRequired(recovery) = missing.result else {
            return XCTFail("A missing current file must still require recovery")
        }
        XCTAssertEqual(recovery.currentFailure, .absent)
        XCTAssertEqual(recovery.previous, old)
        XCTAssertNil(missing.validated)
    }

    func testCorruptAndUnsupportedCurrentFilesUseNormalRecoveryPath() async throws {
        let replacements: [(Data, NoteFileFailure)] = [
            (Data("broken".utf8), .corrupt),
            (try futureSchemaData(), .unsupportedSchemaVersion),
        ]
        for (replacement, expectedFailure) in replacements {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let storage = NoteFileStorage(directory: directory)
            let old = try NoteDocument(noteID: noteID, text: "old").snapshot()
            try await storage.save(old)
            let edited = try NoteDocument(serializedData: old.data)
            try edited.replaceAll(with: "new")
            try await storage.save(edited.snapshot())

            let warmed = await storage.load(reusing: nil)
            guard case .current = warmed.result, let token = warmed.validated else {
                return XCTFail("Expected a validated current snapshot")
            }
            try replacement.write(to: storage.currentURL, options: .atomic)

            let changed = await storage.load(reusing: token)
            XCTAssertNil(changed.validated)
            if expectedFailure == .corrupt {
                guard case let .recoveryRequired(recovery) = changed.result else {
                    return XCTFail("Corrupt current bytes must offer recovery")
                }
                XCTAssertEqual(recovery.previous, old)
                XCTAssertEqual(recovery.currentFailure, expectedFailure)
            } else {
                guard case let .blocked(failure) = changed.result else {
                    return XCTFail("Unsupported schema must remain blocked")
                }
                XCTAssertEqual(
                    failure.current,
                    expectedFailure
                )
                XCTAssertEqual(failure.previous, .valid)
            }
        }
    }

    func testUnreadableCurrentPathCannotReuseAValidatedToken() async throws {
        let sourceDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }
        let source = NoteFileStorage(directory: sourceDirectory)
        try await source.save(
            try NoteDocument(noteID: noteID, text: "valid").snapshot()
        )
        let loaded = await source.load(reusing: nil)
        guard let token = loaded.validated else {
            return XCTFail("Expected a validated token")
        }

        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let blockedDirectory = root.appending(path: "blocked")
        try Data("parent is a file".utf8).write(to: blockedDirectory)
        let blocked = NoteFileStorage(directory: blockedDirectory)

        let result = await blocked.load(reusing: token)
        guard case let .blocked(failure) = result.result else {
            return XCTFail("An unreadable path must remain blocked")
        }
        XCTAssertEqual(failure.current, .unreadable)
        XCTAssertNil(result.validated)
    }

    @MainActor
    func testReplicaRejectsExternalNoteIdentityChangeAfterWarmScan() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        let noteID = try await replica.createNote(name: "Note.md", text: "original")

        _ = try await replica.records(includeUnlisted: true)
        let replacement = try NoteDocument(text: "external replacement").snapshot()
        try replacement.data.write(
            to: replica.noteStorage(noteID).currentURL,
            options: .atomic
        )

        do {
            _ = try await replica.records(includeUnlisted: true)
            XCTFail("A changed note identity must not reuse the cached snapshot")
        } catch {
            XCTAssertEqual(error as? SyncError, .identityConflict)
        }
    }

    @MainActor
    func testReplicaCheckpointSeesExternalRollbackAndMissingFilesAfterWarmScans()
        async throws
    {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        let noteID = try await replica.createNote(name: "Note.md", text: "old")
        let storage = replica.noteStorage(noteID)
        let old = try NoteDocument(serializedData: Data(contentsOf: storage.currentURL))
        try old.replaceAll(with: "new")
        try await storage.save(old.snapshot())

        let latestRecords = try await replica.records(includeUnlisted: true)
        let latestRecord = try XCTUnwrap(
            latestRecords.first { $0.documentKey == "note:\(noteID.uuidString)" }
        )
        let checkpoints = [latestRecord.documentKey: latestRecord.snapshot.heads]

        // This same-replica scan warmed the read cache with the newest file.
        // Replacing it with the retained previous bytes must force a history
        // failure even though those bytes were previously valid.
        try Data(contentsOf: storage.previousURL).write(
            to: storage.currentURL,
            options: .atomic
        )
        let hasLatestHistoryAfterRollback = try await replica.containsHistory(
            checkpoints,
            deleted: []
        )
        XCTAssertFalse(hasLatestHistoryAfterRollback)

        try FileManager.default.removeItem(at: storage.currentURL)
        try FileManager.default.removeItem(at: storage.previousURL)
        let hasLatestHistoryAfterRemoval = try await replica.containsHistory(
            checkpoints,
            deleted: []
        )
        XCTAssertFalse(hasLatestHistoryAfterRemoval)
    }

    private func futureSchemaData() throws -> Data {
        let document = Document(textEncoding: .unicodeScalar)
        try document.put(
            obj: .ROOT,
            key: "noteID",
            value: .String(noteID.uuidString)
        )
        try document.put(
            obj: .ROOT,
            key: "schemaVersion",
            value: .Uint(2)
        )
        _ = try document.putObject(obj: .ROOT, key: "text", ty: .Text)
        return document.save()
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "NoteFileReadReuseTests-\(UUID().uuidString)"
        )
    }
}
