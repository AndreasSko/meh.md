import CloudKit
import Foundation
import XCTest

@testable import NoteCore

final class CloudKitAttachmentRecordTests: XCTestCase {
    private let codec = CloudKitAttachmentRecordCodec()

    private func descriptor() throws -> NotebookAttachmentDescriptor {
        NotebookAttachmentDescriptor(id: UUID(), content: try .init(
            sha256: String(repeating: "a", count: 64), byteCount: 4))
    }

    private func sourceFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ck-attachment-record-\(UUID())")
        try Data([1, 2, 3, 4]).write(to: url)
        return url
    }

    private func assertMismatch(
        _ body: () throws -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual($0 as? NotebookAttachmentTransferError,
                .mismatchedRecord, file: file, line: line)
        }
    }

    func testLiveRecordHasStableIdentityAndExpectedAsset() throws {
        let notebookID = UUID()
        let item = try descriptor()
        let source = try sourceFile()
        defer { try? FileManager.default.removeItem(at: source) }
        let record = codec.liveRecord(item, notebookID: notebookID,
            fileURL: source)

        XCTAssertEqual(record.recordType, "NotebookAttachmentV1")
        XCTAssertEqual(record.recordID.zoneID.zoneName,
            "meh-md-attachments-v1")
        XCTAssertEqual(record.recordID,
            codec.recordID(notebookID: notebookID,
                attachmentID: item.id))
        XCTAssertEqual(try codec.state(of: record, notebookID: notebookID,
            attachmentID: item.id), .live)
        XCTAssertEqual(try codec.assetURL(in: record, descriptor: item,
            notebookID: notebookID), source)
    }

    func testRejectsWrongRecordTypeZoneAndIdentity() throws {
        let notebookID = UUID()
        let item = try descriptor()
        let source = try sourceFile()
        defer { try? FileManager.default.removeItem(at: source) }
        let live = codec.liveRecord(item, notebookID: notebookID,
            fileURL: source)

        assertMismatch {
            _ = try codec.state(of: live, notebookID: UUID(),
                attachmentID: item.id)
        }
        assertMismatch {
            _ = try codec.state(of: live, notebookID: notebookID,
                attachmentID: UUID())
        }
        let wrongType = CKRecord(recordType: "OtherAttachment",
            recordID: live.recordID)
        wrongType["notebookID"] = notebookID.uuidString as CKRecordValue
        wrongType["attachmentID"] = item.id.uuidString as CKRecordValue
        wrongType["deleted"] = 0 as CKRecordValue
        assertMismatch {
            _ = try codec.state(of: wrongType, notebookID: notebookID,
                attachmentID: item.id)
        }
        let wrongZone = CKRecord(recordType: "NotebookAttachmentV1",
            recordID: CKRecord.ID(recordName: live.recordID.recordName,
                zoneID: CKRecordZone.ID(zoneName: "other-zone")))
        wrongZone["notebookID"] = notebookID.uuidString as CKRecordValue
        wrongZone["attachmentID"] = item.id.uuidString as CKRecordValue
        wrongZone["deleted"] = 0 as CKRecordValue
        assertMismatch {
            _ = try codec.state(of: wrongZone, notebookID: notebookID,
                attachmentID: item.id)
        }
        live["attachmentID"] = UUID().uuidString as CKRecordValue
        assertMismatch {
            _ = try codec.state(of: live, notebookID: notebookID,
                attachmentID: item.id)
        }
    }

    func testRejectsChangedChecksumAndByteCount() throws {
        let notebookID = UUID()
        let item = try descriptor()
        let source = try sourceFile()
        defer { try? FileManager.default.removeItem(at: source) }
        let record = codec.liveRecord(item, notebookID: notebookID,
            fileURL: source)

        record["sha256"] = String(repeating: "b", count: 64) as CKRecordValue
        assertMismatch {
            _ = try codec.assetURL(in: record, descriptor: item,
                notebookID: notebookID)
        }
        record["sha256"] = item.content.sha256 as CKRecordValue
        record["byteCount"] = 5 as CKRecordValue
        assertMismatch {
            _ = try codec.assetURL(in: record, descriptor: item,
                notebookID: notebookID)
        }
    }

    func testTombstoneKeepsIdentityAndClearsAsset() throws {
        let notebookID = UUID()
        let item = try descriptor()
        let source = try sourceFile()
        defer { try? FileManager.default.removeItem(at: source) }
        let live = codec.liveRecord(item, notebookID: notebookID,
            fileURL: source)
        let tombstone = codec.tombstone(live, notebookID: notebookID,
            attachmentID: item.id)

        XCTAssertEqual(tombstone.recordID, live.recordID)
        XCTAssertNil(tombstone["asset"])
        XCTAssertEqual(tombstone["sha256"] as? String,
            item.content.sha256)
        XCTAssertEqual((tombstone["byteCount"] as? NSNumber)?.int64Value,
            item.content.byteCount)
        XCTAssertEqual(try codec.state(of: tombstone,
            notebookID: notebookID, attachmentID: item.id), .deleted)
        XCTAssertThrowsError(try codec.assetURL(in: tombstone,
            descriptor: item, notebookID: notebookID)) {
            XCTAssertEqual($0 as? NotebookAttachmentTransferError, .deleted)
        }
        let absent = codec.tombstone(nil, notebookID: notebookID,
            attachmentID: item.id)
        XCTAssertEqual(try codec.state(of: absent,
            notebookID: notebookID, attachmentID: item.id), .deleted)

        tombstone["asset"] = CKAsset(fileURL: source)
        assertMismatch {
            _ = try codec.state(of: tombstone, notebookID: notebookID,
                attachmentID: item.id)
        }
    }

    func testLiveRecordMissingAssetIsNeverAcknowledged() throws {
        let notebookID = UUID()
        let item = try descriptor()
        let source = try sourceFile()
        defer { try? FileManager.default.removeItem(at: source) }
        let record = codec.liveRecord(item, notebookID: notebookID,
            fileURL: source)
        record["asset"] = nil
        XCTAssertThrowsError(try codec.assetURL(in: record,
            descriptor: item, notebookID: notebookID)) {
            XCTAssertEqual($0 as? NotebookAttachmentTransferError,
                .missingAsset)
        }
    }
}
