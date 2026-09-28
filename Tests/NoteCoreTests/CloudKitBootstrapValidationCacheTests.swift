import CloudKit
import Foundation
@testable import NoteCore
import XCTest

final class CloudKitBootstrapValidationCacheTests: XCTestCase {
    func testExactValueReusesValidationForSameMode() throws {
        let record = try makeCatalog(itemCount: 2)
        var cache = CloudKitBootstrapValidationCache()

        let first = try cache.validate(record, mode: .notebook)
        let second = try cache.validate(record, mode: .notebook)

        XCTAssertEqual(first.record, record)
        XCTAssertEqual(second.record, record)
        XCTAssertEqual(cache.cachedRecordCount, 1)
        XCTAssertLessThanOrEqual(
            cache.retainedPayloadByteCount, 16 * 1024 * 1024
        )
    }

    func testChangedPayloadAndHeadsCannotReuseValidation() throws {
        let record = try makeCatalog(itemCount: 2)
        var cache = CloudKitBootstrapValidationCache()
        _ = try cache.validate(record, mode: .notebook)

        let changedPayload = try mutate(record) {
            var snapshot = $0["snapshot"] as! [String: Any]
            let other = try makeCatalog(itemCount: 3)
            let otherJSON = try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(other)
            ) as! [String: Any]
            let otherSnapshot = otherJSON["snapshot"] as! [String: Any]
            snapshot["data"] = otherSnapshot["data"]
            snapshot["heads"] = otherSnapshot["heads"]
            $0["snapshot"] = snapshot
        }
        XCTAssertThrowsError(
            try cache.validate(changedPayload, mode: .notebook)
        )

        let forgedHeads = try mutate(record) {
            var snapshot = $0["snapshot"] as! [String: Any]
            snapshot["heads"] = ["forged-head"]
            $0["snapshot"] = snapshot
        }
        XCTAssertThrowsError(try cache.validate(forgedHeads, mode: .notebook))
        XCTAssertEqual(cache.cachedRecordCount, 1)
    }

    func testDifferentModeDoesNotReuseValidation() throws {
        let record = try makeCatalog(itemCount: 1)
        var cache = CloudKitBootstrapValidationCache()
        _ = try cache.validate(record, mode: .notebook)

        XCTAssertThrowsError(try cache.validate(record, mode: .legacy))
        XCTAssertEqual(cache.cachedRecordCount, 1)
    }

    func testCanonicalDecodeStillChecksHeadsAndMetadataOnCacheHit() throws {
        let record = try makeCatalog(itemCount: 1)
        let fixture = try makeCloudRecord(record)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var cache = CloudKitBootstrapValidationCache()
        _ = try cache.validate(record, mode: .notebook)

        let forgedHeads = fixture.cloudRecord.copy() as! CKRecord
        forgedHeads["heads"] = try JSONEncoder().encode(Set(["forged-head"]))
        XCTAssertThrowsError(
            try fixture.codec.decodeBootstrap(forgedHeads, using: &cache)
        )

        let alteredMetadata = fixture.cloudRecord.copy() as! CKRecord
        alteredMetadata["notebookID"] = UUID().uuidString
        XCTAssertThrowsError(
            try fixture.codec.decodeBootstrap(alteredMetadata, using: &cache)
        )
    }

    func testCanonicalDecodeRejectsWrongZoneAndOversizedAsset() throws {
        let record = try makeCatalog(itemCount: 1)
        let fixture = try makeCloudRecord(record)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var cache = CloudKitBootstrapValidationCache()
        _ = try cache.validate(record, mode: .notebook)

        let wrongZoneCodec = CloudKitRecordCodec(
            mode: .notebook,
            zoneID: CKRecordZone.ID(zoneName: "another-zone")
        )
        XCTAssertThrowsError(
            try wrongZoneCodec.decodeBootstrap(
                fixture.cloudRecord, using: &cache
            )
        )

        let oversizedURL = fixture.directory.appendingPathComponent("oversized")
        FileManager.default.createFile(atPath: oversizedURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: oversizedURL)
        try handle.truncate(
            atOffset: UInt64(CloudKitRemoteRecordValidator.maximumAssetSize + 1)
        )
        try handle.close()
        let oversized = fixture.cloudRecord.copy() as! CKRecord
        oversized["document"] = CKAsset(fileURL: oversizedURL)
        XCTAssertThrowsError(
            try fixture.codec.decodeBootstrap(oversized, using: &cache)
        )
    }

    func testCacheEnforcesCountAndPayloadBudgets() throws {
        let first = try makeCatalog(itemCount: 1)
        let second = try makeCatalog(itemCount: 2)
        let third = try makeCatalog(itemCount: 3)
        var cache = CloudKitBootstrapValidationCache()
        _ = try cache.validate(first, mode: .notebook)
        _ = try cache.validate(second, mode: .notebook)
        _ = try cache.validate(third, mode: .notebook)
        XCTAssertEqual(cache.cachedRecordCount, 2)
        XCTAssertLessThanOrEqual(
            cache.retainedPayloadByteCount, 16 * 1024 * 1024
        )

        var noRetention = CloudKitBootstrapValidationCache(
            maximumRetainedBytes: 0
        )
        _ = try noRetention.validate(first, mode: .notebook)
        XCTAssertEqual(noRetention.cachedRecordCount, 0)
        XCTAssertEqual(noRetention.retainedPayloadByteCount, 0)
    }

    func testValidatedAppendPersistsAndReopens() async throws {
        let record = try makeCatalog(itemCount: 1)
        var cache = CloudKitBootstrapValidationCache()
        let validated = try cache.validate(record, mode: .notebook)
        var state = CloudKitTransportState(
            accountRecordName: "synthetic-account",
            zoneName: CloudKitTransportMode.notebook.zoneName,
            protocolVersion: 2
        )
        try state.appendToInbox(validated)
        XCTAssertEqual(state.inbox, [record])

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BootstrapTokenStore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CloudKitTransportStateStore(
            directory: directory,
            accountRecordName: "synthetic-account",
            zoneName: CloudKitTransportMode.notebook.zoneName,
            protocolVersion: 2
        )
        try await store.update { try $0.appendToInbox(validated) }
        let reopened = try CloudKitTransportStateStore(
            directory: directory,
            accountRecordName: "synthetic-account",
            zoneName: CloudKitTransportMode.notebook.zoneName,
            protocolVersion: 2
        )
        let reopenedState = await reopened.snapshot()
        XCTAssertEqual(reopenedState.inbox, [record])
    }

    private func makeCatalog(itemCount: Int) throws -> SyncRecord {
        let notebookID = UUID(
            uuidString: "11111111-1111-4111-8111-111111111111"
        )!
        let catalog = try NotebookCatalogDocument(notebookID: notebookID)
        for index in 0..<itemCount {
            try catalog.add(
                id: UUID(
                    uuidString: String(format:
                        "00000000-0000-4000-8000-%012x", index + 1)
                )!,
                kind: .note,
                name: "Fictional Note \(index + 1).md"
            )
        }
        return SyncRecord(catalog: catalog.snapshot())
    }

    private func makeCloudRecord(_ record: SyncRecord) throws -> CloudRecordFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BootstrapCodec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let assetURL = directory.appendingPathComponent("snapshot")
        try record.snapshot.data.write(to: assetURL, options: .atomic)
        let codec = CloudKitRecordCodec(
            mode: .notebook,
            zoneID: CKRecordZone.ID(
                zoneName: CloudKitTransportMode.notebook.zoneName
            )
        )
        let cloudRecord = try codec.encode(
            record,
            id: CKRecord.ID(
                recordName: CloudKitTransportMode.notebook.bootstrapName,
                zoneID: codec.zoneID
            ),
            assetURL: assetURL
        )
        return CloudRecordFixture(
            cloudRecord: cloudRecord, codec: codec, directory: directory
        )
    }

    private func mutate(
        _ record: SyncRecord,
        _ edit: (inout [String: Any]) throws -> Void
    ) throws -> SyncRecord {
        var json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(record)
        ) as! [String: Any]
        try edit(&json)
        return try JSONDecoder().decode(
            SyncRecord.self,
            from: JSONSerialization.data(withJSONObject: json)
        )
    }
}

private struct CloudRecordFixture {
    let cloudRecord: CKRecord
    let codec: CloudKitRecordCodec
    let directory: URL
}
