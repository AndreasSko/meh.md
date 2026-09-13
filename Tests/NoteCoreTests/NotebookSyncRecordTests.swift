import Foundation
import XCTest

@testable import NoteCore

final class NotebookSyncRecordTests: XCTestCase {
    func testLegacyJSONRetainsOnlyOriginalFields() throws {
        let record = SyncRecord(snapshot: try NoteDocument(text: "legacy").snapshot())
        let data = try JSONEncoder().encode(record)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["id", "snapshot"])
        let decoded = try JSONDecoder().decode(SyncRecord.self, from: data)
        try decoded.validate()
        XCTAssertEqual(record, decoded)
    }

    func testNotebookCatalogAndNoteRoundTrip() throws {
        let catalog = try NotebookCatalogDocument()
        let note = try NoteDocument(text: "Café 👋🏽")
        for record in [
            SyncRecord(catalog: catalog.snapshot()),
            SyncRecord(snapshot: note.snapshot(), notebookID: catalog.notebookID),
        ] {
            let decoded = try JSONDecoder().decode(
                SyncRecord.self, from: JSONEncoder().encode(record))
            try decoded.validate()
            XCTAssertEqual(record, decoded)
        }
    }

    func testNotebookIdentityAndKindAreBoundIntoDigest() throws {
        let note = try NoteDocument(text: "same bytes")
        let a = SyncRecord(snapshot: note.snapshot(), notebookID: UUID())
        let b = SyncRecord(snapshot: note.snapshot(), notebookID: UUID())
        let legacy = SyncRecord(snapshot: note.snapshot())
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertNotEqual(a.id, legacy.id)
        let altered = try mutate(a) { $0["notebookID"] = b.notebookID!.uuidString }
        XCTAssertThrowsError(try altered.validate())
    }

    func testCatalogPayloadCannotBeRelabeledAsNote() throws {
        let record = SyncRecord(catalog: try NotebookCatalogDocument().snapshot())
        let altered = try mutate(record) { $0["kind"] = "note" }
        XCTAssertThrowsError(try altered.validate())
    }

    func testNotebookRequiresExplicitNonNullKind() throws {
        let record = SyncRecord(snapshot: try NoteDocument().snapshot(), notebookID: UUID())
        for kind in [nil, NSNull()] as [Any?] {
            XCTAssertThrowsError(try mutate(record) { $0["kind"] = kind })
        }
    }

    func testUnsupportedVersionAndForgedHeadsFailValidation() throws {
        let record = SyncRecord(snapshot: try NoteDocument().snapshot(), notebookID: UUID())
        let future = try mutate(record) { $0["protocolVersion"] = 99 }
        XCTAssertThrowsError(try future.validate())
        let forged = try mutate(record) {
            var snapshot = $0["snapshot"] as! [String: Any]
            snapshot["heads"] = ["forged"]
            $0["snapshot"] = snapshot
        }
        XCTAssertThrowsError(try forged.validate())
    }

    private func mutate(_ record: SyncRecord, _ edit: (inout [String: Any]) -> Void) throws
        -> SyncRecord
    {
        var json =
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
        edit(&json)
        return try JSONDecoder().decode(
            SyncRecord.self, from: JSONSerialization.data(withJSONObject: json))
    }
}
