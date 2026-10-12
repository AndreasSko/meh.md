import Automerge
import CloudKit
import Foundation
import XCTest

@testable import NoteCore

final class CloudKitNotebookFormatGateTests: XCTestCase {
    private let zone = CKRecordZone.ID(zoneName: "meh-md-notebook-v2")

    func testScopedRetryWaitsForCanonicalInScope() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "CloudKitScopedGate-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try FakeCloudKitServer(directory: directory)
        let notebookID = UUID()
        let transport = try await CloudKitSyncTransport.makeNotebook(
            services: server.services,
            containerIdentifier: server.containerIdentifier,
            stateDirectory: directory.appending(path: "device")
        )
        _ = try await transport.bootstrap(proposing: SyncRecord(
            catalog: try NotebookCatalogDocument(notebookID: notebookID).snapshot()
        ))
        let document = try NoteDocument(noteID: UUID())
        try document.replaceAll(with: "queued during a scoped retry")
        let note = SyncRecord(snapshot: document.snapshot(), notebookID: notebookID)
        server.inject(.failNextRead)
        let result = try await transport.publishBatch([note])
        XCTAssertEqual(result.acknowledgedIDs, [])
        let engine = try XCTUnwrap(server.latestEngine)
        try await engine.sendChanges(.init(scope: .recordIDs([
            CKRecord.ID(recordName: note.id, zoneID: server.zoneID)
        ])))
        XCTAssertFalse(server.recordNames.contains(note.id))
        let halt = await transport.haltStatus()
        XCTAssertNil(halt)
        try await engine.sendChanges(.init(scope: .zoneIDs([server.zoneID])))
        XCTAssertTrue(server.recordNames.contains(note.id))
        await transport.retire()
    }

    func testMissingFieldsMeanFormatOne() throws {
        let record = CKRecord(
            recordType: "AutomergeNotebookSnapshotV2",
            recordID: CKRecord.ID(recordName: "canonical", zoneID: zone)
        )
        let gate = try CloudKitNotebookFormatGate.read(record)
        XCTAssertEqual(gate.minimumReaderVersion, 1)
        XCTAssertEqual(gate.minimumWriterVersion, 1)
        XCTAssertEqual(gate.catalogFormatVersion, 1)
        XCTAssertNil(gate.migrationSnapshotID)
        XCTAssertNoThrow(try gate.requireSupported())
    }

    func testUnsupportedFormatRequiresUpdateBeforePayloadDecode() throws {
        let future = NotebookSyncFormat.supportedVersion + 1
        let record = CKRecord(
            recordType: "AutomergeNotebookSnapshotV2",
            recordID: CKRecord.ID(recordName: "canonical", zoneID: zone)
        )
        record[CloudKitNotebookFormatGate.readerKey] = NSNumber(value: future)
        record[CloudKitNotebookFormatGate.writerKey] = NSNumber(value: future)
        record[CloudKitNotebookFormatGate.catalogKey] = NSNumber(value: future)
        let gate = try CloudKitNotebookFormatGate.read(record)
        XCTAssertThrowsError(try gate.requireSupported()) { error in
            XCTAssertEqual(
                error as? SyncError,
                .updateRequired(requiredVersion: future)
            )
        }
    }

    func testCapOneCloudKitCodecRejectsCatalogTwo() throws {
        let notebookID = UUID()
        let seed = try NotebookCatalogDocument(notebookID: notebookID)
            .snapshot()
        let future = try Document(seed.data)
        let version: UInt64 = 2
        try future.put(
            obj: .ROOT, key: "schemaVersion", value: .Uint(version)
        )
        let snapshot = NotebookCatalogSnapshot(
            data: future.save(),
            heads: Set(future.heads().map(\.debugDescription)),
            notebookID: notebookID
        )
        let value = SyncRecord(catalog: snapshot)
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "CloudKitCodec-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let payload = directory.appending(path: "snapshot")
        try snapshot.data.write(to: payload)
        let codec = CloudKitRecordCodec(
            mode: .notebook, zoneID: zone,
            maximumSupportedFormatVersion: 1
        )
        let record = CKRecord(
            recordType: CloudKitTransportMode.notebook.recordType,
            recordID: CKRecord.ID(recordName: value.id, zoneID: zone)
        )
        record["snapshotID"] = value.id
        record["protocolVersion"] = NSNumber(value: 2)
        record["kind"] = SyncDocumentKind.catalog.rawValue
        record["notebookID"] = notebookID.uuidString
        record["documentID"] = notebookID.uuidString
        record["heads"] = try JSONEncoder().encode(snapshot.heads)
        record["document"] = CKAsset(fileURL: payload)
        XCTAssertThrowsError(try codec.decode(record)) { error in
            XCTAssertEqual(
                error as? SyncError,
                .updateRequired(requiredVersion: version)
            )
        }
    }

    func testAtomicMigrationHasOneWinnerAndNoLosingSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "CloudKitGate-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try FakeCloudKitServer(directory: directory)
        let future = NotebookSyncFormat.supportedVersion + 1
        let firstID = String(repeating: "a", count: 64)
        let secondID = String(repeating: "b", count: 64)
        _ = try await server.modifyRecordZones(
            saving: [CKRecordZone(zoneID: server.zoneID)], deleting: []
        )
        let canonicalID = CKRecord.ID(
            recordName: "canonical", zoneID: server.zoneID
        )
        let seed = CKRecord(
            recordType: "AutomergeNotebookSnapshotV2",
            recordID: canonicalID
        )
        _ = try await server.save(seed)
        let first = try await server.record(for: canonicalID)
        let second = try await server.record(for: canonicalID)
        first[CloudKitNotebookFormatGate.catalogKey] = NSNumber(value: future)
        first[CloudKitNotebookFormatGate.readerKey] = NSNumber(value: future)
        first[CloudKitNotebookFormatGate.writerKey] = NSNumber(value: future)
        first[CloudKitNotebookFormatGate.migrationKey] = firstID
        second[CloudKitNotebookFormatGate.catalogKey] = NSNumber(value: future)
        second[CloudKitNotebookFormatGate.readerKey] = NSNumber(value: future)
        second[CloudKitNotebookFormatGate.writerKey] = NSNumber(value: future)
        second[CloudKitNotebookFormatGate.migrationKey] = secondID
        let firstSnapshot = CKRecord(
            recordType: "AutomergeNotebookSnapshotV2",
            recordID: CKRecord.ID(
                recordName: firstID, zoneID: server.zoneID
            )
        )
        let secondSnapshot = CKRecord(
            recordType: "AutomergeNotebookSnapshotV2",
            recordID: CKRecord.ID(
                recordName: secondID, zoneID: server.zoneID
            )
        )
        let winner = try await server.modifyRecords(
            saving: [first, firstSnapshot], deleting: [],
            savePolicy: .ifServerRecordUnchanged, atomically: true
        )
        XCTAssertEqual(winner.saveResults.count, 2)
        for result in winner.saveResults.values { _ = try result.get() }
        let loser = try await server.modifyRecords(
            saving: [second, secondSnapshot], deleting: [],
            savePolicy: .ifServerRecordUnchanged, atomically: true
        )
        XCTAssertThrowsError(try loser.saveResults[canonicalID]?.get())
        XCTAssertThrowsError(
            try loser.saveResults[secondSnapshot.recordID]?.get()
        )
        XCTAssertTrue(server.recordNames.contains(firstID))
        XCTAssertFalse(server.recordNames.contains(secondID))
        let current = try await server.record(for: canonicalID)
        XCTAssertEqual(
            try CloudKitNotebookFormatGate.read(current)
                .migrationSnapshotID,
            firstID
        )
    }

    func testRestartedOutboxCannotPublishPastFutureGate() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "CloudKitGateRestart-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try FakeCloudKitServer(directory: directory)
        let notebookID = UUID()
        let deviceDirectory = directory.appending(path: "device")
        func open() async throws -> CloudKitSyncTransport {
            try await CloudKitSyncTransport.makeNotebook(
                services: server.services,
                containerIdentifier: server.containerIdentifier,
                stateDirectory: deviceDirectory
            )
        }
        let first = try await open()
        let catalog = SyncRecord(catalog:
            try NotebookCatalogDocument(notebookID: notebookID).snapshot()
        )
        _ = try await first.bootstrap(proposing: catalog)
        let document = try NoteDocument(noteID: UUID())
        try document.replaceAll(with: "queued local edit")
        let note = SyncRecord(
            snapshot: document.snapshot(), notebookID: notebookID
        )
        server.inject(.failSave(.quotaExceeded) {
            $0.recordName == note.id
        })
        let failed = try await first.publishBatch([note])
        XCTAssertEqual(failed.acknowledgedIDs, [])
        await first.retire()

        let canonicalID = CKRecord.ID(
            recordName: CloudKitTransportMode.notebook.bootstrapName,
            zoneID: server.zoneID
        )
        let control = try await server.record(for: canonicalID)
        let future = NotebookSyncFormat.supportedVersion + 1
        control[CloudKitNotebookFormatGate.readerKey] =
            NSNumber(value: future)
        control[CloudKitNotebookFormatGate.writerKey] =
            NSNumber(value: future)
        control[CloudKitNotebookFormatGate.catalogKey] =
            NSNumber(value: future)
        control[CloudKitNotebookFormatGate.migrationKey] =
            String(repeating: "c", count: 64)
        let updated = try await server.modifyRecords(
            saving: [control], deleting: [],
            savePolicy: .ifServerRecordUnchanged, atomically: true
        )
        _ = try updated.saveResults[canonicalID]?.get()

        let restarted = try await open()
        let backgroundEngine = try XCTUnwrap(server.latestEngine)
        try await backgroundEngine.sendChanges(
            .init(scope: .zoneIDs([server.zoneID]))
        )
        XCTAssertFalse(server.recordNames.contains(note.id))
        let halt = await restarted.haltStatus()
        XCTAssertNotNil(halt)
        do {
            _ = try await restarted.publishBatch([note])
            XCTFail("The paused transport must reject explicit sends")
        } catch {
            XCTAssertEqual(
                error as? SyncError,
                .updateRequired(requiredVersion: future)
            )
        }
        await restarted.retire()
    }

    func testTransientCanonicalReadKeepsOutboxRetryable() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "CloudKitGateRetry-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try FakeCloudKitServer(directory: directory)
        let notebookID = UUID()
        let transport = try await CloudKitSyncTransport.makeNotebook(
            services: server.services,
            containerIdentifier: server.containerIdentifier,
            stateDirectory: directory.appending(path: "device")
        )
        _ = try await transport.bootstrap(proposing: SyncRecord(
            catalog: try NotebookCatalogDocument(notebookID: notebookID)
                .snapshot()
        ))
        let document = try NoteDocument(noteID: UUID())
        try document.replaceAll(with: "retry after one failed read")
        let note = SyncRecord(
            snapshot: document.snapshot(), notebookID: notebookID
        )
        server.inject(.failNextRead)
        let failed = try await transport.publishBatch([note])
        XCTAssertEqual(failed.acknowledgedIDs, [])
        XCTAssertFalse(server.recordNames.contains(note.id))
        let halt = await transport.haltStatus()
        XCTAssertNil(halt)
        let retry = try await transport.publishBatch([note])
        XCTAssertNil(retry.error)
        XCTAssertEqual(retry.acknowledgedIDs, [note.id])
        await transport.retire()
    }

    func testFutureUpgradeWinningCASRejectsStalePublication() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "CloudKitGateRace-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try FakeCloudKitServer(directory: directory)
        let notebookID = UUID()
        let stateDirectory = directory.appending(path: "device")
        let transport = try await CloudKitSyncTransport.makeNotebook(
            services: server.services,
            containerIdentifier: server.containerIdentifier,
            stateDirectory: stateDirectory
        )
        _ = try await transport.bootstrap(proposing: SyncRecord(
            catalog: try NotebookCatalogDocument(notebookID: notebookID)
                .snapshot()
        ))
        let document = try NoteDocument(noteID: UUID())
        try document.replaceAll(with: "edit racing the upgrade")
        let note = SyncRecord(
            snapshot: document.snapshot(), notebookID: notebookID
        )
        let future = NotebookSyncFormat.supportedVersion + 1
        server.inject(.advanceCanonicalBeforeSave(
            requiredVersion: future
        ))
        let result = try await transport.publishBatch([note])
        XCTAssertEqual(result.acknowledgedIDs, [])
        XCTAssertEqual(
            result.error as? SyncError,
            .updateRequired(requiredVersion: future)
        )
        XCTAssertFalse(server.recordNames.contains(note.id))
        let halt = await transport.haltStatus()
        XCTAssertNotNil(halt)
        await transport.retire()
        let stateData = try Data(contentsOf:
            stateDirectory.appending(path: "cloudkit-sync-state.json")
        )
        let state = try XCTUnwrap(
            JSONSerialization.jsonObject(with: stateData) as? [String: Any]
        )
        let outbox = try XCTUnwrap(state["outbox"] as? [String: Any])
        XCTAssertNotNil(outbox[note.id])
    }
}
