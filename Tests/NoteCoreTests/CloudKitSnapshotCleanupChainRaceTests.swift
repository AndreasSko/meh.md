import CloudKit
import Foundation
import XCTest

@testable import NoteCore

final class CloudKitSnapshotCleanupChainRaceTests: XCTestCase {
    func testReplacementDeletedAfterReadWithImmediateNotification() async throws {
        try await overlappingChain(beforeDelete: false, notifyWhilePaused: true)
    }

    func testReplacementDeletedAfterReadWithDelayedNotification() async throws {
        try await overlappingChain(beforeDelete: false, notifyWhilePaused: false)
    }

    func testReplacementDeletedImmediatelyBeforeDeleteDispatch() async throws {
        try await overlappingChain(beforeDelete: true, notifyWhilePaused: false)
    }

    private func overlappingChain(
        beforeDelete: Bool, notifyWhilePaused: Bool
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "CleanupChainRace-\(UUID())"
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try FakeCloudKitServer(directory: root)
        let notebookID = UUID()
        let document = try NoteDocument(text: "Fictional old journal\n")
        let old = SyncRecord(snapshot: document.snapshot(), notebookID: notebookID)
        try document.replaceAll(with: "Fictional middle journal\n")
        let middle = SyncRecord(snapshot: document.snapshot(), notebookID: notebookID)
        try document.replaceAll(with: "Fictional latest journal\n")
        let latest = SyncRecord(snapshot: document.snapshot(), notebookID: notebookID)
        let expectedVersions = try document.historyVersions()
        let expectedTexts = try expectedVersions.map(document.historicalText(for:))
        let catalogDocument = try NotebookCatalogDocument(notebookID: notebookID)
        _ = try catalogDocument.add(id: document.noteID, kind: .note,
                                    name: "Fictional journal")
        let catalog = SyncRecord(catalog: catalogDocument.snapshot())
        let gate = CloudKitRaceGate()
        let database = CloudKitRaceDatabase(
            base: server,
            afterRead: beforeDelete ? nil : (middle.id, gate),
            beforeDelete: beforeDelete ? (old.id, gate) : nil
        )
        let a = try await open("a", root: root, server: server,
                               services: database.services(base: server.services))
        let aEngine = try XCTUnwrap(server.latestEngine)
        _ = try await a.bootstrap(proposing: catalog)
        try await publish([old, middle], to: a)
        _ = try await drain(a)
        let b = try await open("b", root: root, server: server)
        _ = try await b.bootstrap(proposing: catalog)
        // B retries middle and publishes latest without fetching old. Its
        // acknowledged inbox therefore authorizes only middle -> latest.
        try await publish([middle, latest], to: b)

        // A knows only old -> middle; B knows middle -> latest. The selected
        // request boundary freezes A while B performs actual cloud cleanup.
        let pending = Task {
            try await a.cleanupRedundantSnapshots(notebookID: notebookID)
        }
        do {
            try await gate.waitUntilPaused()
            XCTAssertTrue(server.recordNames.contains(middle.id))
            _ = try await b.cleanupRedundantSnapshots(notebookID: notebookID)
            XCTAssertFalse(server.recordNames.contains(middle.id))
            XCTAssertTrue(server.recordNames.contains(old.id))
            XCTAssertTrue(server.deletedRecordNames.contains(middle.id))
            XCTAssertTrue(server.recordNames.contains(latest.id))
            if notifyWhilePaused {
                await aEngine.deliver(.fetchedRecordZoneChanges(
                    modifications: [], deletions: [CKRecord.ID(
                        recordName: middle.id, zoneID: server.zoneID
                    )]
                ))
            }
            await gate.release()
            do {
                let report = try await pending.value
                if notifyWhilePaused {
                    XCTFail("Unreceived successor must not resolve middle's absence")
                }
                XCTAssertEqual(report.deletedSnapshotCount, 1)
                XCTAssertFalse(server.recordNames.contains(old.id))
            } catch {
                XCTAssertTrue(notifyWhilePaused)
                XCTAssertEqual(error as? CloudKitSyncTransportError,
                               .unexpectedDeletion)
                XCTAssertTrue(server.recordNames.contains(old.id))
            }
        } catch {
            pending.cancel()
            await gate.release()
            _ = try? await pending.value
            throw error
        }

        let attempts = await database.deletionAttempts()
        XCTAssertEqual(attempts, notifyWhilePaused ? [] : [[old.id]])

        _ = try await drain(a)
        for _ in 0..<2 {
            _ = try await a.cleanupRedundantSnapshots(notebookID: notebookID)
        }
        let convergedHalt = await a.haltStatus()
        XCTAssertNil(convergedHalt)
        await a.retire()
        let restarted = try await open("a", root: root, server: server)
        _ = try await drain(restarted)
        let repeated = try await restarted.cleanupRedundantSnapshots(
            notebookID: notebookID
        )
        XCTAssertEqual(repeated.deletedSnapshotCount, 0)
        let restartedHalt = await restarted.haltStatus()
        XCTAssertNil(restartedHalt)
        XCTAssertEqual(server.recordNames, ["canonical-notebook-v2", latest.id])

        let fresh = try await open("fresh", root: root, server: server)
        _ = try await fresh.bootstrap(proposing: catalog)
        let received = try await drain(fresh)
        let restoredRecord = try XCTUnwrap(received.first { $0.id == latest.id })
        let restored = try NoteDocument(snapshot: restoredRecord.snapshot)
        XCTAssertEqual(try restored.text, try document.text)
        XCTAssertEqual(try restored.historyVersions(), expectedVersions)
        XCTAssertEqual(try restored.historyVersions().map(restored.historicalText(for:)),
                       expectedTexts)
        await b.retire()
        await restarted.retire()
        await fresh.retire()
    }

    private func open(
        _ device: String, root: URL, server: FakeCloudKitServer,
        services: CloudKitServices? = nil
    ) async throws -> CloudKitSyncTransport {
        try await CloudKitSyncTransport.makeNotebook(
            services: services ?? server.services,
            containerIdentifier: server.containerIdentifier,
            stateDirectory: root.appending(path: device)
        )
    }

    private func publish(_ records: [SyncRecord], to transport: CloudKitSyncTransport)
        async throws {
        let result = try await transport.publishBatch(records)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.acknowledgedIDs, Set(records.map(\.id)))
    }

    private func drain(_ transport: CloudKitSyncTransport) async throws -> [SyncRecord] {
        var cursor: String?
        var records: [SyncRecord] = []
        for _ in 0..<30 {
            let page = try await transport.fetch(after: cursor)
            records += page.records
            cursor = page.cursor
            if !page.hasMore { return records }
        }
        throw SyncError.unavailable("Race fetch exceeded page bound")
    }
}
