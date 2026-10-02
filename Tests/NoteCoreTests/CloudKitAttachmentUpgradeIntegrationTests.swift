import CloudKit
import Foundation
import XCTest

@testable import NoteCore

@MainActor
final class CloudKitAttachmentUpgradeIntegrationTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "cloudkit-attachment-upgrade-\(UUID())"
        )
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true
        )
        return url
    }

    private func open(
        _ name: String, server: FakeCloudKitServer, root: URL,
        maximumVersion: UInt64 = NotebookSyncFormat.supportedVersion
    ) async throws -> (
        replica: NotebookReplica,
        transport: CloudKitSyncTransport,
        coordinator: NotebookSyncCoordinator
    ) {
        let replica = NotebookReplica(
            directory: root.appending(path: name)
        )
        let transport = try await CloudKitSyncTransport.makeNotebook(
            services: server.services,
            containerIdentifier: server.containerIdentifier,
            stateDirectory: root.appending(path: "\(name)-cloud"),
            maximumSupportedFormatVersion: maximumVersion
        )
        return (
            replica, transport,
            NotebookSyncCoordinator(replica: replica, transport: transport)
        )
    }

    private func importAttachment(
        into replica: NotebookReplica, at root: URL
    ) async throws -> NotebookAttachmentDescriptor {
        let source = root.appending(path: "illustration.bin")
        try Data((0..<8_192).map { UInt8($0 % 251) }).write(to: source)
        let plan = try await NotebookImportScanner(
            attachmentStore: replica.attachmentStore
        ).scan(urls: [source])
        let descriptor = try XCTUnwrap(plan.entries.first {
            $0.kind == .attachment
        }?.attachment)
        try await replica.importMarkdown(plan)
        return descriptor
    }

    private func gate(on server: FakeCloudKitServer) async throws ->
        CloudKitNotebookFormatGate {
        let id = CKRecord.ID(
            recordName: CloudKitTransportMode.notebook.bootstrapName,
            zoneID: server.zoneID
        )
        return try CloudKitNotebookFormatGate.read(
            await server.record(for: id)
        )
    }

    func testAttachmentUpgradePausesOldClientThenResumesLocalEdits()
        async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try FakeCloudKitServer(directory: directory)
        let old = try await open(
            "old", server: server, root: directory, maximumVersion: 1
        )
        await old.coordinator.synchronize()
        XCTAssertNil(old.coordinator.lastError)
        let modern = try await open(
            "modern", server: server, root: directory
        )
        await modern.coordinator.synchronize()
        XCTAssertNil(modern.coordinator.lastError)

        let attachment = try await importAttachment(
            into: modern.replica, at: directory
        )
        await modern.coordinator.synchronize()
        XCTAssertNil(modern.coordinator.lastError)
        let migrated = try await gate(on: server)
        XCTAssertEqual(migrated.catalogFormatVersion, 2)
        XCTAssertEqual(migrated.minimumReaderVersion, 2)
        let migrationID = try XCTUnwrap(migrated.migrationSnapshotID)
        XCTAssertTrue(server.recordNames.contains(migrationID))

        await old.coordinator.synchronize()
        XCTAssertEqual(
            old.coordinator.lastError as? SyncError,
            .updateRequired(requiredVersion: 2)
        )
        let noteID = try await old.replica.createNote(
            name: "Written while paused.md", text: "kept locally"
        )
        let paused = try await old.replica.openNote(noteID)
        try paused.replaceAll(with: "edited while paused")
        try await paused.flush()
        await old.transport.retire()

        let resumed = try await open(
            "old", server: server, root: directory
        )
        await resumed.coordinator.synchronize()
        XCTAssertNil(resumed.coordinator.lastError)
        await modern.coordinator.synchronize()
        await resumed.coordinator.synchronize()
        XCTAssertNil(modern.coordinator.lastError)
        let receivedNote = try await modern.replica.openNote(noteID)
        XCTAssertEqual(receivedNote.text, "edited while paused")
        XCTAssertEqual(
            try resumed.replica.attachmentDescriptor(for: attachment.id),
            attachment
        )
        let afterResume = try await gate(on: server)
        XCTAssertEqual(afterResume.migrationSnapshotID, migrationID)
        await resumed.transport.retire()
        await modern.transport.retire()
    }

    func testLostUpgradeAcknowledgementKeepsSingleMigrationReceipt()
        async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try FakeCloudKitServer(directory: directory)
        let device = try await open(
            "device", server: server, root: directory
        )
        await device.coordinator.synchronize()
        XCTAssertNil(device.coordinator.lastError)
        _ = try await importAttachment(
            into: device.replica, at: directory
        )
        server.inject(.crashAfterServerSave)
        await device.coordinator.synchronize()
        XCTAssertTrue(device.coordinator.lastError is FakeCloudKitCrash)
        let upgraded = try await gate(on: server)
        let receipt = try XCTUnwrap(upgraded.migrationSnapshotID)
        await device.transport.retire()

        let reopened = try await open(
            "device", server: server, root: directory
        )
        await reopened.coordinator.synchronize()
        XCTAssertNil(reopened.coordinator.lastError)
        let afterRestart = try await gate(on: server)
        XCTAssertEqual(afterRestart.migrationSnapshotID, receipt)
        await reopened.transport.retire()
    }

    func testTwoPreparedAttachmentUpgradesConvergeOnOneReceipt()
        async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try FakeCloudKitServer(directory: directory)
        let left = try await open("left", server: server, root: directory)
        let right = try await open("right", server: server, root: directory)
        await left.coordinator.synchronize()
        await right.coordinator.synchronize()
        XCTAssertNil(left.coordinator.lastError)
        XCTAssertNil(right.coordinator.lastError)

        let leftAttachment = try await importAttachment(
            into: left.replica, at: directory
        )
        let rightAttachment = try await importAttachment(
            into: right.replica, at: directory
        )
        let leftCandidate = try XCTUnwrap(left.replica.catalogSnapshot)
        let rightCandidate = try XCTUnwrap(right.replica.catalogSnapshot)
        XCTAssertEqual(
            try NotebookSyncFormat.version(
                of: SyncRecord(catalog: leftCandidate)
            ), 2
        )
        XCTAssertEqual(
            try NotebookSyncFormat.version(
                of: SyncRecord(catalog: rightCandidate)
            ), 2
        )

        let leftPass = Task { await left.coordinator.synchronize() }
        let rightPass = Task { await right.coordinator.synchronize() }
        await leftPass.value
        await rightPass.value
        let firstGate = try await gate(on: server)
        let receipt = try XCTUnwrap(firstGate.migrationSnapshotID)
        XCTAssertTrue([
            SyncRecord(catalog: leftCandidate).id,
            SyncRecord(catalog: rightCandidate).id
        ].contains(receipt))

        for _ in 0..<6 {
            await left.coordinator.synchronize()
            await right.coordinator.synchronize()
        }
        XCTAssertNil(left.coordinator.lastError)
        XCTAssertNil(right.coordinator.lastError)
        for replica in [left.replica, right.replica] {
            XCTAssertEqual(
                try replica.attachmentDescriptor(for: leftAttachment.id),
                leftAttachment
            )
            XCTAssertEqual(
                try replica.attachmentDescriptor(for: rightAttachment.id),
                rightAttachment
            )
        }
        let settledGate = try await gate(on: server)
        XCTAssertEqual(settledGate.catalogFormatVersion, 2)
        XCTAssertEqual(settledGate.migrationSnapshotID, receipt)
        await left.transport.retire()
        await right.transport.retire()
    }

    func testFormatTwoInitialSeedAdvertisesItsOwnReceipt() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try FakeCloudKitServer(directory: directory)
        let modern = try await open(
            "modern", server: server, root: directory
        )
        try await modern.replica.createLocalNotebook()
        _ = try await importAttachment(
            into: modern.replica, at: directory
        )
        let snapshot = try XCTUnwrap(modern.replica.catalogSnapshot)
        let seed = SyncRecord(catalog: snapshot)
        XCTAssertEqual(try NotebookSyncFormat.version(of: seed), 2)
        let canonical = try await modern.transport.bootstrap(
            proposing: seed
        )
        XCTAssertEqual(canonical.id, seed.id)
        let initialGate = try await gate(on: server)
        XCTAssertEqual(initialGate.catalogFormatVersion, 2)
        XCTAssertEqual(initialGate.migrationSnapshotID, seed.id)

        let old = try await open(
            "old", server: server, root: directory, maximumVersion: 1
        )
        let olderProposal = SyncRecord(catalog:
            try NotebookCatalogDocument(notebookID: snapshot.notebookID)
                .snapshot()
        )
        do {
            _ = try await old.transport.bootstrap(
                proposing: olderProposal
            )
            XCTFail("A format-one client must pause before decoding seed two")
        } catch {
            XCTAssertEqual(
                error as? SyncError,
                .updateRequired(requiredVersion: 2)
            )
        }
        await old.transport.retire()
        await modern.transport.retire()
    }

    func testCanonicalWithoutControlFieldsStillJoinsAsFormatOne()
        async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try FakeCloudKitServer(directory: directory)
        let notebookID = UUID()
        let seed = SyncRecord(catalog:
            try NotebookCatalogDocument(notebookID: notebookID).snapshot()
        )
        let first = try await open(
            "first", server: server, root: directory,
            maximumVersion: 1
        )
        _ = try await first.transport.bootstrap(proposing: seed)
        let canonicalID = CKRecord.ID(
            recordName: CloudKitTransportMode.notebook.bootstrapName,
            zoneID: server.zoneID
        )
        let legacy = try await server.record(for: canonicalID)
        legacy[CloudKitNotebookFormatGate.readerKey] = nil
        legacy[CloudKitNotebookFormatGate.writerKey] = nil
        legacy[CloudKitNotebookFormatGate.catalogKey] = nil
        legacy[CloudKitNotebookFormatGate.migrationKey] = nil
        legacy[CloudKitNotebookFormatGate.publicationKey] = nil
        let save = try await server.modifyRecords(
            saving: [legacy], deleting: [],
            savePolicy: .ifServerRecordUnchanged, atomically: true
        )
        _ = try save.saveResults[canonicalID]?.get()

        let modern = try await open(
            "modern", server: server, root: directory
        )
        let joined = try await modern.transport.bootstrap(proposing: seed)
        XCTAssertEqual(joined, seed)
        let legacyGate = try await gate(on: server)
        XCTAssertEqual(legacyGate.catalogFormatVersion, 1)
        await first.transport.retire()
        await modern.transport.retire()
    }
}
