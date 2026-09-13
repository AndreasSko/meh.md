import CloudKit
import Foundation
import XCTest

@testable import NoteCore

final class CloudKitNotebookRecordTests: XCTestCase {
    override func tearDown() {
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories = []
        super.tearDown()
    }

    private var temporaryDirectories: [URL] = []

    func testLegacyRecordRetainsV1ShapeAndRoundTrips() throws {
        let value = try noteRecord(text: "legacy", notebookID: nil)
        let fixture = try encoded(value, mode: .legacy)

        XCTAssertEqual(fixture.record.recordType, "AutomergeSnapshotV1")
        let noteID: String? = fixture.record["noteID"]
        XCTAssertEqual(noteID, value.snapshot.noteID.uuidString)
        XCTAssertNil(fixture.record["protocolVersion"])
        XCTAssertNil(fixture.record["kind"])
        XCTAssertNil(fixture.record["notebookID"])
        XCTAssertNil(fixture.record["documentID"])
        XCTAssertEqual(try fixture.codec.decode(fixture.record), value)
    }

    func testNotebookNotePersistsMetadataAndRoundTrips() throws {
        let notebookID = UUID()
        let value = try noteRecord(text: "notebook", notebookID: notebookID)
        let fixture = try encoded(value, mode: .notebook)

        XCTAssertEqual(
            (fixture.record["protocolVersion"] as NSNumber?)?.intValue, 2
        )
        let kind: String? = fixture.record["kind"]
        let encodedNotebookID: String? = fixture.record["notebookID"]
        let documentID: String? = fixture.record["documentID"]
        XCTAssertEqual(kind, SyncDocumentKind.note.rawValue)
        XCTAssertEqual(encodedNotebookID, notebookID.uuidString)
        XCTAssertEqual(documentID, value.snapshot.noteID.uuidString)
        XCTAssertNil(fixture.record["noteID"])
        XCTAssertEqual(try fixture.codec.decode(fixture.record), value)
    }

    func testNotebookCatalogRoundTripsAndMayBootstrap() throws {
        let catalog = try NotebookCatalogDocument(notebookID: UUID())
        let value = SyncRecord(catalog: catalog.snapshot())
        let fixture = try encoded(
            value,
            mode: .notebook,
            recordName: CloudKitTransportMode.notebook.bootstrapName
        )

        let kind: String? = fixture.record["kind"]
        let documentID: String? = fixture.record["documentID"]
        XCTAssertEqual(kind, SyncDocumentKind.catalog.rawValue)
        XCTAssertEqual(documentID, value.notebookID?.uuidString)
        XCTAssertEqual(try fixture.codec.decode(fixture.record), value)
        XCTAssertEqual(fixture.codec.mode.zoneName, "meh-md-notebook-v2")
        XCTAssertEqual(
            fixture.codec.mode.recordType, "AutomergeNotebookSnapshotV2"
        )
    }

    func testNotebookBootstrapRejectsNote() throws {
        let value = try noteRecord(text: "body", notebookID: UUID())
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let zoneID = CKRecordZone.ID(
            zoneName: CloudKitTransportMode.notebook.zoneName
        )
        let codec = CloudKitRecordCodec(mode: .notebook, zoneID: zoneID)
        let id = CKRecord.ID(
            recordName: CloudKitTransportMode.notebook.bootstrapName,
            zoneID: zoneID
        )

        XCTAssertThrowsError(
            try codec.encode(
                value,
                id: id,
                assetURL: try asset(value.snapshot.data, in: directory)
            )
        ) { XCTAssertEqual($0 as? SyncError, .invalidRecord) }
    }

    func testModeValidationProtectsReservedNotebookZone() {
        XCTAssertNoThrow(
            try CloudKitTransportMode.legacy.validate(zoneName: "custom-v1")
        )
        XCTAssertThrowsError(
            try CloudKitTransportMode.legacy.validate(
                zoneName: CloudKitTransportMode.notebook.zoneName
            )
        ) { XCTAssertEqual($0 as? SyncError, .scopeChanged) }
        XCTAssertNoThrow(
            try CloudKitTransportMode.notebook.validate(
                zoneName: CloudKitTransportMode.notebook.zoneName
            )
        )
        XCTAssertThrowsError(
            try CloudKitTransportMode.notebook.validate(zoneName: "custom-v2")
        ) { XCTAssertEqual($0 as? SyncError, .scopeChanged) }
    }

    func testCodecRejectsWrongModeZoneTypeMetadataAndHash() throws {
        let value = try noteRecord(text: "strict", notebookID: UUID())
        let fixture = try encoded(value, mode: .notebook)

        let legacy = CloudKitRecordCodec(
            mode: .legacy,
            zoneID: fixture.codec.zoneID
        )
        XCTAssertInvalidRemote { _ = try legacy.decode(fixture.record) }

        let otherZone = CloudKitRecordCodec(
            mode: .notebook,
            zoneID: CKRecordZone.ID(zoneName: "another-zone")
        )
        XCTAssertInvalidRemote { _ = try otherZone.decode(fixture.record) }

        let wrongType = copy(
            fixture.record,
            recordType: "UnexpectedNotebookType"
        )
        XCTAssertInvalidRemote { _ = try fixture.codec.decode(wrongType) }

        fixture.record["protocolVersion"] = 1
        XCTAssertInvalidRemote { _ = try fixture.codec.decode(fixture.record) }
        fixture.record["protocolVersion"] = 2
        fixture.record["notebookID"] = UUID().uuidString
        XCTAssertInvalidRemote { _ = try fixture.codec.decode(fixture.record) }
        fixture.record["notebookID"] = value.notebookID?.uuidString
        fixture.record["snapshotID"] = String(repeating: "a", count: 64)
        XCTAssertInvalidRemote { _ = try fixture.codec.decode(fixture.record) }
    }

    func testDurableStateRejectsProtocolReuseAndMixedRecords() async throws {
        let directory = temporaryDirectory()
        let legacyStore = try CloudKitTransportStateStore(
            directory: directory,
            accountRecordName: "account",
            zoneName: "same-zone"
        )
        XCTAssertThrowsError(
            try CloudKitTransportStateStore(
                directory: directory,
                accountRecordName: "account",
                zoneName: "same-zone",
                protocolVersion: 2
            )
        ) { XCTAssertEqual($0 as? SyncError, .scopeChanged) }

        var legacyState = CloudKitTransportState(
            accountRecordName: "account", zoneName: "zone"
        )
        let notebookRecord = try noteRecord(
            text: "mixed", notebookID: UUID()
        )
        do {
            try await legacyStore.update {
                $0.outbox[notebookRecord.id] = notebookRecord
            }
            XCTFail("Expected mixed durable outbox to be rejected")
        } catch {
            XCTAssertEqual(error as? SyncError, .invalidRecord)
        }
        XCTAssertThrowsError(try legacyState.appendToInbox(notebookRecord)) {
            XCTAssertEqual($0 as? SyncError, .invalidRecord)
        }
    }

    private func noteRecord(
        text: String,
        notebookID: UUID?
    ) throws -> SyncRecord {
        let document = try NoteDocument(noteID: UUID(), text: text)
        if let notebookID {
            return SyncRecord(
                snapshot: document.snapshot(), notebookID: notebookID
            )
        }
        return SyncRecord(snapshot: document.snapshot())
    }

    private func encoded(
        _ value: SyncRecord,
        mode: CloudKitTransportMode,
        recordName: String? = nil
    ) throws -> (
        codec: CloudKitRecordCodec,
        record: CKRecord
    ) {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let zoneID = CKRecordZone.ID(zoneName: mode.zoneName)
        let codec = CloudKitRecordCodec(mode: mode, zoneID: zoneID)
        let recordID = CKRecord.ID(
            recordName: recordName ?? value.id,
            zoneID: zoneID
        )
        return (
            codec,
            try codec.encode(
                value,
                id: recordID,
                assetURL: try asset(value.snapshot.data, in: directory)
            )
        )
    }

    private func asset(_ data: Data, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        return url
    }

    private func copy(_ source: CKRecord, recordType: String) -> CKRecord {
        let result = CKRecord(recordType: recordType, recordID: source.recordID)
        for key in source.allKeys() { result[key] = source[key] }
        return result
    }

    private func XCTAssertInvalidRemote(
        _ body: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual(
                $0 as? CloudKitSyncTransportError,
                .invalidRemoteRecord,
                file: file,
                line: line
            )
        }
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CloudKitNotebookRecordTests-\(UUID().uuidString)"
        )
        temporaryDirectories.append(url)
        return url
    }
}
