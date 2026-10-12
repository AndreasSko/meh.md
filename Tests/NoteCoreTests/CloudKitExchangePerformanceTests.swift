import CloudKit
import Foundation
@testable import NoteCore
import XCTest

final class CloudKitExchangePerformanceTests: XCTestCase {
    func testExchangeChecksAccountOnceAndStandaloneReadsRecheck() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExchangeCounts-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try FakeCloudKitServer(directory: directory)
        let account = CountingCloudKitAccount(server: server)
        let services = CloudKitServices(
            account: account, database: server, makeEngine: server.services.makeEngine
        )
        let transport = try await CloudKitSyncTransport.makeNotebook(
            services: services, containerIdentifier: server.containerIdentifier,
            stateDirectory: directory.appendingPathComponent("state")
        )
        let catalog = SyncRecord(catalog:
            try NotebookCatalogDocument(notebookID: UUID()).snapshot())
        _ = try await transport.bootstrap(proposing: catalog)
        let before = await account.counts
        try await transport.beginExchange()
        for _ in 0..<3 { _ = try await transport.fetch(after: nil) }
        let inExchange = await account.counts
        XCTAssertEqual(inExchange.status - before.status, 1)
        XCTAssertEqual(inExchange.user - before.user, 1)
        await transport.endExchange()
        _ = try await transport.fetch(after: nil)
        _ = try await transport.fetch(after: nil)
        let after = await account.counts
        XCTAssertEqual(after.status - inExchange.status, 2)
        XCTAssertEqual(after.user - inExchange.user, 2)
        try await transport.beginExchange()
        let beforeEvent = await account.counts
        let user = try await server.userRecordID()
        let engine = try XCTUnwrap(server.latestEngine)
        await engine.deliver(.accountChange(.signIn(user)))
        _ = try await transport.fetch(after: nil)
        let afterEvent = await account.counts
        XCTAssertEqual(afterEvent.status - beforeEvent.status, 1)
        await engine.deliver(.accountChange(.switchAccounts))
        do {
            _ = try await transport.fetch(after: nil)
            XCTFail("Account change must invalidate the exchange and halt sync")
        } catch {
            XCTAssertEqual(error as? SyncError, .scopeChanged)
        }
        await transport.retire()
    }

    func testCheckedNoOpCleanupPersistsStatusAndNewSnapshotReenablesWork() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MaintenanceStatus-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try FakeCloudKitServer(directory: directory)
        let stateDirectory = directory.appendingPathComponent("state")
        let notebookID = UUID()
        func open() async throws -> CloudKitSyncTransport {
            try await CloudKitSyncTransport.makeNotebook(
                services: server.services, containerIdentifier: server.containerIdentifier,
                stateDirectory: stateDirectory
            )
        }
        let transport = try await open()
        let catalog = try NotebookCatalogDocument(notebookID: notebookID)
        _ = try await transport.bootstrap(proposing: SyncRecord(catalog: catalog.snapshot()))
        _ = try await transport.cleanupRedundantSnapshots(notebookID: notebookID)
        let status = try await transport.snapshotMaintenanceStatus(notebookID: notebookID)
        XCTAssertNotNil(status?.lastSuccessfulCleanup)
        XCTAssertEqual(status?.hasNewSnapshotsSinceLastCleanup, false)
        await transport.retire()
        let reopened = try await open()
        let restored = try await reopened.snapshotMaintenanceStatus(notebookID: notebookID)
        XCTAssertEqual(restored, status)
        let note = try NoteDocument(noteID: UUID())
        try await reopened.publish(SyncRecord(snapshot: note.snapshot(), notebookID: notebookID))
        try note.replaceAll(with: "Fictional new snapshot")
        try await reopened.publish(SyncRecord(snapshot: note.snapshot(), notebookID: notebookID))
        let changed = try await reopened.snapshotMaintenanceStatus(notebookID: notebookID)
        XCTAssertEqual(changed?.hasNewSnapshotsSinceLastCleanup, true)
        XCTAssertEqual(changed?.maximumSnapshotsPerDocument, 2)
        XCTAssertEqual(changed?.hasPendingCleanup, true)
        XCTAssertGreaterThan(changed?.retainedSnapshotBytes ?? 0, 0)
        await reopened.retire()
    }
}

private actor CountingCloudKitAccount: CloudKitAccountClient {
    let server: FakeCloudKitServer
    var counts = (status: 0, user: 0)
    init(server: FakeCloudKitServer) { self.server = server }
    func accountStatus() async throws -> CKAccountStatus {
        counts.status += 1
        return try await server.accountStatus()
    }
    func userRecordID() async throws -> CKRecord.ID {
        counts.user += 1
        return try await server.userRecordID()
    }
}
