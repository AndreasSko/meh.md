import Foundation
import XCTest
import TestSupport

@testable import NoteCore

@MainActor
final class SyncRecordValidationCacheTests: XCTestCase {
    func testValidatingTheSameRecordAgainDoesNotReadIt() async throws {
        let replica = NotebookReplica(directory: temporaryDirectory())
        try await replica.createLocalNotebook()
        let record = SyncRecord(catalog: try XCTUnwrap(replica.catalogSnapshot))

        let first = try await countingCatalogDecodes { try record.validate() }
        let second = try await countingCatalogDecodes { try record.validate() }

        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 0)
    }

    func testRecordWithForgedHeadsFailsAfterTheRealOneWasValidated() async throws {
        let replica = NotebookReplica(directory: temporaryDirectory())
        try await replica.createLocalNotebook()
        let record = SyncRecord(catalog: try XCTUnwrap(replica.catalogSnapshot))
        try record.validate()

        let forged = try forgedHeads(of: record)
        XCTAssertEqual(forged.id, record.id)

        XCTAssertThrowsError(try forged.validate())
        XCTAssertThrowsError(try forged.validatedCatalog())
    }

    private func forgedHeads(of record: SyncRecord) throws -> SyncRecord {
        var payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(record))
                as? [String: Any])
        var snapshot = try XCTUnwrap(payload["snapshot"] as? [String: Any])
        snapshot["heads"] = ["forged-head"]
        payload["snapshot"] = snapshot
        return try JSONDecoder().decode(
            SyncRecord.self, from: JSONSerialization.data(withJSONObject: payload))
    }
}

/// Full catalog reads `body` caused, across all catalogs.
@MainActor
func countingCatalogDecodes(_ body: () async throws -> Void) async throws -> Int {
    let before = NotebookCatalogDocument.itemDecodes.load(ordering: .relaxed)
    try await body()
    return NotebookCatalogDocument.itemDecodes.load(ordering: .relaxed) - before
}

@MainActor
func countingCatalogDecodes(_ body: () throws -> Void) throws -> Int {
    let before = NotebookCatalogDocument.itemDecodes.load(ordering: .relaxed)
    try body()
    return NotebookCatalogDocument.itemDecodes.load(ordering: .relaxed) - before
}

/// Full catalog reads `body` caused on the main thread.
@MainActor
func countingMainThreadCatalogDecodes(
    _ body: () async throws -> Void
) async throws -> Int {
    let before = NotebookCatalogDocument.mainThreadItemDecodes.load(ordering: .relaxed)
    try await body()
    return NotebookCatalogDocument.mainThreadItemDecodes.load(ordering: .relaxed) - before
}
