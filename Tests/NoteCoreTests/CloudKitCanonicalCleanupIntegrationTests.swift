import Foundation
import XCTest

@testable import NoteCore

final class CloudKitCanonicalCleanupIntegrationTests: XCTestCase {
    func testCreatorCanonicalDigestCannotAuthorizeCleanup() async throws {
        try await canonicalCleanup(existingBootstrap: false, legacyRestart: false)
    }

    func testExistingCanonicalDigestCannotAuthorizeCleanup() async throws {
        try await canonicalCleanup(existingBootstrap: true, legacyRestart: false)
    }

    func testPersistedCanonicalDigestPlanIsDroppedAfterRestart() async throws {
        try await canonicalCleanup(existingBootstrap: false, legacyRestart: true)
    }

    func testPersistedFalseCanonicalAbsenceRecoversWithoutBootstrap() async throws {
        try await canonicalCleanup(existingBootstrap: false, legacyRestart: true,
                                   falseAbsence: true)
    }

    func testCanonicalAliasCoversActualOlderCatalogRetirement() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "CanonicalRetirement-\(UUID())"
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try FakeCloudKitServer(directory: root)
        let notebookID = UUID()
        let catalog = try NotebookCatalogDocument(notebookID: notebookID)
        let noteID = UUID()
        _ = try catalog.add(id: noteID, kind: .note, name: "Fictional retired catalog")
        let older = SyncRecord(catalog: catalog.snapshot())
        try catalog.setPinnedInRecents(true, for: noteID)
        let canonical = SyncRecord(catalog: catalog.snapshot())
        let device = try await open("device", root: root, server: server)
        let accepted = try await device.bootstrap(proposing: canonical)
        XCTAssertEqual(accepted, canonical)
        let upload = try await device.publishBatch([older])
        XCTAssertNil(upload.error)
        XCTAssertEqual(upload.acknowledgedIDs, [older.id])
        XCTAssertFalse(server.recordNames.contains(canonical.id))
        // The real cloud deletion concerns the older immutable digest. Its
        // covering catalog exists only under CloudKit's reserved alias.
        server.deleteRecord(named: older.id)
        try await drain(device)
        let stateURL = root.appending(path: "device/cloudkit-sync-state.json")
        let retired = try JSONDecoder().decode(
            CloudKitTransportState.self, from: Data(contentsOf: stateURL)
        )
        XCTAssertTrue(retired.remoteDeletedSnapshotIDs.contains(older.id))
        XCTAssertFalse(retired.remoteDeletedSnapshotIDs.contains(canonical.id))
        XCTAssertTrue(retired.unresolvedRemoteDeletionRecordIDs.isEmpty)
        let halt = await device.haltStatus()
        XCTAssertNil(halt)
        await device.retire()
        let restarted = try await open("device", root: root, server: server)
        try await drain(restarted)
        let cleanup = try await restarted.cleanupRedundantSnapshots(
            notebookID: notebookID
        )
        XCTAssertEqual(cleanup.deletedSnapshotCount, 0)
        let restartHalt = await restarted.haltStatus()
        XCTAssertNil(restartHalt)
        XCTAssertEqual(server.recordNames, ["canonical-notebook-v2"])
        await restarted.retire()
    }

    private func canonicalCleanup(existingBootstrap: Bool, legacyRestart: Bool,
                                  falseAbsence: Bool = false)
        async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "CanonicalCleanup-\(UUID())"
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try FakeCloudKitServer(directory: root)
        let notebookID = UUID()
        let catalog = try NotebookCatalogDocument(notebookID: notebookID)
        let noteID = UUID()
        _ = try catalog.add(id: noteID, kind: .note, name: "Fictional journal")
        let older = SyncRecord(catalog: catalog.snapshot())
        try catalog.setPinnedInRecents(true, for: noteID)
        let canonical = SyncRecord(catalog: catalog.snapshot())
        XCTAssertNotEqual(older.id, canonical.id)
        let before = try NotebookCatalogDocument(serializedData: older.snapshot.data)
        XCTAssertTrue(before.historyHeads.isSubset(of: catalog.historyHeads))
        var device = try await open("device", root: root, server: server)
        let accepted = try await device.bootstrap(proposing: canonical)
        XCTAssertEqual(accepted, canonical)
        if existingBootstrap {
            await device.retire()
            device = try await open("existing", root: root, server: server)
            let existing = try await device.bootstrap(proposing: older)
            XCTAssertEqual(existing, canonical)
        }
        let uploaded = try await device.publishBatch([older])
        XCTAssertNil(uploaded.error)
        XCTAssertEqual(uploaded.acknowledgedIDs, [older.id])
        XCTAssertEqual(server.recordNames, ["canonical-notebook-v2", older.id])

        let unrelatedAbsentID = SyncRecord(
            snapshot: try NoteDocument(text: "Fictional retired note").snapshot(),
            notebookID: notebookID
        ).id
        if legacyRestart {
            await device.retire()
            let file = root.appending(path: "device/cloudkit-sync-state.json")
            var saved = try XCTUnwrap(JSONSerialization.jsonObject(
                with: Data(contentsOf: file)
            ) as? [String: Any])
            // Emulate a pre-fix state without bootstrap provenance and with
            // the cleanup plan discovered from its canonical inbox digest.
            saved.removeValue(forKey: "canonicalSnapshotID")
            saved["pendingSnapshotCleanup"] = [older.id: [
                "victimID": older.id, "survivorID": canonical.id
            ]]
            if falseAbsence {
                saved["unresolvedRemoteDeletionRecordIDs"] = [canonical.id]
                saved["remoteDeletedSnapshotIDs"] = [canonical.id, unrelatedAbsentID]
            }
            try JSONSerialization.data(withJSONObject: saved).write(to: file)
            device = try await open("device", root: root, server: server)
            if falseAbsence {
                _ = try await device.fetch(after: nil)
                let recovered = try JSONDecoder().decode(
                    CloudKitTransportState.self, from: Data(contentsOf: file)
                )
                XCTAssertFalse(recovered.remoteDeletedSnapshotIDs.contains(canonical.id))
                XCTAssertFalse(recovered.unresolvedRemoteDeletionRecordIDs.contains(canonical.id))
                XCTAssertTrue(recovered.remoteDeletedSnapshotIDs.contains(unrelatedAbsentID))
            }
        }

        // An inbox digest does not prove that its immutable cloud record
        // exists: this canonical payload has only the bootstrap alias.
        let cleanup = try await device.cleanupRedundantSnapshots(
            notebookID: notebookID
        )
        XCTAssertEqual(cleanup.deletedSnapshotCount, 0)
        let halt = await device.haltStatus()
        XCTAssertNil(halt)
        XCTAssertEqual(server.deletedRecordNames, [])
        XCTAssertEqual(server.recordNames, ["canonical-notebook-v2", older.id])
        await device.retire()
        let restarted = try await open(existingBootstrap ? "existing" : "device",
                                       root: root, server: server)
        let repeated = try await restarted.cleanupRedundantSnapshots(
            notebookID: notebookID
        )
        XCTAssertEqual(repeated.deletedSnapshotCount, 0)
        let restartHalt = await restarted.haltStatus()
        XCTAssertNil(restartHalt)
        await restarted.retire()
    }

    private func open(_ name: String, root: URL, server: FakeCloudKitServer)
        async throws -> CloudKitSyncTransport {
        try await CloudKitSyncTransport.makeNotebook(
            services: server.services,
            containerIdentifier: server.containerIdentifier,
            stateDirectory: root.appending(path: name)
        )
    }

    private func drain(_ transport: CloudKitSyncTransport) async throws {
        var cursor: String?
        for _ in 0..<30 {
            let page = try await transport.fetch(after: cursor)
            cursor = page.cursor
            if !page.hasMore { return }
        }
        throw SyncError.unavailable("Canonical regression fetch exceeded page bound")
    }
}
