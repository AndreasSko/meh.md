import Foundation
import XCTest

@testable import NoteCore

@MainActor
final class NotebookImportTests: XCTestCase {
    private enum InjectedFailure: Error { case stop }

    func testResumePreservesStagedDatesAfterSourceIsRemoved() async throws {
        let root = temporaryDirectory()
        let sourceRoot = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceRoot)
        }
        try FileManager.default.createDirectory(
            at: sourceRoot,
            withIntermediateDirectories: true
        )
        let source = sourceRoot.appending(path: "dated.md")
        try Data("exact source bytes".utf8).write(to: source)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000.123)],
            ofItemAtPath: source.path
        )
        let plan = try await NotebookImportScanner().scan(urls: [source])
        let entry = try XCTUnwrap(plan.entries.first)
        let expected = NoteMetadata(
            createdAt: entry.createdAt,
            modifiedAt: entry.modifiedAt
        )
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        replica.importFaultInjector = { stage in
            if stage == .journalSaved { throw InjectedFailure.stop }
        }
        do {
            try await replica.importMarkdown(plan)
            XCTFail("Expected interruption after staging the import")
        } catch is InjectedFailure {}
        try FileManager.default.removeItem(at: sourceRoot)

        let restarted = NotebookReplica(directory: root)
        try await restarted.load()
        try await restarted.resumePendingImport()

        guard case let .current(snapshot) =
            await restarted.noteStorage(entry.id).load()
        else { return XCTFail("Expected imported note") }
        XCTAssertEqual(try snapshot.metadata, expected)
        XCTAssertEqual(
            try NoteDocument(snapshot: snapshot).text,
            "exact source bytes"
        )
    }

    func testResumeAtEveryWriteBoundaryUsesOneImport() async throws {
        let stages: [NotebookImportStage] = [
            .journalSaved,
            .beforeBody(Self.noteID),
            .bodySaved(Self.noteID),
            .beforeCatalog,
            .catalogSaved,
        ]
        for stage in stages {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let replica = NotebookReplica(directory: root)
            try await replica.createLocalNotebook()
            replica.importFaultInjector = { observed in
                if observed == stage { throw InjectedFailure.stop }
            }

            do {
                try await replica.importMarkdown(Self.plan())
                XCTFail("Expected interruption at \(stage)")
            } catch is InjectedFailure {}
            XCTAssertTrue(replica.hasPendingImport)

            let restarted = NotebookReplica(directory: root)
            try await restarted.load()
            try await restarted.resumePendingImport()
            XCTAssertFalse(restarted.hasPendingImport)
            XCTAssertEqual(
                Set(restarted.placements.map(\.item.id)),
                [Self.folderID, Self.noteID]
            )
            let session = try await restarted.openNote(Self.noteID)
            XCTAssertEqual(session.text, "imported")

            let reopened = NotebookReplica(directory: root)
            try await reopened.load()
            XCTAssertEqual(reopened.placements.count, 2)
        }
    }

    func testResumeAfterCatalogCommitPreservesNewerChanges() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        replica.importFaultInjector = { stage in
            if stage == .catalogSaved { throw InjectedFailure.stop }
        }
        do {
            try await replica.importMarkdown(Self.plan())
            XCTFail("Expected interruption after the catalog commit")
        } catch is InjectedFailure {}
        replica.importFaultInjector = nil

        let session = try await replica.openNote(Self.noteID)
        try session.replaceAll(with: "edited after import")
        try await session.flush()
        try await replica.rename(Self.noteID, to: "Renamed.md")
        try await replica.setTrashed(Self.noteID, true)
        try await replica.markPermanentlyDeleted([Self.noteID])

        try await replica.resumePendingImport()

        XCTAssertFalse(replica.hasPendingImport)
        XCTAssertTrue(try replica.deletedIDs.contains(Self.noteID))
        let stored = await replica.noteStorage(Self.noteID).load()
        guard case .current(let snapshot) = stored else {
            return XCTFail("Expected the edited body")
        }
        XCTAssertEqual(try NoteDocument(snapshot: snapshot).text, "edited after import")
    }

    func testResumeForksLatestConcurrentCatalog() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let importing = NotebookReplica(directory: root)
        try await importing.createLocalNotebook()
        importing.importFaultInjector = { stage in
            if stage == .journalSaved { throw InjectedFailure.stop }
        }
        do {
            try await importing.importMarkdown(Self.plan())
            XCTFail("Expected interruption after journaling")
        } catch is InjectedFailure {}
        importing.importFaultInjector = nil

        let concurrent = NotebookReplica(directory: root)
        try await concurrent.load()
        let unrelated = try await concurrent.createFolder(name: "Concurrent")

        try await importing.resumePendingImport()

        XCTAssertEqual(
            Set(importing.placements.map(\.item.id)),
            [Self.folderID, Self.noteID, unrelated]
        )
    }

    func testInvalidAndConflictingPlansWriteNothing() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        let existing = try await replica.createFolder(name: "Existing")
        let invalid = NotebookImportPlan(
            id: UUID(),
            entries: [
                NotebookImportEntry(
                    id: UUID(), kind: .note, name: "Bad.md",
                    parentID: UUID(), text: "bad"
                ),
            ],
            skippedPaths: []
        )
        do {
            try await replica.importMarkdown(invalid)
            XCTFail("Expected whole-plan validation")
        } catch {
            XCTAssertEqual(error as? NotebookImportError, .invalidPlan)
        }
        let conflicting = NotebookImportPlan(
            id: UUID(),
            entries: [
                NotebookImportEntry(
                    id: existing, kind: .folder, name: "Copy",
                    parentID: nil, text: nil
                ),
            ],
            skippedPaths: []
        )
        do {
            try await replica.importMarkdown(conflicting)
            XCTFail("Expected identity conflict")
        } catch {
            XCTAssertEqual(
                error as? NotebookImportError,
                .identityConflict(existing)
            )
        }
        XCTAssertFalse(replica.hasPendingImport)
        XCTAssertEqual(replica.placements.map(\.item.id), [existing])
    }

    func testInvalidSuppliedDateWritesNoJournalBodyOrCatalog() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        let noteID = UUID()
        let before = replica.catalogSnapshot
        let invalid = NotebookImportPlan(
            id: UUID(),
            entries: [
                NotebookImportEntry(
                    id: noteID,
                    kind: .note,
                    name: "Invalid.md",
                    parentID: nil,
                    text: "body",
                    createdAt: Date(timeIntervalSince1970: .infinity)
                ),
            ],
            skippedPaths: []
        )

        do {
            try await replica.importMarkdown(invalid)
            XCTFail("Expected invalid timestamp rejection")
        } catch {
            XCTAssertEqual(error as? NotebookImportError, .invalidPlan)
        }

        XCTAssertEqual(replica.catalogSnapshot, before)
        XCTAssertFalse(replica.hasPendingImport)
        XCTAssertFalse(NotebookImportStorage(directory: root).hasPendingImport)
        let body = await replica.noteStorage(noteID).load()
        XCTAssertEqual(body, .firstLaunch)
    }

    func testCorruptJournalAndBodyAreSafelyRefused() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        replica.importFaultInjector = { stage in
            if stage == .journalSaved { throw InjectedFailure.stop }
        }
        do { try await replica.importMarkdown(Self.plan()) } catch is InjectedFailure {}
        try Data("damaged".utf8).write(
            to: NotebookImportStorage(directory: root).journalURL
        )
        do {
            try await replica.resumePendingImport()
            XCTFail("Expected corrupt journal refusal")
        } catch {
            XCTAssertEqual(error as? NotebookImportError, .corruptJournal)
        }
        XCTAssertTrue(replica.hasPendingImport)

        try FileManager.default.removeItem(at: root)
        let bodyRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: bodyRoot) }
        let bodyReplica = NotebookReplica(directory: bodyRoot)
        try await bodyReplica.createLocalNotebook()
        bodyReplica.importFaultInjector = { stage in
            if stage == .journalSaved { throw InjectedFailure.stop }
        }
        do { try await bodyReplica.importMarkdown(Self.plan()) } catch is InjectedFailure {}
        let wrong = try NoteDocument(noteID: Self.noteID, text: "other")
        try await bodyReplica.noteStorage(Self.noteID).save(wrong.snapshot())
        do {
            try await bodyReplica.resumePendingImport()
            XCTFail("Expected conflicting body refusal")
        } catch {
            XCTAssertEqual(
                error as? NotebookImportError,
                .bodyConflict(Self.noteID)
            )
        }
        XCTAssertTrue(bodyReplica.hasPendingImport)
    }

    func testJournalCopiedToAnotherNotebookIsRefused() async throws {
        let firstRoot = temporaryDirectory()
        let secondRoot = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: firstRoot)
            try? FileManager.default.removeItem(at: secondRoot)
        }
        let first = NotebookReplica(directory: firstRoot)
        try await first.createLocalNotebook()
        first.importFaultInjector = { stage in
            if stage == .journalSaved { throw InjectedFailure.stop }
        }
        do { try await first.importMarkdown(Self.plan()) } catch is InjectedFailure {}

        let second = NotebookReplica(directory: secondRoot)
        try await second.createLocalNotebook()
        try FileManager.default.copyItem(
            at: NotebookImportStorage(directory: firstRoot).journalURL,
            to: NotebookImportStorage(directory: secondRoot).journalURL
        )
        let reopened = NotebookReplica(directory: secondRoot)
        try await reopened.load()
        do {
            try await reopened.resumePendingImport()
            XCTFail("Expected a notebook identity mismatch")
        } catch {
            XCTAssertEqual(
                error as? NotebookImportError,
                .notebookIdentityMismatch
            )
        }
        XCTAssertTrue(reopened.hasPendingImport)
        XCTAssertTrue(reopened.placements.isEmpty)
    }

    func testPartialCatalogAndMissingCommittedBodyAreRefused() async throws {
        let partialRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: partialRoot) }
        let partial = NotebookReplica(directory: partialRoot)
        try await partial.createLocalNotebook()
        partial.importFaultInjector = { stage in
            if stage == .journalSaved { throw InjectedFailure.stop }
        }
        do { try await partial.importMarkdown(Self.plan()) } catch is InjectedFailure {}
        guard case .current(let snapshot) =
            await NotebookCatalogStorage(directory: partialRoot).load()
        else { return XCTFail("Expected current catalog") }
        let changed = try NotebookCatalogDocument(snapshot: snapshot)
        try changed.add(
            id: Self.folderID,
            kind: .folder,
            name: "Partial",
            parentID: nil
        )
        try await NotebookCatalogStorage(directory: partialRoot).save(
            changed.snapshot()
        )
        do {
            try await partial.resumePendingImport()
            XCTFail("Expected partial catalog refusal")
        } catch {
            XCTAssertEqual(error as? NotebookImportError, .catalogConflict)
        }

        let missingRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: missingRoot) }
        let missing = NotebookReplica(directory: missingRoot)
        try await missing.createLocalNotebook()
        missing.importFaultInjector = { stage in
            if stage == .catalogSaved { throw InjectedFailure.stop }
        }
        do { try await missing.importMarkdown(Self.plan()) } catch is InjectedFailure {}
        try FileManager.default.removeItem(
            at: missing.noteStorage(Self.noteID).currentURL
        )
        do {
            try await missing.resumePendingImport()
            XCTFail("Expected missing body refusal")
        } catch {
            XCTAssertEqual(
                error as? NotebookImportError,
                .bodyConflict(Self.noteID)
            )
        }
        XCTAssertTrue(missing.hasPendingImport)
    }

    func testBatchCatalogAdditionIsIsolatedAndValidatesWholeTree() throws {
        let catalog = try NotebookCatalogDocument()
        let existing = try catalog.add(kind: .folder, name: "Existing")
        let original = catalog.snapshot()

        let imported = try catalog.forkAddingImportEntries(Self.plan().entries)
        XCTAssertEqual(try catalog.items().map(\.id), [existing])
        XCTAssertEqual(
            Set(try imported.items().map(\.id)),
            [existing, Self.folderID, Self.noteID]
        )

        let duplicate = NotebookImportEntry(
            id: existing, kind: .folder, name: "Duplicate",
            parentID: nil, text: nil
        )
        XCTAssertThrowsError(try catalog.forkAddingImportEntries([duplicate]))
        let missingParent = NotebookImportEntry(
            id: UUID(), kind: .note, name: "Missing.md",
            parentID: UUID(), text: "text"
        )
        XCTAssertThrowsError(
            try catalog.forkAddingImportEntries([missingParent])
        )
        let first = UUID()
        let second = UUID()
        let cycle = [
            NotebookImportEntry(
                id: first, kind: .folder, name: "First",
                parentID: second, text: nil
            ),
            NotebookImportEntry(
                id: second, kind: .folder, name: "Second",
                parentID: first, text: nil
            ),
        ]
        XCTAssertThrowsError(try catalog.forkAddingImportEntries(cycle))
        XCTAssertEqual(catalog.snapshot(), original)
    }

    func testSetAsidePreservesCorruptJournalAndStagedState() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        replica.importFaultInjector = { stage in
            if stage == .bodySaved(Self.noteID) {
                throw InjectedFailure.stop
            }
        }
        do { try await replica.importMarkdown(Self.plan()) } catch is InjectedFailure {}
        replica.importFaultInjector = nil

        let catalogBefore = replica.catalogSnapshot
        guard case .current(let stagedBefore) =
            await replica.noteStorage(Self.noteID).load()
        else { return XCTFail("Expected a staged note body") }
        let corruptBytes = Data("damaged saved import".utf8)
        try corruptBytes.write(
            to: NotebookImportStorage(directory: root).journalURL
        )

        let recoveryURL = try await replica.setAsidePendingImport()

        XCTAssertFalse(replica.hasPendingImport)
        XCTAssertEqual(try Data(contentsOf: recoveryURL), corruptBytes)
        XCTAssertEqual(replica.catalogSnapshot, catalogBefore)
        guard case .current(let stagedAfter) =
            await replica.noteStorage(Self.noteID).load()
        else { return XCTFail("Expected the staged body to remain") }
        XCTAssertEqual(stagedAfter, stagedBefore)

        let replacementID = UUID()
        let replacement = NotebookImportPlan(
            id: UUID(),
            entries: [
                NotebookImportEntry(
                    id: replacementID,
                    kind: .note,
                    name: "Replacement.md",
                    parentID: nil,
                    text: "replacement"
                ),
            ],
            skippedPaths: []
        )
        try await replica.importMarkdown(replacement)
        XCTAssertEqual(replica.placements.map(\.item.id), [replacementID])
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: recoveryURL.deletingLastPathComponent(),
                includingPropertiesForKeys: nil
            ).count,
            1
        )
    }

    func testSetAsideFailureAfterMoveUpdatesPendingFlag() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        replica.importFaultInjector = { stage in
            if stage == .journalSaved { throw InjectedFailure.stop }
        }
        do { try await replica.importMarkdown(Self.plan()) } catch is InjectedFailure {}

        var movedURL: URL?
        replica.importFaultInjector = { stage in
            if case .journalSetAside(let url) = stage {
                movedURL = url
                throw InjectedFailure.stop
            }
        }
        do {
            _ = try await replica.setAsidePendingImport()
            XCTFail("Expected the injected post-move failure")
        } catch is InjectedFailure {}

        XCTAssertFalse(replica.hasPendingImport)
        XCTAssertFalse(
            NotebookImportStorage(directory: root).hasPendingImport
        )
        XCTAssertNotNil(movedURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedURL!.path))
    }

    private static let folderID = UUID(
        uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    )!
    private static let noteID = UUID(
        uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
    )!

    private static func plan() -> NotebookImportPlan {
        NotebookImportPlan(
            id: UUID(),
            entries: [
                NotebookImportEntry(
                    id: noteID, kind: .note, name: "Note.md",
                    parentID: folderID, text: "imported"
                ),
                NotebookImportEntry(
                    id: folderID, kind: .folder, name: "Folder",
                    parentID: nil, text: nil
                ),
            ],
            skippedPaths: []
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "NotebookImportTests-\(UUID().uuidString)"
        )
    }
}
