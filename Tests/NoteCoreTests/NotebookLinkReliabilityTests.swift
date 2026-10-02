import Foundation
import XCTest

@testable import NoteCore

@MainActor
final class NotebookLinkReliabilityTests: XCTestCase {
    func testConcurrentOfflineRenamesPreserveLiteralLinksWhenBodiesMerge() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstURL = root.appending(path: "first")
        let secondURL = root.appending(path: "second")
        let first = NotebookReplica(directory: firstURL)
        try await first.createLocalNotebook()
        let target = try await first.createNote(name: "Target.md", text: "target")
        let literal = "[[Target]]\n[Target](./Target.md)"
        let source = try await first.createNote(name: "Source.md", text: literal)
        try FileManager.default.copyItem(at: firstURL, to: secondURL)
        let second = NotebookReplica(directory: secondURL)
        try await second.load()

        try await first.rename(target, to: "First.md")
        try await second.rename(target, to: "Second.md")
        let firstRecords = try await first.records()
        let secondRecords = try await second.records()
        // Exchange both catalog and body histories in opposite directions.
        // This reproduces real sync, where separately authored replacements
        // would otherwise be merged as concurrent text insertions.
        for record in secondRecords { try await first.apply(record) }
        for record in firstRecords { try await second.apply(record) }

        let firstCorpus = try await first.linkCorpus()
        let secondCorpus = try await second.linkCorpus()
        XCTAssertEqual(firstCorpus.texts[source], literal)
        XCTAssertEqual(secondCorpus.texts[source], literal)
        for corpus in [firstCorpus, secondCorpus] {
            for link in NotebookLinkParser.parse(try XCTUnwrap(corpus.texts[source])) {
                XCTAssertEqual(NotebookLinkResolver.resolve(
                    link, sourceID: source, notes: corpus.notes),
                    .resolved(noteID: target, fragment: nil))
            }
        }
    }

    private enum SimulatedCrash: Error { case interrupted }

    func testInterruptedCatalogSavePublishesStructureAndHistoryTogether() async throws {
        for stage in [NotebookLinkLocationStage.beforeCatalogSave, .catalogSaved] {
            let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let replica = NotebookReplica(directory: root)
            try await replica.createLocalNotebook()
            let target = try await replica.createNote(name: "Target.md", text: "target")
            let literal = "[[Target#Heading]]\n[Target](./Target.md#Heading)"
            let source = try await replica.createNote(name: "Source.md", text: literal)
            let originalBody = try Data(contentsOf: replica.noteStorage(source).currentURL)
            replica.linkLocationFaultInjector = {
                if $0 == stage { throw SimulatedCrash.interrupted }
            }
            do {
                try await replica.rename(target, to: "Renamed.md")
                XCTFail("The injected crash must interrupt rename")
            } catch SimulatedCrash.interrupted {}

            let reopened = NotebookReplica(directory: root)
            try await reopened.load()
            let corpus = try await reopened.linkCorpus()
            let descriptor = try XCTUnwrap(corpus.notes.first { $0.id == target })
            XCTAssertEqual(descriptor.name,
                           stage == .beforeCatalogSave ? "Target.md" : "Renamed.md")
            XCTAssertEqual(descriptor.formerLocations.isEmpty, stage == .beforeCatalogSave)
            XCTAssertEqual(try Data(contentsOf: reopened.noteStorage(source).currentURL),
                           originalBody, "A structural change must not touch note bodies")
            XCTAssertEqual(corpus.texts[source], literal)
            for link in NotebookLinkParser.parse(literal) {
                XCTAssertEqual(NotebookLinkResolver.resolve(
                    link, sourceID: source, notes: corpus.notes),
                    .resolved(noteID: target, fragment: "Heading"))
            }
        }
    }

    func testRemoteRenameAcceptsOfflineNewLinksAndPreservesRemoteText() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstURL = root.appending(path: "first")
        let secondURL = root.appending(path: "second")
        let first = NotebookReplica(directory: firstURL)
        try await first.createLocalNotebook()
        let target = try await first.createNote(name: "Target.md", text: "# Heading")
        let source = try await first.createNote(name: "Source.md", text: "[[Target]]")
        try FileManager.default.copyItem(at: firstURL, to: secondURL)
        let second = NotebookReplica(directory: secondURL)
        try await second.load()

        try await first.rename(target, to: "Renamed.md")
        let offline = try await second.createNote(
            name: "Offline.md", text: "[old path](./Target.md#Heading)")
        let edited = try await second.openNote(source)
        let userText = "[[Target]]\nRemote prose with an emoji 🌲 and [renamed label](./Target.md)"
        try edited.replaceAll(with: userText)
        try await edited.flush()
        let firstRecords = try await first.records()
        let secondRecords = try await second.records()
        for record in secondRecords { try await first.apply(record) }
        for record in firstRecords { try await second.apply(record) }

        for replica in [first, second] {
            let corpus = try await replica.linkCorpus()
            XCTAssertEqual(corpus.texts[source], userText)
            XCTAssertEqual(corpus.texts[offline], "[old path](./Target.md#Heading)")
            for sourceID in [source, offline] {
                for link in NotebookLinkParser.parse(try XCTUnwrap(corpus.texts[sourceID])) {
                    XCTAssertEqual(NotebookLinkResolver.resolve(
                        link, sourceID: sourceID, notes: corpus.notes),
                        .resolved(noteID: target,
                                  fragment: sourceID == offline ? "Heading" : nil))
                }
            }
            XCTAssertEqual(NotebookLinkIndex(texts: corpus.texts, notes: corpus.notes)
                .backlinks(to: target).count, 3)
        }
    }

    func testReusedTargetPathProducesChooserInsteadOfRedirectingOldLink() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        let original = try await replica.createNote(name: "Target.md", text: "old target")
        let source = try await replica.createNote(
            name: "Source.md", text: "[[Target]]\n[old](./Target.md)")
        try await replica.rename(original, to: "Renamed.md")
        let replacement = try await replica.createNote(name: "Target.md", text: "new target")
        let corpus = try await replica.linkCorpus()
        for link in NotebookLinkParser.parse(try XCTUnwrap(corpus.texts[source])) {
            XCTAssertEqual(NotebookLinkResolver.resolve(link, sourceID: source,
                                                       notes: corpus.notes),
                           .ambiguous([original, replacement].sorted {
                               $0.uuidString < $1.uuidString
                           }))
        }
        let index = NotebookLinkIndex(texts: corpus.texts, notes: corpus.notes)
        XCTAssertTrue(index.backlinks(to: original).isEmpty)
        XCTAssertTrue(index.backlinks(to: replacement).isEmpty)
    }

    func testMovingSourceAcrossImportedRootsDoesNotChooseSameNameTarget() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        let firstRoot = UUID(), secondRoot = UUID()
        let firstTarget = UUID(), secondTarget = UUID(), source = UUID()
        try await replica.importMarkdown(NotebookImportPlan(id: UUID(), entries: [
            NotebookImportEntry(id: firstRoot, kind: .folder, name: "First", parentID: nil, text: nil),
            NotebookImportEntry(id: secondRoot, kind: .folder, name: "Second", parentID: nil, text: nil),
            NotebookImportEntry(id: firstTarget, kind: .note, name: "Target.md", parentID: firstRoot, text: "first target"),
            NotebookImportEntry(id: secondTarget, kind: .note, name: "Target.md", parentID: secondRoot, text: "second target"),
            NotebookImportEntry(id: source, kind: .note, name: "Source.md", parentID: firstRoot, text: "[[Target]]\n[old](./Target.md)")
        ], skippedPaths: []))
        let before = try await replica.linkCorpus()
        for link in NotebookLinkParser.parse(try XCTUnwrap(before.texts[source])) {
            XCTAssertEqual(NotebookLinkResolver.resolve(link, sourceID: source, notes: before.notes),
                           .resolved(noteID: firstTarget, fragment: nil))
        }

        try await replica.move(source, to: secondRoot)

        let corpus = try await replica.linkCorpus()
        XCTAssertEqual(corpus.texts[source], "[[Target]]\n[old](./Target.md)")
        for link in NotebookLinkParser.parse(try XCTUnwrap(corpus.texts[source])) {
            XCTAssertEqual(NotebookLinkResolver.resolve(link, sourceID: source, notes: corpus.notes),
                           .ambiguous([firstTarget, secondTarget].sorted {
                               $0.uuidString < $1.uuidString
                           }))
        }
    }

    func testConcurrentSourceAndTargetMovesPreserveRelativeRelationship() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstURL = root.appending(path: "first"), secondURL = root.appending(path: "second")
        let first = NotebookReplica(directory: firstURL)
        try await first.createLocalNotebook()
        let from = try await first.createFolder(name: "From")
        let to = try await first.createFolder(name: "To")
        let target = try await first.createNote(name: "Target.md", text: "target")
        let source = try await first.createNote(name: "Source.md", text: "[target](../Target.md)", parentID: from)
        try FileManager.default.copyItem(at: firstURL, to: secondURL)
        let second = NotebookReplica(directory: secondURL)
        try await second.load()
        try await first.move(source, to: to)
        try await second.move(target, to: from)
        let firstRecords = try await first.records(), secondRecords = try await second.records()
        for record in secondRecords { try await first.apply(record) }
        for record in firstRecords { try await second.apply(record) }

        for replica in [first, second] {
            let corpus = try await replica.linkCorpus()
            XCTAssertEqual(corpus.texts[source], "[target](../Target.md)")
            XCTAssertEqual(NotebookLinkResolver.resolve(
                try XCTUnwrap(NotebookLinkParser.parse(corpus.texts[source]!).first),
                sourceID: source, notes: corpus.notes),
                .resolved(noteID: target, fragment: nil))
        }
    }

    func testHistoricalDottedWikiTitleStillResolvesAfterRename() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        let target = try await replica.createNote(name: "Budget 2026.10", text: "budget")
        let source = try await replica.createNote(name: "Source.md", text: "[[Budget 2026.10]]")
        try await replica.rename(target, to: "Budget.md")
        let corpus = try await replica.linkCorpus()
        let link = try XCTUnwrap(NotebookLinkParser.parse(corpus.texts[source]!).first)
        XCTAssertEqual(NotebookLinkResolver.resolve(link, sourceID: source, notes: corpus.notes),
                       .resolved(noteID: target, fragment: nil))
    }

    func testLinksAuthoredAtBothConcurrentNamesResolveAfterOneExchange() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstURL = root.appending(path: "first"), secondURL = root.appending(path: "second")
        let first = NotebookReplica(directory: firstURL)
        try await first.createLocalNotebook()
        let target = try await first.createNote(name: "Target.md", text: "target")
        try FileManager.default.copyItem(at: firstURL, to: secondURL)
        let second = NotebookReplica(directory: secondURL)
        try await second.load()
        try await first.rename(target, to: "First.md")
        try await second.rename(target, to: "Second.md")
        let firstSource = try await first.createNote(name: "First source.md", text: "[[First]]")
        let secondSource = try await second.createNote(name: "Second source.md", text: "[[Second]]")
        let firstRecords = try await first.records(), secondRecords = try await second.records()
        for record in secondRecords { try await first.apply(record) }
        for record in firstRecords { try await second.apply(record) }

        for replica in [first, second] {
            let corpus = try await replica.linkCorpus()
            for source in [firstSource, secondSource] {
                let link = try XCTUnwrap(NotebookLinkParser.parse(corpus.texts[source]!).first)
                XCTAssertEqual(NotebookLinkResolver.resolve(
                    link, sourceID: source, notes: corpus.notes),
                    .resolved(noteID: target, fragment: nil))
            }
        }
    }
}
