import Foundation
import XCTest

@testable import NoteCore

@MainActor
final class NotebookLinkMaintenanceTests: XCTestCase {
    func testImportedCatalogItemsKeepTheirRootScope() throws {
        let catalog = try NotebookCatalogDocument()
        let root = UUID()
        let child = UUID()
        let next = try catalog.forkAddingImportEntries([
            NotebookImportEntry(
                id: root, kind: .folder, name: "Imported", parentID: nil,
                text: nil),
            NotebookImportEntry(
                id: child, kind: .note, name: "Note.md", parentID: root,
                text: "")
        ])
        let items = try next.items()
        XCTAssertEqual(items.first { $0.id == root }?.importRootID, root)
        XCTAssertEqual(items.first { $0.id == child }?.importRootID, root)
        XCTAssertNil(try catalog.items().first?.importRootID)

        try next.move(child, to: nil)
        XCTAssertNil(try next.items().first { $0.id == child }?.importRootID)
    }

    func testFolderMovePreservesLiteralWikiAndMarkdownLinks() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        let target = try await replica.createNote(name: "Target.md", text: "# Heading")
        let source = try await replica.createNote(
            name: "Source.md",
            text: "[[Target#Heading]]\n[Target](./Target.md#Heading)")
        let folder = try await replica.createFolder(name: "Folder")

        try await replica.move(target, to: folder)

        let corpus = try await replica.linkCorpus()
        let updated = try XCTUnwrap(corpus.texts[source])
        XCTAssertTrue(updated.contains("[[Target#Heading]]"))
        XCTAssertTrue(updated.contains("[Target](./Target.md#Heading)"))
        let sourceDescriptor = try XCTUnwrap(corpus.notes.first { $0.id == source })
        for occurrence in NotebookLinkParser.parse(updated) {
            guard case .resolved(let noteID, _) = NotebookLinkResolver.resolve(
                occurrence, sourceID: sourceDescriptor.id, notes: corpus.notes)
            else { return XCTFail("Updated link did not resolve") }
            XCTAssertEqual(noteID, target)
        }
    }

    func testUnrelatedRenameLeavesExistingLinkTextUnchanged() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        let target = try await replica.createNote(name: "Target.md", text: "body")
        let source = try await replica.createNote(
            name: "Source.md", text: "[[Target]] and [label](./Target.md)")
        let unrelated = try await replica.createNote(name: "Other.md", text: "other")
        let beforeCorpus = try await replica.linkCorpus()
        let before = try XCTUnwrap(beforeCorpus.texts[source])

        try await replica.rename(unrelated, to: "Renamed.md")

        let afterCorpus = try await replica.linkCorpus()
        let after = try XCTUnwrap(afterCorpus.texts[source])
        XCTAssertEqual(after, before)
        XCTAssertEqual(target, try XCTUnwrap(afterCorpus.notes.first {
            $0.name == "Target.md"
        }?.id))
    }

    func testSourceEditDuringMoveIsPreserved() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        let target = try await replica.createNote(name: "Target.md", text: "body")
        let source = try await replica.createNote(name: "Source.md", text: "[[Target]]")
        let session = try await replica.openNote(source)
        let folder = try await replica.createFolder(name: "Folder")
        replica.catalogWriteSuspension = {
            try session.replaceAll(with: "[[Target]]\nnewer local text")
        }

        try await replica.move(target, to: folder)

        XCTAssertEqual(session.text, "[[Target]]\nnewer local text")
        XCTAssertNil(replica.linkMaintenanceIssueMessage)
        let corpus = try await replica.linkCorpus()
        XCTAssertEqual(corpus.texts[target], "body")
    }

    func testTargetRenameResolvesPreservedLiteralLinks() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        let target = try await replica.createNote(name: "Target.md", text: "# Heading")
        let source = try await replica.createNote(
            name: "Source.md",
            text: "[[Target#Heading]]\n[Target](./Target.md#Heading)")

        try await replica.rename(target, to: "Renamed.md")

        let corpus = try await replica.linkCorpus()
        let updated = try XCTUnwrap(corpus.texts[source])
        XCTAssertEqual(updated, "[[Target#Heading]]\n[Target](./Target.md#Heading)")
        for occurrence in NotebookLinkParser.parse(updated) {
            XCTAssertEqual(NotebookLinkResolver.resolve(
                occurrence, sourceID: source, notes: corpus.notes),
                .resolved(noteID: target, fragment: "Heading"))
        }
    }

    func testSourceFolderMoveResolvesPreservedOutboundMarkdownPath() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        let target = try await replica.createNote(name: "Target.md", text: "body")
        let folder = try await replica.createFolder(name: "Folder")
        let source = try await replica.createNote(
            name: "Source.md", text: "[Target](../Target.md)",
            parentID: folder)

        let newParent = try await replica.createFolder(name: "Archive")
        try await replica.move(folder, to: newParent)

        let corpus = try await replica.linkCorpus()
        let updated = try XCTUnwrap(corpus.texts[source])
        XCTAssertEqual(updated, "[Target](../Target.md)")
        let link = try XCTUnwrap(NotebookLinkParser.parse(updated).first)
        XCTAssertEqual(
            NotebookLinkResolver.resolve(link, sourceID: source, notes: corpus.notes),
            .resolved(noteID: target, fragment: nil))
    }

    func testMoveUndoResolvesOriginalLiteralPaths() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        let folder = try await replica.createFolder(name: "Folder")
        let target = try await replica.createNote(
            name: "Target.md", text: "body", parentID: folder)
        let source = try await replica.createNote(
            name: "Source.md", text: "[Target](./Folder/Target.md)")
        let archive = try await replica.createFolder(name: "Archive")

        let maybeUndo = try await replica.moveItems([folder], to: archive)
        let undo = try XCTUnwrap(maybeUndo)
        let movedCorpus = try await replica.linkCorpus()
        XCTAssertEqual(movedCorpus.texts[source], "[Target](./Folder/Target.md)")
        XCTAssertEqual(NotebookLinkResolver.resolve(
            try XCTUnwrap(NotebookLinkParser.parse(movedCorpus.texts[source]!).first),
            sourceID: source, notes: movedCorpus.notes),
            .resolved(noteID: target, fragment: nil))
        _ = try await replica.undoBrowserChange(undo)

        let restoredCorpus = try await replica.linkCorpus()
        XCTAssertTrue(try XCTUnwrap(restoredCorpus.texts[source]).contains("./Folder/Target.md"))
        XCTAssertEqual(
            NotebookLinkResolver.resolve(
                try XCTUnwrap(NotebookLinkParser.parse(restoredCorpus.texts[source]!).first),
                sourceID: source, notes: restoredCorpus.notes),
            .resolved(noteID: target, fragment: nil))
    }

    func testImportedRootPathAndScopeAreExposedBySynchronousLinkNotes() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        let importedRoot = UUID()
        let importedNote = UUID()
        try await replica.importMarkdown(NotebookImportPlan(
            id: UUID(),
            entries: [
                NotebookImportEntry(
                    id: importedRoot, kind: .folder, name: "Imported",
                    parentID: nil, text: nil),
                NotebookImportEntry(
                    id: importedNote, kind: .note, name: "Note.md",
                    parentID: importedRoot, text: "body")
            ],
            skippedPaths: []))

        let descriptor = try XCTUnwrap(replica.linkNotes.first { $0.id == importedNote })
        XCTAssertEqual(descriptor.rootID, importedRoot)
        XCTAssertEqual(descriptor.rootPath, "Imported")
        XCTAssertEqual(descriptor.path, "Imported")

        let newNote = try await replica.createNote(
            name: "New.md", text: "new", parentID: importedRoot)
        XCTAssertEqual(replica.linkNotes.first { $0.id == newNote }?.rootID, importedRoot)
        let nested = try await replica.createFolder(name: "Nested", parentID: importedRoot)
        let nestedNote = try await replica.createNote(
            name: "Nested note.md", text: "new", parentID: nested)
        XCTAssertEqual(replica.linkNotes.first { $0.id == nestedNote }?.rootID, importedRoot)
    }

    func testSelectedTopLevelMarkdownFilesCanLinkAcrossOneImportBatch() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        let firstID = UUID()
        let secondID = UUID()
        try await replica.importMarkdown(NotebookImportPlan(
            id: UUID(),
            entries: [
                NotebookImportEntry(
                    id: firstID, kind: .note, name: "A.md", parentID: nil,
                    text: "[[B]]"),
                NotebookImportEntry(
                    id: secondID, kind: .note, name: "B.md", parentID: nil,
                    text: "target")
            ],
            skippedPaths: []))

        let corpus = try await replica.linkCorpus()
        XCTAssertNil(corpus.notes.first { $0.id == firstID }?.rootID)
        XCTAssertNil(corpus.notes.first { $0.id == secondID }?.rootID)
        let link = try XCTUnwrap(NotebookLinkParser.parse(corpus.texts[firstID]!).first)
        XCTAssertEqual(
            NotebookLinkResolver.resolve(link, sourceID: firstID, notes: corpus.notes),
            .resolved(noteID: secondID, fragment: nil))
    }

    func testUnavailableBodyIsNotPresentedAsEmptyAndNameCollisionsUseMaterializedNames() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        let unavailable = try await replica.createNote(name: "Lost.md", text: "body")
        try FileManager.default.removeItem(at: replica.noteStorage(unavailable).currentURL)
        let firstCollision = try await replica.createNote(name: "Same.md", text: "one")
        let secondCollision = try await replica.createNote(name: "Same.md", text: "two")
        let source = try await replica.createNote(name: "Source.md", text: "")

        let corpus = try await replica.linkCorpus()
        XCTAssertNil(corpus.texts[unavailable])
        XCTAssertTrue(corpus.unavailableIDs.contains(unavailable))
        try await replica.rename(unavailable, to: "Renamed lost.md")
        XCTAssertNil(replica.linkMaintenanceIssueMessage)
        let collisionNames = replica.linkNotes.filter {
            $0.id == firstCollision || $0.id == secondCollision
        }.map(\.name)
        XCTAssertEqual(Set(collisionNames).count, 2)
        let sourceNote = try XCTUnwrap(replica.linkNotes.first { $0.id == source })
        let targetNote = try XCTUnwrap(replica.linkNotes.first {
            ($0.id == firstCollision || $0.id == secondCollision) && $0.name != "Same.md"
        })
        let destination = try XCTUnwrap(NotebookLinkDestination.make(
            target: targetNote, source: sourceNote, kind: .markdown))
        let candidate = try XCTUnwrap(NotebookLinkParser.parse("[x](\(destination))").first)
        XCTAssertEqual(
            NotebookLinkResolver.resolve(
                candidate, sourceID: source, notes: replica.linkNotes),
            .resolved(noteID: targetNote.id, fragment: nil))
        XCTAssertNotEqual(firstCollision, secondCollision)
    }
}
