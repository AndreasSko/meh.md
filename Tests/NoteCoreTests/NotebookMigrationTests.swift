import Foundation
import XCTest

@testable import NoteCore

final class NotebookMigrationTests: XCTestCase {
    private enum Stop: Error { case now }

    func testMigrationPreservesExactNoteBytesAndLeavesLegacyUntouched() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyURL = root.appending(path: "legacy")
        let legacy = NoteFileStorage(directory: legacyURL)
        let note = try NoteDocument(text: "# Original\r\n\r\ne\u{301} 👋🏽\n")
        try await legacy.save(note.snapshot())
        try note.replaceAll(with: try note.text + "later\n")
        try await legacy.save(note.snapshot())
        let original = try Data(contentsOf: legacy.currentURL)
        let previous = try Data(contentsOf: legacy.previousURL)
        let migration = NotebookMigration(directory: root.appending(path: "notebook"))
        let result = try await migration.migrateLegacyNote(from: legacyURL)
        let catalog = try NotebookCatalogDocument(snapshot: result)
        XCTAssertEqual(try catalog.items().map(\.id), [note.noteID])
        XCTAssertEqual(
            try catalog.legacyMigration(),
            .note(noteID: note.noteID, heads: note.heads)
        )
        XCTAssertEqual(
            try Data(contentsOf: migration.noteStorage(for: note.noteID).currentURL), original)
        XCTAssertEqual(try Data(contentsOf: legacy.currentURL), original)
        XCTAssertEqual(try Data(contentsOf: legacy.previousURL), previous)
    }

    func testEveryInterruptedStageResumesWithSameCatalogAndOneNote() async throws {
        for stage in NotebookMigrationStage.allCases {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let legacyURL = root.appending(path: "legacy")
            let directory = root.appending(path: "notebook")
            let note = try NoteDocument(text: "Keep this")
            try await NoteFileStorage(directory: legacyURL).save(note.snapshot())
            do {
                _ = try await NotebookMigration(directory: directory).migrateLegacyNote(
                    from: legacyURL
                ) {
                    if $0 == stage { throw Stop.now }
                }
                XCTFail("Expected interruption")
            } catch Stop.now {}
            guard
                case .current(let before) = await NotebookCatalogStorage(directory: directory)
                    .load()
            else {
                return XCTFail("Catalog identity must already be durable")
            }
            let result = try await NotebookMigration(directory: directory).migrateLegacyNote(
                from: legacyURL)
            XCTAssertEqual(result.notebookID, before.notebookID)
            let catalog = try NotebookCatalogDocument(snapshot: result)
            XCTAssertEqual(try catalog.items().map(\.id), [note.noteID])
            XCTAssertTrue(before.heads.isSubset(of: catalog.historyHeads))
        }
    }

    func testCompletedMigrationDoesNotDependOnOldFilesOrOverwriteNewEdits() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyURL = root.appending(path: "legacy")
        let migration = NotebookMigration(directory: root.appending(path: "notebook"))
        let note = try NoteDocument(text: "old")
        try await NoteFileStorage(directory: legacyURL).save(note.snapshot())
        let first = try await migration.migrateLegacyNote(from: legacyURL)
        try note.replaceAll(with: "New notebook edit")
        let destination = migration.noteStorage(for: note.noteID)
        try await destination.save(note.snapshot())
        try FileManager.default.removeItem(at: legacyURL)
        let second = try await migration.migrateLegacyNote(from: legacyURL)
        XCTAssertEqual(first, second)
        let saved = try NoteDocument(serializedData: Data(contentsOf: destination.currentURL))
        XCTAssertEqual(try saved.text, "New notebook edit")
    }

    func testMissingCompletedDestinationNeverRecreatesOldNote() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyURL = root.appending(path: "legacy")
        let migration = NotebookMigration(directory: root.appending(path: "notebook"))
        let note = try NoteDocument(text: "old")
        try await NoteFileStorage(directory: legacyURL).save(note.snapshot())
        _ = try await migration.migrateLegacyNote(from: legacyURL)
        let destination = migration.noteStorage(for: note.noteID)
        try FileManager.default.removeItem(at: destination.currentURL)
        do {
            _ = try await migration.migrateLegacyNote(from: legacyURL)
            XCTFail("Missing data must require attention")
        } catch {
            XCTAssertEqual(error as? NotebookMigrationError, .missingMigratedNote)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.currentURL.path))
    }

    func testEmptyLegacyCreatesAnEmptyNotebookAndStableReceipt() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let migration = NotebookMigration(directory: root.appending(path: "notebook"))
        let legacyURL = root.appending(path: "legacy")
        let first = try await migration.migrateLegacyNote(from: legacyURL)
        XCTAssertEqual(try NotebookCatalogDocument(snapshot: first).items(), [])
        XCTAssertEqual(try NotebookCatalogDocument(snapshot: first).legacyMigration(), .empty)
        let second = try await migration.migrateLegacyNote(from: legacyURL)
        XCTAssertEqual(first, second)
    }

    func testCorruptLegacyBlocksBeforeCreatingCatalog() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyURL = root.appending(path: "legacy")
        try FileManager.default.createDirectory(at: legacyURL, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: legacyURL.appending(path: "note.automerge"))
        let directory = root.appending(path: "notebook")
        do {
            _ = try await NotebookMigration(directory: directory).migrateLegacyNote(from: legacyURL)
            XCTFail("Corrupt source cannot become an empty notebook")
        } catch {
            XCTAssertEqual(error as? NotebookMigrationError, .legacyNoteUnavailable)
        }
        let catalog = await NotebookCatalogStorage(directory: directory).load()
        XCTAssertEqual(catalog, .firstLaunch)
    }

    func testRetryMergesLegacyEditsMadeAfterInterruptedCopy() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyURL = root.appending(path: "legacy")
        let directory = root.appending(path: "notebook")
        let migration = NotebookMigration(directory: directory)
        let original = try NoteDocument(text: "one two")
        let legacy = NoteFileStorage(directory: legacyURL)
        try await legacy.save(original.snapshot())
        do {
            _ = try await migration.migrateLegacyNote(from: legacyURL) {
                if $0 == .noteSaved { throw Stop.now }
            }
            XCTFail("Expected interruption")
        } catch Stop.now {}
        let left = try original.fork()
        let right = try original.fork()
        try left.replaceUTF16(range: NSRange(location: 0, length: 3), with: "ONE")
        try right.replaceUTF16(range: NSRange(location: 4, length: 3), with: "TWO")
        try await legacy.save(left.snapshot())
        let destination = migration.noteStorage(for: original.noteID)
        try await destination.save(right.snapshot())
        _ = try await migration.migrateLegacyNote(from: legacyURL)
        let merged = try NoteDocument(serializedData: Data(contentsOf: destination.currentURL))
        XCTAssertEqual(try merged.text, "ONE TWO")
        XCTAssertTrue(left.heads.isSubset(of: merged.historyHeads))
        XCTAssertTrue(right.heads.isSubset(of: merged.historyHeads))
    }

    func testMissingSourceAfterCatalogCheckpointCannotBecomeEmpty()
        async throws
    {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyURL = root.appending(path: "legacy")
        let directory = root.appending(path: "notebook")
        let note = try NoteDocument(text: "Keep this")
        let initialHeads = note.heads
        let legacy = NoteFileStorage(directory: legacyURL)
        try await legacy.save(note.snapshot())

        do {
            _ = try await NotebookMigration(
                directory: directory
            ).migrateLegacyNote(from: legacyURL) {
                if $0 == .catalogCreated { throw Stop.now }
            }
            XCTFail("Expected interruption")
        } catch Stop.now {}
        try FileManager.default.removeItem(at: legacy.currentURL)

        do {
            _ = try await NotebookMigration(
                directory: directory
            ).migrateLegacyNote(from: legacyURL)
            XCTFail("Missing source and destination must block")
        } catch {
            XCTAssertEqual(
                error as? NotebookMigrationError,
                .missingMigratedNote
            )
        }
        guard
            case .current(let snapshot) = await NotebookCatalogStorage(
                directory: directory
            ).load()
        else {
            return XCTFail("Expected the pending catalog")
        }
        let catalog = try NotebookCatalogDocument(snapshot: snapshot)
        XCTAssertEqual(
            try catalog.legacyMigration(),
            .copying(noteID: note.noteID, heads: initialHeads)
        )
        XCTAssertEqual(try catalog.items(), [])
    }

    func testMissingSourceAfterCopyCompletesFromDestination() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyURL = root.appending(path: "legacy")
        let directory = root.appending(path: "notebook")
        let note = try NoteDocument(text: "Keep this")
        let initialHeads = note.heads
        try await NoteFileStorage(directory: legacyURL).save(note.snapshot())

        do {
            _ = try await NotebookMigration(
                directory: directory
            ).migrateLegacyNote(from: legacyURL) {
                if $0 == .noteSaved { throw Stop.now }
            }
            XCTFail("Expected interruption")
        } catch Stop.now {}
        try FileManager.default.removeItem(at: legacyURL)

        let migration = NotebookMigration(directory: directory)
        let result = try await migration.migrateLegacyNote(from: legacyURL)
        let catalog = try NotebookCatalogDocument(snapshot: result)
        XCTAssertEqual(
            try catalog.legacyMigration(),
            .note(noteID: note.noteID, heads: initialHeads)
        )
        let saved = try NoteDocument(
            serializedData: Data(
                contentsOf: migration.noteStorage(for: note.noteID).currentURL
            )
        )
        XCTAssertEqual(try saved.text, "Keep this")
    }

    func testRetryRejectsReplacementSourceIdentity() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyURL = root.appending(path: "legacy")
        let directory = root.appending(path: "notebook")
        let legacy = NoteFileStorage(directory: legacyURL)
        try await legacy.save(try NoteDocument(text: "Original").snapshot())
        do {
            _ = try await NotebookMigration(
                directory: directory
            ).migrateLegacyNote(from: legacyURL) {
                if $0 == .catalogCreated { throw Stop.now }
            }
            XCTFail("Expected interruption")
        } catch Stop.now {}

        let replacement = try NoteDocument(text: "Replacement")
        try replacement.snapshot().data.write(to: legacy.currentURL)
        do {
            _ = try await NotebookMigration(
                directory: directory
            ).migrateLegacyNote(from: legacyURL)
            XCTFail("A replacement identity must be rejected")
        } catch {
            XCTAssertEqual(
                error as? NotebookMigrationError,
                .identityConflict
            )
        }
    }

    func testRetryRejectsDisconnectedSourceWithSameIdentity() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyURL = root.appending(path: "legacy")
        let directory = root.appending(path: "notebook")
        let original = try NoteDocument(text: "Original")
        let legacy = NoteFileStorage(directory: legacyURL)
        try await legacy.save(original.snapshot())
        do {
            _ = try await NotebookMigration(
                directory: directory
            ).migrateLegacyNote(from: legacyURL) {
                if $0 == .catalogCreated { throw Stop.now }
            }
            XCTFail("Expected interruption")
        } catch Stop.now {}

        let disconnected = try NoteDocument(
            noteID: original.noteID,
            text: "Unrelated"
        )
        try disconnected.snapshot().data.write(to: legacy.currentURL)
        do {
            _ = try await NotebookMigration(
                directory: directory
            ).migrateLegacyNote(from: legacyURL)
            XCTFail("Disconnected history must be rejected")
        } catch {
            XCTAssertEqual(
                error as? NotebookMigrationError,
                .identityConflict
            )
        }
    }

    func testCompletedMigrationSurfacesDestinationRecovery() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyURL = root.appending(path: "legacy")
        let directory = root.appending(path: "notebook")
        let note = try NoteDocument(text: "Original")
        try await NoteFileStorage(directory: legacyURL).save(note.snapshot())
        let migration = NotebookMigration(directory: directory)
        _ = try await migration.migrateLegacyNote(from: legacyURL)

        let destination = migration.noteStorage(for: note.noteID)
        let edited = try NoteDocument(
            serializedData: Data(contentsOf: destination.currentURL)
        )
        try edited.replaceAll(with: "Edited")
        try await destination.save(edited.snapshot())
        try Data("damaged".utf8).write(to: destination.currentURL)

        do {
            _ = try await migration.migrateLegacyNote(from: legacyURL)
            XCTFail("Destination recovery must remain explicit")
        } catch {
            XCTAssertEqual(
                error as? NotebookMigrationError,
                .destinationNoteNeedsRecovery
            )
        }

        let recovered = try await migration.recoverMigratedNoteFromPrevious()
        XCTAssertEqual(try NoteDocument(snapshot: recovered).text, "Original")
        _ = try await migration.migrateLegacyNote(from: legacyURL)
        let quarantines = try FileManager.default.contentsOfDirectory(
            at: destination.currentURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("note.quarantine-") }
        XCTAssertEqual(quarantines.count, 1)
        XCTAssertEqual(try Data(contentsOf: quarantines[0]), Data("damaged".utf8))
    }

    func testLegacySourceRecoveryIsExplicitAndMigrationResumes() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyURL = root.appending(path: "legacy")
        let storage = NoteFileStorage(directory: legacyURL)
        let note = try NoteDocument(text: "Previous")
        try await storage.save(note.snapshot())
        try note.replaceAll(with: "Damaged version")
        try await storage.save(note.snapshot())
        try Data("damaged".utf8).write(to: storage.currentURL)
        let migration = NotebookMigration(
            directory: root.appending(path: "notebook")
        )

        let recovered = try await migration.recoverLegacyNoteFromPrevious(
            from: legacyURL
        )
        XCTAssertEqual(try NoteDocument(snapshot: recovered).text, "Previous")
        let catalog = try await migration.migrateLegacyNote(from: legacyURL)
        XCTAssertEqual(
            try NotebookCatalogDocument(snapshot: catalog).items().map(\.id),
            [note.noteID]
        )
    }

    func testDestinationRecoveryValidatesPreviousBeforeMutation() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyURL = root.appending(path: "legacy")
        let note = try NoteDocument(text: "Original")
        try await NoteFileStorage(directory: legacyURL).save(note.snapshot())
        let migration = NotebookMigration(
            directory: root.appending(path: "notebook")
        )
        _ = try await migration.migrateLegacyNote(from: legacyURL)
        let destination = migration.noteStorage(for: note.noteID)
        try note.replaceAll(with: "Newer")
        try await destination.save(note.snapshot())
        let replacement = try NoteDocument(text: "Wrong identity")
        try replacement.snapshot().data.write(to: destination.previousURL)
        let damaged = Data("damaged".utf8)
        try damaged.write(to: destination.currentURL)

        do {
            _ = try await migration.recoverMigratedNoteFromPrevious()
            XCTFail("A replacement previous note must not be restored")
        } catch {
            XCTAssertEqual(error as? NotebookMigrationError, .identityConflict)
        }
        XCTAssertEqual(try Data(contentsOf: destination.currentURL), damaged)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "NotebookMigration-\(UUID().uuidString)")
    }
}
