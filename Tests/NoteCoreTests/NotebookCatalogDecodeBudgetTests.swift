import Foundation
import XCTest
import TestSupport

@testable import NoteCore

/// Reading the whole catalog is the slow step of a sync, and most of it runs
/// on the main thread. These tests bound how often one step does it.
@MainActor
final class NotebookCatalogDecodeBudgetTests: XCTestCase {
    func testApplyingRemoteCatalogReadsItOncePerNeededStep() async throws {
        let local = NotebookReplica(directory: temporaryDirectory())
        try await local.createLocalNotebook()
        _ = try await local.createNote(name: "Local.md")
        let remote = NotebookReplica(directory: temporaryDirectory())
        try await remote.acceptSeed(
            SyncRecord(catalog: try XCTUnwrap(local.catalogSnapshot)))
        _ = try await remote.createNote(name: "Remote.md")
        let record = SyncRecord(catalog: try XCTUnwrap(remote.catalogSnapshot))
        // The transport validates a record when it arrives.
        try record.validate()

        let decodes = try await countingCatalogDecodes {
            try await local.apply(record)
        }

        // The incoming catalog, the merge check, and the storage write.
        XCTAssertEqual(decodes, 3)
        XCTAssertEqual(
            Set(local.placements.map(\.item.name)), ["Local.md", "Remote.md"])
    }

    func testApplyingOwnPublishedCatalogReadsItOncePerNeededStep() async throws {
        let local = NotebookReplica(directory: temporaryDirectory())
        try await local.createLocalNotebook()
        try await local.acceptSeed(
            SyncRecord(catalog: try XCTUnwrap(local.catalogSnapshot)))
        _ = try await local.createNote(name: "Local.md")
        let record = SyncRecord(catalog: try XCTUnwrap(local.catalogSnapshot))
        try record.validate()

        let decodes = try await countingCatalogDecodes {
            try await local.apply(record)
        }

        XCTAssertEqual(decodes, 0)
        XCTAssertEqual(local.catalogSnapshot, record.catalogSnapshot)
    }

    func testAcceptingTheStartingCatalogAgainReadsOnlyThatCatalog() async throws {
        let local = NotebookReplica(directory: temporaryDirectory())
        try await local.createLocalNotebook()
        let seed = SyncRecord(catalog: try XCTUnwrap(local.catalogSnapshot))
        try await local.acceptSeed(seed)
        _ = try await local.createNote(name: "Later.md")
        let heads = try XCTUnwrap(local.catalogSnapshot).heads

        let decodes = try await countingCatalogDecodes {
            try await local.acceptSeed(seed)
        }

        // The small starting catalog; the merge adds nothing, so no check.
        XCTAssertEqual(decodes, 1)
        XCTAssertEqual(local.catalogSnapshot?.heads, heads)
        XCTAssertEqual(local.placements.map(\.item.name), ["Later.md"])
    }

    func testMergingAnOlderVersionChangesAndReadsNothing() throws {
        let catalog = try NotebookCatalogDocument()
        _ = try catalog.add(kind: .note, name: "First.md")
        let older = try catalog.fork()
        _ = try catalog.add(kind: .note, name: "Second.md")
        let heads = catalog.heads
        _ = try catalog.items()

        let decodes = try countingCatalogDecodes { try catalog.merge(older) }

        XCTAssertEqual(decodes, 0)
        XCTAssertEqual(catalog.heads, heads)
        XCTAssertEqual(
            Set(try catalog.items().map(\.name)), ["First.md", "Second.md"])
    }

    func testDeletionsMadeAfterPublishingAreNotReportedForThePublishedCatalog()
        async throws
    {
        let replica = NotebookReplica(directory: temporaryDirectory())
        try await replica.createLocalNotebook()
        let note = try await replica.createNote(name: "Note.md")
        try await replica.setTrashed(note, true)
        let published = try XCTUnwrap(replica.catalogSnapshot)
        XCTAssertEqual(try replica.permanentlyDeletedIDs(in: published), [])

        try await replica.permanentlyDelete(
            try replica.deletionSelection(rootIDs: [note]))

        XCTAssertEqual(try replica.permanentlyDeletedIDs(in: published), [])
        let current = try XCTUnwrap(replica.catalogSnapshot)
        XCTAssertEqual(try replica.permanentlyDeletedIDs(in: current), [note])
    }
}
