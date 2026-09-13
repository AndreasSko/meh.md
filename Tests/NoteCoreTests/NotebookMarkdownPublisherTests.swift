import Foundation
import XCTest

@testable import NoteCore

final class NotebookMarkdownPublisherTests: XCTestCase {
    private enum Stop: Error { case now }

    func testPublishesNestedActiveNotesAsExactUTF8Markdown() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try NotebookCatalogDocument()
        let folder = try catalog.add(kind: .folder, name: "Projects")
        let note = try NoteDocument(text: "# Draft\n\nLiteral 👋\n")
        try catalog.add(
            id: note.noteID,
            kind: .note,
            name: "Draft",
            parentID: folder
        )

        try await NotebookMarkdownPublisher(directory: root).publish(
            catalog: catalog.snapshot(),
            placements: catalog.placements(),
            notes: [note.snapshot()]
        )

        XCTAssertEqual(
            try Data(
                contentsOf: root.appending(path: "Markdown/Projects/Draft.md")
            ),
            Data("# Draft\n\nLiteral 👋\n".utf8)
        )
    }

    func testPreservesMarkdownExtension() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try NotebookCatalogDocument()
        let note = try NoteDocument(text: "body")
        try catalog.add(
            id: note.noteID,
            kind: .note,
            name: "Long.markdown"
        )

        try await NotebookMarkdownPublisher(directory: root).publish(
            catalog: catalog.snapshot(),
            placements: catalog.placements(),
            notes: [note.snapshot()]
        )

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appending(path: "Markdown/Long.markdown").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appending(path: "Markdown/Long.markdown.md").path
            )
        )
    }

    func testFits253Through255ByteASCIIStemsBeforeAddingExtension()
        async throws
    {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try NotebookCatalogDocument()
        var notes: [NoteSnapshot] = []
        var expectedNames: [String] = []
        for (length, character) in [(253, "a"), (254, "b"), (255, "c")] {
            let note = try NoteDocument(text: "\(length)")
            try catalog.add(
                id: note.noteID,
                kind: .note,
                name: String(repeating: character, count: length)
            )
            notes.append(note.snapshot())
            expectedNames.append(
                String(repeating: character, count: 252) + ".md"
            )
        }

        try await NotebookMarkdownPublisher(directory: root).publish(
            catalog: catalog.snapshot(),
            placements: catalog.placements(),
            notes: notes
        )

        for name in expectedNames {
            XCTAssertEqual(name.utf8.count, 255)
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: root.appending(path: "Markdown/\(name)").path
                )
            )
        }
    }

    func testFitsMultibyteStemAtCharacterBoundary() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try NotebookCatalogDocument()
        let note = try NoteDocument(text: "unicode")
        let grapheme = "e\u{301}"
        let catalogName = String(repeating: "a", count: 250) + grapheme
        try catalog.add(
            id: note.noteID,
            kind: .note,
            name: catalogName
        )

        try await NotebookMarkdownPublisher(directory: root).publish(
            catalog: catalog.snapshot(),
            placements: catalog.placements(),
            notes: [note.snapshot()]
        )

        let publishedName = String(repeating: "a", count: 250) + ".md"
        XCTAssertEqual(catalogName.utf8.count, 253)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appending(
                    path: "Markdown/\(publishedName)"
                ).path
            )
        )
    }

    func testTruncationCollisionUsesStableIdentifierSuffix() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try NotebookCatalogDocument()
        let firstID = UUID(
            uuidString: "11111111-1111-1111-1111-111111111111"
        )!
        let secondID = UUID(
            uuidString: "22222222-2222-2222-2222-222222222222"
        )!
        let first = try NoteDocument(noteID: firstID, text: "first")
        let second = try NoteDocument(noteID: secondID, text: "second")
        let sharedStem = String(repeating: "é", count: 126)
        try catalog.add(
            id: firstID, kind: .note, name: sharedStem + "a"
        )
        try catalog.add(
            id: secondID, kind: .note, name: sharedStem + "b"
        )

        try await NotebookMarkdownPublisher(directory: root).publish(
            catalog: catalog.snapshot(),
            placements: catalog.placements(),
            notes: [first.snapshot(), second.snapshot()]
        )

        let baseName = sharedStem + ".md"
        let collisionName = NotebookName.collisionName(
            baseName, id: secondID
        )
        XCTAssertEqual(
            try String(
                contentsOf: root.appending(path: "Markdown/\(baseName)"),
                encoding: .utf8
            ),
            "first"
        )
        XCTAssertEqual(
            try String(
                contentsOf: root.appending(
                    path: "Markdown/\(collisionName)"
                ),
                encoding: .utf8
            ),
            "second"
        )
        XCTAssertLessThanOrEqual(collisionName.utf8.count, 255)
        XCTAssertTrue(collisionName.hasSuffix(" (22222222).md"))
    }

    func testUnchangedPublishDoesNotReplaceHierarchy() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try NotebookCatalogDocument()
        let note = try NoteDocument(text: "unchanged")
        try catalog.add(id: note.noteID, kind: .note, name: "Note.md")
        let publisher = NotebookMarkdownPublisher(directory: root)
        let snapshot = catalog.snapshot()
        let placements = try catalog.placements()
        let notes = [note.snapshot()]
        try await publisher.publish(
            catalog: snapshot,
            placements: placements,
            notes: notes
        )
        let generationURL = root.appending(
            path: "Markdown/.notebook-generation"
        )
        let generation = try Data(contentsOf: generationURL)
        var stages: [NotebookMarkdownPublishStage] = []

        try await publisher.publish(
            catalog: snapshot,
            placements: placements,
            notes: notes
        ) { stages.append($0) }

        XCTAssertTrue(stages.isEmpty)
        XCTAssertEqual(try Data(contentsOf: generationURL), generation)
    }

    func testChangedManagedFileIsRepairedInsteadOfTreatedAsNoOp()
        async throws
    {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try NotebookCatalogDocument()
        let note = try NoteDocument(text: "persisted")
        try catalog.add(id: note.noteID, kind: .note, name: "Note.md")
        let publisher = NotebookMarkdownPublisher(directory: root)
        let snapshot = catalog.snapshot()
        let placements = try catalog.placements()
        let notes = [note.snapshot()]
        try await publisher.publish(
            catalog: snapshot,
            placements: placements,
            notes: notes
        )
        let copyURL = root.appending(path: "Markdown/Note.md")
        let generationURL = root.appending(
            path: "Markdown/.notebook-generation"
        )
        let firstGeneration = try Data(contentsOf: generationURL)
        try Data("external".utf8).write(to: copyURL)

        try await publisher.publish(
            catalog: snapshot,
            placements: placements,
            notes: notes
        )

        XCTAssertEqual(try Data(contentsOf: copyURL), Data("persisted".utf8))
        XCTAssertNotEqual(
            try Data(contentsOf: generationURL),
            firstGeneration
        )
    }

    func testPublisherErrorsProvideUserFacingDescriptions() {
        let noteID = UUID()
        let errors: [NotebookMarkdownPublisherError] = [
            .destinationNotOwned,
            .notebookIdentityMismatch,
            .invalidCatalog,
            .missingNote(noteID),
            .invalidNote(noteID),
            .unsafeManagedContent
        ]

        for error in errors {
            XCTAssertFalse((error.errorDescription ?? "").isEmpty)
        }
    }

    func testRenameAndMoveReplaceOnlyManagedHierarchyAcrossRestart()
        async throws
    {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try NotebookCatalogDocument()
        let note = try NoteDocument(text: "body")
        try catalog.add(id: note.noteID, kind: .note, name: "Old.md")
        let publisher = NotebookMarkdownPublisher(directory: root)
        try await publisher.publish(
            catalog: catalog.snapshot(),
            placements: catalog.placements(),
            notes: [note.snapshot()]
        )
        let folder = try catalog.add(kind: .folder, name: "Archive")
        try catalog.rename(note.noteID, to: "New.md")
        try catalog.move(note.noteID, to: folder)

        try await NotebookMarkdownPublisher(directory: root).publish(
            catalog: catalog.snapshot(),
            placements: catalog.placements(),
            notes: [note.snapshot()]
        )

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appending(path: "Markdown/Old.md").path
            )
        )
        XCTAssertEqual(
            try String(
                contentsOf: root.appending(path: "Markdown/Archive/New.md"),
                encoding: .utf8
            ),
            "body"
        )
    }

    func testUnclaimedNonemptyDestinationIsNeverModified() async throws {
        let root = temporaryDirectory(create: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let unrelated = root.appending(path: "keep.txt")
        try Data("keep".utf8).write(to: unrelated)
        let catalog = try NotebookCatalogDocument()

        await assertPublisherError(.destinationNotOwned) {
            try await NotebookMarkdownPublisher(directory: root).publish(
                catalog: catalog.snapshot(),
                placements: catalog.placements(),
                notes: []
            )
        }
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("keep".utf8))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.path),
            ["keep.txt"]
        )
    }

    func testMissingNoteFailsBeforeReplacingExistingExport() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try NotebookCatalogDocument()
        let existing = try NoteDocument(text: "preserved")
        try catalog.add(
            id: existing.noteID,
            kind: .note,
            name: "Existing.md"
        )
        let publisher = NotebookMarkdownPublisher(directory: root)
        try await publisher.publish(
            catalog: catalog.snapshot(),
            placements: catalog.placements(),
            notes: [existing.snapshot()]
        )
        let missing = try catalog.add(kind: .note, name: "Missing.md")

        await assertPublisherError(.missingNote(missing)) {
            try await publisher.publish(
                catalog: catalog.snapshot(),
                placements: catalog.placements(),
                notes: [existing.snapshot()]
            )
        }
        XCTAssertEqual(
            try String(
                contentsOf: root.appending(path: "Markdown/Existing.md"),
                encoding: .utf8
            ),
            "preserved"
        )
    }

    func testUntrackedFileInsideManagedHierarchyIsPreservedAndBlocksUpdate()
        async throws
    {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try NotebookCatalogDocument()
        let publisher = NotebookMarkdownPublisher(directory: root)
        try await publisher.publish(
            catalog: catalog.snapshot(),
            placements: catalog.placements(),
            notes: []
        )
        let unrelated = root.appending(path: "Markdown/unrelated.txt")
        try Data("mine".utf8).write(to: unrelated)

        await assertPublisherError(.unsafeManagedContent) {
            try await publisher.publish(
                catalog: catalog.snapshot(),
                placements: catalog.placements(),
                notes: []
            )
        }
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("mine".utf8))
    }

    func testTrashedNoteIsRemovedFromOwnedExport() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try NotebookCatalogDocument()
        let note = try NoteDocument(text: "temporary")
        try catalog.add(id: note.noteID, kind: .note, name: "Note.md")
        let publisher = NotebookMarkdownPublisher(directory: root)
        try await publisher.publish(
            catalog: catalog.snapshot(),
            placements: catalog.placements(),
            notes: [note.snapshot()]
        )
        try catalog.setTrashed(note.noteID, true)

        try await publisher.publish(
            catalog: catalog.snapshot(),
            placements: catalog.placements(),
            notes: [note.snapshot()]
        )

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appending(path: "Markdown/Note.md").path
            )
        )
    }

    func testRestartRecoversEveryDurableReplacementBoundary() async throws {
        for stoppedStage in NotebookMarkdownPublishStage.allCases {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let catalog = try NotebookCatalogDocument()
            let note = try NoteDocument(text: "old")
            try catalog.add(id: note.noteID, kind: .note, name: "Note.md")
            let placements = try catalog.placements()
            let publisher = NotebookMarkdownPublisher(directory: root)
            try await publisher.publish(
                catalog: catalog.snapshot(),
                placements: placements,
                notes: [note.snapshot()]
            )
            try note.replaceAll(with: "new")

            do {
                try await publisher.publish(
                    catalog: catalog.snapshot(),
                    placements: placements,
                    notes: [note.snapshot()]
                ) { stage in
                    if stage == stoppedStage { throw Stop.now }
                }
                XCTFail("Expected interruption at \(stoppedStage)")
            } catch Stop.now {}

            try await NotebookMarkdownPublisher(directory: root).publish(
                catalog: catalog.snapshot(),
                placements: placements,
                notes: [note.snapshot()]
            )
            XCTAssertEqual(
                try String(
                    contentsOf: root.appending(path: "Markdown/Note.md"),
                    encoding: .utf8
                ),
                "new"
            )
            XCTAssertFalse(
                try FileManager.default.contentsOfDirectory(atPath: root.path)
                    .contains { $0.hasPrefix(".notebook-stage-") }
            )
        }
    }

    func testPermanentDeletionRemovesCopiesAndInterruptedGenerations() async throws {
        for stoppedStage in NotebookMarkdownPublishStage.allCases {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let catalog = try NotebookCatalogDocument()
            let deleted = try NoteDocument(text: "body to remove")
            let survivor = try NoteDocument(text: "keep this")
            try catalog.add(id: deleted.noteID, kind: .note, name: "Delete.md")
            try catalog.add(id: survivor.noteID, kind: .note, name: "Keep.md")
            let publisher = NotebookMarkdownPublisher(directory: root)
            try await publisher.publish(
                catalog: catalog.snapshot(), placements: catalog.placements(),
                notes: [deleted.snapshot(), survivor.snapshot()])
            try catalog.markPermanentlyDeleted([deleted.noteID])
            do {
                try await publisher.publish(
                    catalog: catalog.snapshot(), placements: catalog.placements(),
                    notes: [survivor.snapshot()]
                ) { stage in
                    if stage == stoppedStage { throw Stop.now }
                }
                XCTFail("Expected interruption at \(stoppedStage)")
            } catch Stop.now {}
            try await NotebookMarkdownPublisher(directory: root).publish(
                catalog: catalog.snapshot(), placements: catalog.placements(),
                notes: [survivor.snapshot()])
            let paths = try FileManager.default.subpathsOfDirectory(atPath: root.path)
            XCTAssertFalse(paths.contains { $0.hasSuffix("Delete.md") })
            XCTAssertFalse(paths.contains { $0.hasPrefix(".notebook-stage-") })
            XCTAssertEqual(try String(contentsOf: root.appending(path: "Markdown/Keep.md"),
                                      encoding: .utf8), "keep this")
        }
    }

    private func assertPublisherError(
        _ expected: NotebookMarkdownPublisherError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)")
        } catch let error as NotebookMarkdownPublisherError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Expected publisher error, got \(error)")
        }
    }

    private func temporaryDirectory(create: Bool = false) -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "NotebookMarkdownPublisherTests-\(UUID().uuidString)"
        )
        if create {
            try! FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
        }
        return url
    }
}
