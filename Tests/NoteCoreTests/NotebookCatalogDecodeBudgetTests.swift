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

        // The incoming catalog and the merge check.
        XCTAssertEqual(decodes, 2)
        XCTAssertEqual(local.catalogSnapshot, record.catalogSnapshot)
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
