import Foundation
import XCTest

@testable import NoteCore

final class NotebookMarkdownPublisherCacheTests: XCTestCase {
    private enum Stop: Error { case now }

    func testWarmPublishDecodesOnlyChangedNote() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try NotebookCatalogDocument()
        let first = try NoteDocument(text: "first")
        let second = try NoteDocument(text: "second")
        try catalog.add(id: first.noteID, kind: .note, name: "First")
        try catalog.add(id: second.noteID, kind: .note, name: "Second")
        let publisher = NotebookMarkdownPublisher(directory: root)
        let snapshot = catalog.snapshot()
        let placements = try catalog.placements()
        try await publisher.publish(
            catalog: snapshot, placements: placements,
            notes: [first.snapshot(), second.snapshot()]
        )
        let coldNotes = await publisher.lastDecodedNoteCount
        let coldCatalog = await publisher.lastDecodedCatalogCount
        XCTAssertEqual(coldNotes, 2)
        XCTAssertEqual(coldCatalog, 1)

        try await publisher.publish(
            catalog: snapshot, placements: placements,
            notes: [first.snapshot(), second.snapshot()]
        )
        let unchangedNotes = await publisher.lastDecodedNoteCount
        let unchangedCatalog = await publisher.lastDecodedCatalogCount
        XCTAssertEqual(unchangedNotes, 0)
        XCTAssertEqual(unchangedCatalog, 0)

        try second.replaceAll(with: "second revision")
        try await publisher.publish(
            catalog: snapshot, placements: placements,
            notes: [first.snapshot(), second.snapshot()]
        )
        let changedNotes = await publisher.lastDecodedNoteCount
        let changedCatalog = await publisher.lastDecodedCatalogCount
        XCTAssertEqual(changedNotes, 1)
        XCTAssertEqual(changedCatalog, 0)
        XCTAssertEqual(
            try Data(contentsOf: root.appending(path: "Markdown/Second.md")),
            Data("second revision".utf8)
        )
    }

    func testForgedAndCorruptNoteSnapshotsPreservePublishedCopy()
        async throws
    {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try NotebookCatalogDocument()
        let note = try NoteDocument(text: "trusted")
        let other = try NoteDocument(text: "other")
        try catalog.add(id: note.noteID, kind: .note, name: "Note")
        let publisher = NotebookMarkdownPublisher(directory: root)
        let snapshot = catalog.snapshot()
        let placements = try catalog.placements()
        let original = note.snapshot()
        try await publisher.publish(
            catalog: snapshot, placements: placements, notes: [original]
        )
        let copy = root.appending(path: "Markdown/Note.md")
        let originalBytes = try Data(contentsOf: copy)
        let invalidSnapshots = [
            NoteSnapshot(
                data: original.data,
                heads: original.heads.union(["forged-head"]),
                noteID: note.noteID
            ),
            NoteSnapshot(
                data: other.snapshot().data,
                heads: other.snapshot().heads,
                noteID: note.noteID
            ),
            NoteSnapshot(
                data: Data([0, 1, 2, 3]),
                heads: original.heads,
                noteID: note.noteID
            )
        ]

        for invalid in invalidSnapshots {
            await assertPublisherError(.invalidNote(note.noteID)) {
                try await publisher.publish(
                    catalog: snapshot, placements: placements,
                    notes: [invalid]
                )
            }
            XCTAssertEqual(try Data(contentsOf: copy), originalBytes)
        }
    }

    func testForgedCatalogAndSuppliedPlacementsAreRejectedAfterWarmup()
        async throws
    {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try NotebookCatalogDocument()
        let note = try NoteDocument(text: "trusted")
        try catalog.add(id: note.noteID, kind: .note, name: "Note")
        let publisher = NotebookMarkdownPublisher(directory: root)
        let snapshot = catalog.snapshot()
        let placements = try catalog.placements()
        try await publisher.publish(
            catalog: snapshot, placements: placements,
            notes: [note.snapshot()]
        )
        let copy = root.appending(path: "Markdown/Note.md")
        let originalBytes = try Data(contentsOf: copy)

        await assertPublisherError(.invalidCatalog) {
            try await publisher.publish(
                catalog: snapshot, placements: [],
                notes: [note.snapshot()]
            )
        }
        let forgedCatalogs = [
            NotebookCatalogSnapshot(
                data: snapshot.data,
                heads: snapshot.heads.union(["forged-head"]),
                notebookID: snapshot.notebookID
            ),
            NotebookCatalogSnapshot(
                data: snapshot.data, heads: snapshot.heads,
                notebookID: UUID()
            ),
            NotebookCatalogSnapshot(
                data: Data([0, 1, 2, 3]), heads: snapshot.heads,
                notebookID: snapshot.notebookID
            )
        ]
        for forged in forgedCatalogs {
            await assertPublisherError(.invalidCatalog) {
                try await publisher.publish(
                    catalog: forged, placements: placements,
                    notes: [note.snapshot()]
                )
            }
            XCTAssertEqual(try Data(contentsOf: copy), originalBytes)
        }
    }

    func testCatalogChangesAndRollbackRefreshPlacements() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try NotebookCatalogDocument()
        let note = try NoteDocument(text: "body")
        try catalog.add(id: note.noteID, kind: .note, name: "Original")
        let original = catalog.snapshot()
        let originalPlacements = try catalog.placements()
        let publisher = NotebookMarkdownPublisher(directory: root)
        try await publisher.publish(
            catalog: original, placements: originalPlacements,
            notes: [note.snapshot()]
        )

        try catalog.rename(note.noteID, to: "Renamed")
        try await publisher.publish(
            catalog: catalog.snapshot(), placements: catalog.placements(),
            notes: [note.snapshot()]
        )
        let changedDecodes = await publisher.lastDecodedCatalogCount
        XCTAssertEqual(changedDecodes, 1)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appending(path: "Markdown/Renamed.md").path
            )
        )

        try await publisher.publish(
            catalog: original, placements: originalPlacements,
            notes: [note.snapshot()]
        )
        let rollbackDecodes = await publisher.lastDecodedCatalogCount
        XCTAssertEqual(rollbackDecodes, 1)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appending(path: "Markdown/Original.md").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appending(path: "Markdown/Renamed.md").path
            )
        )
    }

    func testCountAndByteLimitsBoundRetainedEntries() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try NotebookCatalogDocument()
        let first = try NoteDocument(text: "first")
        let second = try NoteDocument(text: "second")
        try catalog.add(id: first.noteID, kind: .note, name: "First")
        try catalog.add(id: second.noteID, kind: .note, name: "Second")
        let snapshot = catalog.snapshot()
        let placements = try catalog.placements()
        let notes = [first.snapshot(), second.snapshot()]
        let countLimited = NotebookMarkdownPublisher(
            directory: root.appending(path: "count"),
            maximumCachedNotes: 1,
            maximumCachedBytes: 32 * 1_024 * 1_024
        )
        try await countLimited.publish(
            catalog: snapshot, placements: placements, notes: notes
        )
        let oneEntry = await countLimited.cachedNoteCount
        XCTAssertEqual(oneEntry, 1)
        try await countLimited.publish(
            catalog: snapshot, placements: placements, notes: notes
        )
        let oneDecode = await countLimited.lastDecodedNoteCount
        XCTAssertEqual(oneDecode, 1)

        let byteLimited = NotebookMarkdownPublisher(
            directory: root.appending(path: "bytes"),
            maximumCachedNotes: 2,
            maximumCachedBytes: 0
        )
        try await byteLimited.publish(
            catalog: snapshot, placements: placements, notes: notes
        )
        let noEntries = await byteLimited.cachedNoteCount
        let noBytes = await byteLimited.retainedCacheBytes
        XCTAssertEqual(noEntries, 0)
        XCTAssertEqual(noBytes, 0)
        try await byteLimited.publish(
            catalog: snapshot, placements: placements, notes: notes
        )
        let repeatedNotes = await byteLimited.lastDecodedNoteCount
        let repeatedCatalog = await byteLimited.lastDecodedCatalogCount
        XCTAssertEqual(repeatedNotes, 2)
        XCTAssertEqual(repeatedCatalog, 1)
    }

    func testCatalogGrowthPrunesNotesToSharedByteBudget() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try NotebookCatalogDocument()
        let first = try NoteDocument(text: "first body")
        let second = try NoteDocument(text: "second body")
        try catalog.add(id: first.noteID, kind: .note, name: "First")
        try catalog.add(id: second.noteID, kind: .note, name: "Second")
        let original = catalog.snapshot()
        let originalPlacements = try catalog.placements()
        let notes = [first.snapshot(), second.snapshot()]
        let baseline = NotebookMarkdownPublisher(
            directory: root.appending(path: "baseline")
        )
        try await baseline.publish(
            catalog: original, placements: originalPlacements, notes: notes
        )
        let byteBudget = await baseline.retainedCacheBytes
        XCTAssertGreaterThan(byteBudget, 0)

        let pressured = NotebookMarkdownPublisher(
            directory: root.appending(path: "pressured"),
            maximumCachedNotes: 2,
            maximumCachedBytes: byteBudget
        )
        try await pressured.publish(
            catalog: original, placements: originalPlacements, notes: notes
        )
        let warmed = await pressured.cachedNoteCount
        XCTAssertEqual(warmed, 2)

        try catalog.add(kind: .folder, name: "Archive")
        let grown = catalog.snapshot()
        let grownPlacements = try catalog.placements()
        try await pressured.publish(
            catalog: grown, placements: grownPlacements, notes: notes
        )
        let retainedNotes = await pressured.cachedNoteCount
        let retainedBytes = await pressured.retainedCacheBytes
        XCTAssertLessThan(retainedNotes, 2)
        XCTAssertLessThanOrEqual(retainedBytes, byteBudget)
        XCTAssertEqual(
            try Data(contentsOf: root.appending(path: "pressured/Markdown/First.md")),
            Data("first body".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: root.appending(path: "pressured/Markdown/Second.md")),
            Data("second body".utf8)
        )

        try await pressured.publish(
            catalog: grown, placements: grownPlacements, notes: notes
        )
        let catalogDecodes = await pressured.lastDecodedCatalogCount
        XCTAssertEqual(catalogDecodes, 0)
    }

    func testChangedAndTrashedNotesArePruned() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try NotebookCatalogDocument()
        let first = try NoteDocument(text: "first")
        let second = try NoteDocument(text: "second")
        try catalog.add(id: first.noteID, kind: .note, name: "First")
        try catalog.add(id: second.noteID, kind: .note, name: "Second")
        let publisher = NotebookMarkdownPublisher(directory: root)
        try await publisher.publish(
            catalog: catalog.snapshot(), placements: catalog.placements(),
            notes: [first.snapshot(), second.snapshot()]
        )
        let initiallyCached = await publisher.cachedNoteCount
        XCTAssertEqual(initiallyCached, 2)

        try first.replaceAll(with: "changed")
        try catalog.setTrashed(second.noteID, true)
        try await publisher.publish(
            catalog: catalog.snapshot(), placements: catalog.placements(),
            notes: [first.snapshot(), second.snapshot()]
        )
        let afterChange = await publisher.cachedNoteCount
        let decoded = await publisher.lastDecodedNoteCount
        XCTAssertEqual(afterChange, 1)
        XCTAssertEqual(decoded, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appending(path: "Markdown/Second.md").path
            )
        )

        try catalog.markPermanentlyDeleted([first.noteID])
        try await publisher.publish(
            catalog: catalog.snapshot(), placements: catalog.placements(),
            notes: [second.snapshot()]
        )
        let afterDeletion = await publisher.cachedNoteCount
        XCTAssertEqual(afterDeletion, 0)
    }

    func testSamePublisherRetriesEachDurableBoundary() async throws {
        for stoppedStage in NotebookMarkdownPublishStage.allCases {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let catalog = try NotebookCatalogDocument()
            let note = try NoteDocument(text: "before")
            try catalog.add(id: note.noteID, kind: .note, name: "Note")
            let snapshot = catalog.snapshot()
            let placements = try catalog.placements()
            let publisher = NotebookMarkdownPublisher(directory: root)
            try await publisher.publish(
                catalog: snapshot, placements: placements,
                notes: [note.snapshot()]
            )
            try note.replaceAll(with: "after")

            do {
                try await publisher.publish(
                    catalog: snapshot, placements: placements,
                    notes: [note.snapshot()]
                ) { stage in
                    if stage == stoppedStage { throw Stop.now }
                }
                XCTFail("Expected interruption at \(stoppedStage)")
            } catch Stop.now {}

            try await publisher.publish(
                catalog: snapshot, placements: placements,
                notes: [note.snapshot()]
            )
            XCTAssertEqual(
                try Data(
                    contentsOf: root.appending(path: "Markdown/Note.md")
                ),
                Data("after".utf8)
            )
            let paths = try FileManager.default.contentsOfDirectory(
                atPath: root.path
            )
            XCTAssertFalse(paths.contains { $0.hasPrefix(".notebook-stage-") })
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

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "NotebookMarkdownPublisherCacheTests-\(UUID().uuidString)"
        )
    }
}
