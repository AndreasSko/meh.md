import CloudKit
import Foundation
@testable import NoteCore
import XCTest

final class CloudKitSnapshotSizeLimitTests: XCTestCase {
    func testExactAssetBoundaryIsAcceptedForBothWireVersions() throws {
        let limit = CloudKitSnapshotSizeLimit.maximumBytes
        for version in [1, 2] {
            XCTAssertNoThrow(
                try CloudKitSnapshotSizeLimit.validateAssetSize(
                    UInt64(limit), protocolVersion: version
                )
            )
            XCTAssertThrowsError(
                try CloudKitSnapshotSizeLimit.validateAssetSize(
                    UInt64(limit + 1), protocolVersion: version
                )
            ) {
                XCTAssertEqual(
                    $0 as? CloudKitSyncTransportError,
                    .invalidRemoteRecord
                )
            }
        }
    }

    func testOversizedOutgoingRecordIsRejectedBeforeStagingOrInbox() throws {
        let oversized = Data(
            count: CloudKitSnapshotSizeLimit.maximumBytes + 1
        )
        for mode in [CloudKitTransportMode.legacy, .notebook] {
            let record = makeRecord(data: oversized, mode: mode)
            XCTAssertThrowsError(try mode.validate(record)) {
                XCTAssertEqual(
                    $0 as? CloudKitSyncTransportError,
                    .snapshotTooLarge(documentID: record.snapshot.noteID)
                )
            }
            XCTAssertThrowsError(
                try CloudKitSnapshotSizeLimit.validate(
                    record, limit: Int.max
                )
            ) {
                XCTAssertEqual(
                    $0 as? CloudKitSyncTransportError,
                    .snapshotTooLarge(documentID: record.snapshot.noteID)
                )
            }

            let codec = CloudKitRecordCodec(
                mode: mode, zoneID: CKRecordZone.ID(zoneName: mode.zoneName)
            )
            XCTAssertThrowsError(
                try codec.encode(
                    record,
                    id: CKRecord.ID(
                        recordName: record.id, zoneID: codec.zoneID
                    ),
                    assetURL: URL(fileURLWithPath: "/nonexistent-snapshot")
                )
            ) {
                XCTAssertEqual(
                    $0 as? CloudKitSyncTransportError,
                    .snapshotTooLarge(documentID: record.snapshot.noteID)
                )
            }

            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            var staging = CloudKitAssetStaging(directory: directory)
            XCTAssertThrowsError(try staging.retain(record)) {
                XCTAssertEqual(
                    $0 as? CloudKitSyncTransportError,
                    .snapshotTooLarge(documentID: record.snapshot.noteID)
                )
            }
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent(record.id).path
                )
            )

            var state = CloudKitTransportState(
                accountRecordName: "fictional-account",
                zoneName: mode.zoneName,
                protocolVersion: mode.protocolVersion
            )
            XCTAssertThrowsError(try state.appendToInbox(record)) {
                XCTAssertEqual(
                    $0 as? CloudKitSyncTransportError,
                    .snapshotTooLarge(documentID: record.snapshot.noteID)
                )
            }
            XCTAssertTrue(state.inbox.isEmpty)
        }
    }

    func testOversizedCatalogRejectionIdentifiesItsKind() {
        let catalog = NotebookCatalogSnapshot(
            data: Data(count: CloudKitSnapshotSizeLimit.maximumBytes + 1),
            heads: [], notebookID: UUID()
        )
        let record = SyncRecord(catalog: catalog)
        XCTAssertThrowsError(try CloudKitSnapshotSizeLimit.validate(record)) {
            XCTAssertEqual(
                $0 as? CloudKitSyncTransportError,
                .snapshotTooLarge(
                    documentID: catalog.notebookID, kind: .catalog
                )
            )
        }
    }

    func testOutgoingRecordAtLimitPassesSizeGate() throws {
        let bytes = Data(count: CloudKitSnapshotSizeLimit.maximumBytes)
        for mode in [CloudKitTransportMode.legacy, .notebook] {
            let record = makeRecord(data: bytes, mode: mode)
            XCTAssertNoThrow(try CloudKitSnapshotSizeLimit.validate(record))
        }
    }

    func testMixedBatchAdmitsHealthyRecordsOnly() throws {
        let notebookID = UUID()
        let first = SyncRecord(
            snapshot: try NoteDocument(text: "first").snapshot(),
            notebookID: notebookID
        )
        let blocked = SyncRecord(
            snapshot: NoteSnapshot(
                data: Data(count: CloudKitSnapshotSizeLimit.maximumBytes + 1),
                heads: [], noteID: UUID()
            ),
            notebookID: notebookID
        )
        let second = SyncRecord(
            snapshot: try NoteDocument(text: "second").snapshot(),
            notebookID: notebookID
        )

        let partition = try CloudKitSnapshotSizeLimit.partition([
            first, blocked, second
        ])

        XCTAssertEqual(partition.admitted, [first, second])
        XCTAssertEqual(partition.rejected, [blocked])
    }

    func testSmallVisibleBodyCanExceedHistoryBudget() throws {
        let note = try NoteDocument(text: "short")
        let initialBytes = note.snapshot().data.count
        try note.replaceAll(with: String(repeating: "history", count: 100))
        try note.replaceAll(with: "short")
        let record = SyncRecord(snapshot: note.snapshot())

        XCTAssertEqual(try note.text, "short")
        XCTAssertGreaterThan(record.snapshot.data.count, initialBytes)
        XCTAssertThrowsError(
            try CloudKitSnapshotSizeLimit.validate(
                record, limit: initialBytes
            )
        ) {
            XCTAssertEqual(
                $0 as? CloudKitSyncTransportError,
                .snapshotTooLarge(documentID: note.noteID)
            )
        }
    }

    func testRequeuedOversizedSaveDoesNotBlockHealthyEngineBatch()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let mode = CloudKitTransportMode.notebook
        let zoneID = CKRecordZone.ID(zoneName: mode.zoneName)
        let notebookID = UUID()
        let ordinary = SyncRecord(
            snapshot: try NoteDocument(text: "unique local edit").snapshot(),
            notebookID: notebookID
        )
        let blocked = makeRecord(
            data: Data(count: CloudKitSnapshotSizeLimit.maximumBytes + 1),
            mode: mode
        )
        let outbox = [ordinary.id: ordinary, blocked.id: blocked]
        let ordinarySave = CKSyncEngine.PendingRecordZoneChange.saveRecord(
            CKRecord.ID(recordName: ordinary.id, zoneID: zoneID)
        )
        let blockedSave = CKSyncEngine.PendingRecordZoneChange.saveRecord(
            CKRecord.ID(recordName: blocked.id, zoneID: zoneID)
        )
        let deletionID = CKRecord.ID(recordName: "deleted", zoneID: zoneID)
        let deletion = CKSyncEngine.PendingRecordZoneChange.deleteRecord(
            deletionID
        )
        let startup = try CloudKitSnapshotSizeLimit.partitionPendingSaves(
            [blockedSave, ordinarySave, deletion],
            outbox: outbox, zoneID: zoneID
        )
        // Model a restored CK request arriving after startup's filter.
        let pending = startup.admitted + [blockedSave]
        let selection = try CloudKitSnapshotSizeLimit.partitionPendingSaves(
            pending, outbox: outbox, zoneID: zoneID
        )
        XCTAssertEqual(selection.rejected, [blockedSave])
        XCTAssertEqual(selection.admitted, [ordinarySave, deletion])

        var staging = CloudKitAssetStaging(directory: directory)
        let codec = CloudKitRecordCodec(mode: mode, zoneID: zoneID)
        var records: [String: CKRecord] = [:]
        for change in selection.admitted {
            guard case let .saveRecord(id) = change,
                  let value = outbox[id.recordName] else { continue }
            let assetURL = try staging.retain(value)
            records[id.recordName] = try codec.encode(
                value, id: id, assetURL: assetURL
            )
        }
        let stagedRecords = records
        // The delegate captured pending before staging rejected its request.
        let batch = await CKSyncEngine.RecordZoneChangeBatch(
            pendingChanges: pending
        ) { stagedRecords[$0.recordName] }
        XCTAssertEqual(batch?.recordsToSave.map(\.recordID.recordName),
                       [ordinary.id])
        XCTAssertEqual(batch?.recordIDsToDelete, [deletionID])
        XCTAssertEqual(outbox[blocked.id], blocked)
        XCTAssertEqual(outbox[ordinary.id], ordinary)
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent(ordinary.id)),
            ordinary.snapshot.data
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(blocked.id).path
        ))
    }

    func testEngineSizeFilterPropagatesUnsupportedProtocol() throws {
        let record = SyncRecord(
            snapshot: try NoteDocument(text: "local history").snapshot(),
            notebookID: UUID()
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(record))
                as? [String: Any]
        )
        object["protocolVersion"] = 3
        let invalid = try JSONDecoder().decode(
            SyncRecord.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        let zoneID = CKRecordZone.ID(zoneName: "fictional-zone")
        let pending = CKSyncEngine.PendingRecordZoneChange.saveRecord(
            CKRecord.ID(recordName: invalid.id, zoneID: zoneID)
        )

        XCTAssertThrowsError(
            try CloudKitSnapshotSizeLimit.partitionPendingSaves(
                [pending], outbox: [invalid.id: invalid], zoneID: zoneID
            )
        ) { XCTAssertEqual($0 as? SyncError, .invalidRecord) }
    }

    func testOversizedLateAcknowledgementCannotAdvanceDurableState()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let notebookID = UUID()
        let ordinary = SyncRecord(
            snapshot: try NoteDocument(text: "unique local edit").snapshot(),
            notebookID: notebookID
        )
        let oversized = makeRecord(
            data: Data(count: CloudKitSnapshotSizeLimit.maximumBytes + 1),
            mode: .notebook
        )
        let store = try CloudKitTransportStateStore(
            directory: directory,
            accountRecordName: "fictional-account",
            zoneName: CloudKitTransportMode.notebook.zoneName,
            protocolVersion: 2
        )
        try await store.update { $0.outbox[ordinary.id] = ordinary }
        let before = await store.snapshot()
        let committer = CloudKitEventCommitter(store: store)

        do {
            _ = try await committer.commitSent([
                CloudKitAcknowledgedRecord(id: ordinary.id, record: ordinary),
                CloudKitAcknowledgedRecord(id: oversized.id, record: oversized),
            ])
            XCTFail("An oversized saved record was acknowledged")
        } catch let error as CloudKitSyncTransportError {
            XCTAssertEqual(
                error,
                .snapshotTooLarge(documentID: oversized.snapshot.noteID)
            )
        }
        let unchanged = await store.snapshot()
        XCTAssertEqual(unchanged, before)
        let reopened = try CloudKitTransportStateStore(
            directory: directory,
            accountRecordName: "fictional-account",
            zoneName: CloudKitTransportMode.notebook.zoneName,
            protocolVersion: 2
        )
        let recovered = await reopened.snapshot()
        XCTAssertEqual(recovered, before)
    }

    func testPreviouslyQueuedHistorySurvivesRestartWithoutAdmission()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let notebookID = UUID()
        let ordinary = SyncRecord(
            snapshot: try NoteDocument(text: "ordinary").snapshot(),
            notebookID: notebookID
        )
        let note = try NoteDocument(text: "small")
        let threshold = max(
            note.snapshot().data.count, ordinary.snapshot.data.count
        )
        try note.replaceAll(with: String(repeating: "old edit", count: 100))
        try note.replaceAll(with: "small")
        let historical = SyncRecord(
            snapshot: note.snapshot(), notebookID: notebookID
        )
        let store = try CloudKitTransportStateStore(
            directory: directory,
            accountRecordName: "fictional-account",
            zoneName: CloudKitTransportMode.notebook.zoneName,
            protocolVersion: 2
        )
        try await store.update { state in
            state.outbox[ordinary.id] = ordinary
            state.outbox[historical.id] = historical
        }

        let reopened = try CloudKitTransportStateStore(
            directory: directory,
            accountRecordName: "fictional-account",
            zoneName: CloudKitTransportMode.notebook.zoneName,
            protocolVersion: 2
        )
        let recovered = await reopened.snapshot()
        let partition = try CloudKitSnapshotSizeLimit.partition(
            Array(recovered.outbox.values), limit: threshold
        )

        XCTAssertEqual(partition.rejected, [historical])
        XCTAssertEqual(recovered.outbox[historical.id], historical)
        XCTAssertEqual(try NoteDocument(snapshot: historical.snapshot).text,
                       "small")
        XCTAssertEqual(recovered.outbox[ordinary.id], ordinary)
    }

    private func makeRecord(
        data: Data, mode: CloudKitTransportMode
    ) -> SyncRecord {
        let snapshot = NoteSnapshot(data: data, heads: [], noteID: UUID())
        switch mode {
        case .legacy: return SyncRecord(snapshot: snapshot)
        case .notebook:
            return SyncRecord(snapshot: snapshot, notebookID: UUID())
        }
    }
}
