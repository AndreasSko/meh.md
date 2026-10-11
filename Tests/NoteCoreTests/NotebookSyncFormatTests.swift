import Automerge
import Foundation
import XCTest

@testable import NoteCore

final class NotebookSyncFormatTests: XCTestCase {
    func testFutureFormatIsRecognizedBeforeUnknownItemsAreDecoded() throws {
        let catalog = try NotebookCatalogDocument().snapshot()
        let document = try Document(catalog.data)
        try document.put(obj: .ROOT, key: "schemaVersion", value: .Uint(NotebookSyncFormat.supportedVersion + 1))
        // A new release can use an item structure this release cannot decode.
        try document.put(obj: .ROOT, key: "items", value: .String("future layout"))
        let record = Self.record(document, notebookID: catalog.notebookID)
        XCTAssertThrowsError(try record.validate()) {
            XCTAssertEqual($0 as? SyncError, .updateRequired(requiredVersion: NotebookSyncFormat.supportedVersion + 1))
        }
        XCTAssertFalse(NotebookSyncRetryPolicy.isTransient(
            SyncError.updateRequired(requiredVersion: NotebookSyncFormat.supportedVersion + 1)
        ))
    }

    func testConcurrentVersionRegistersUseHighestRequirement() throws {
        let catalog = try NotebookCatalogDocument().snapshot()
        let left = try Document(catalog.data)
        let right = left.fork()
        try left.put(obj: .ROOT, key: "schemaVersion", value: .Uint(2))
        try right.put(obj: .ROOT, key: "schemaVersion", value: .Uint(3))
        try left.merge(other: right)
        XCTAssertEqual(
            try NotebookSyncFormat.version(of: Self.record(left, notebookID: catalog.notebookID)),
            3
        )
    }

    func testCorruptFutureRecordDoesNotBecomeAnUpdateRequirement() throws {
        let catalog = try NotebookCatalogDocument().snapshot()
        let document = try Document(catalog.data)
        try document.put(obj: .ROOT, key: "schemaVersion", value: .Uint(NotebookSyncFormat.supportedVersion + 1))
        let record = Self.record(document, notebookID: catalog.notebookID)
        let encoder = JSONEncoder()
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(record)) as? [String: Any]
        )
        json["id"] = String(repeating: "0", count: 64)
        let corrupt = try JSONDecoder().decode(
            SyncRecord.self, from: JSONSerialization.data(withJSONObject: json)
        )
        XCTAssertThrowsError(try corrupt.validate()) {
            XCTAssertEqual($0 as? SyncError, .invalidRecord)
        }
    }

    func testFutureRecordStillChecksHeadsAndNotebookIdentity() throws {
        let catalog = try NotebookCatalogDocument().snapshot()
        let document = try Document(catalog.data)
        try document.put(obj: .ROOT, key: "schemaVersion", value: .Uint(NotebookSyncFormat.supportedVersion + 1))
        let actual = Self.record(document, notebookID: catalog.notebookID)
        let wrongHeads = SyncRecord(catalog: NotebookCatalogSnapshot(
            data: actual.snapshot.data, heads: catalog.heads,
            notebookID: catalog.notebookID
        ))
        let wrongIdentity = Self.record(document, notebookID: UUID())
        for record in [wrongHeads, wrongIdentity] {
            XCTAssertThrowsError(try record.validate()) {
                XCTAssertEqual($0 as? NotebookCatalogError, .identityMismatch)
            }
        }
    }

    private static func record(_ document: Document, notebookID: UUID) -> SyncRecord {
        SyncRecord(catalog: NotebookCatalogSnapshot(
            data: document.save(),
            heads: Set(document.heads().map(\.debugDescription)),
            notebookID: notebookID
        ))
    }
}
