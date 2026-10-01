import CloudKit
import Foundation
import XCTest

@testable import NoteCore

/// Drives the real `CloudKitSyncTransport`, including its engine delegate,
/// against an in-process CloudKit (see `Support/FakeCloudKit.swift`).
final class CloudKitSyncEngineTests: XCTestCase {
    private var root: URL!
    private var server: FakeCloudKitServer!
    private let notebookID = UUID()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "CloudKitSyncEngineTests-\(UUID().uuidString)"
        )
        server = try FakeCloudKitServer(directory: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testUploadedNotesReachAnotherDevice() async throws {
        let catalog = try makeCatalog()
        let notes = try (0..<5).map { try makeNote("note \($0)") }
        let first = try await open("device-a")
        _ = try await first.bootstrap(proposing: catalog)
        let result = try await first.publishBatch(notes)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.acknowledgedIDs, Set(notes.map(\.id)))

        let second = try await open("device-b")
        let seed = try await second.bootstrap(proposing: try makeCatalog())
        XCTAssertEqual(seed, catalog)
        let received = try await fetchAll(second).records
        XCTAssertEqual(
            Set(received.map(\.id)), Set(notes.map(\.id) + [catalog.id])
        )
    }

    func testRecordAlreadyOnServerIsAcknowledged() async throws {
        let note = try makeNote("shared")
        let first = try await open("device-a")
        _ = try await first.bootstrap(proposing: try makeCatalog())
        _ = try await first.publishBatch([note])

        // Content-addressed IDs make CloudKit's conflict an acknowledgement.
        let second = try await open("device-b")
        _ = try await second.bootstrap(proposing: try makeCatalog())
        let result = try await second.publishBatch([note])
        XCTAssertNil(result.error)
        XCTAssertEqual(result.acknowledgedIDs, [note.id])
    }

    func testConflictIsAcknowledgedWithoutAnotherRequest() async throws {
        let note = try makeNote("shared")
        let first = try await open("device-a")
        _ = try await first.bootstrap(proposing: try makeCatalog())
        _ = try await first.publishBatch([note])
        let second = try await open("device-b")
        _ = try await second.bootstrap(proposing: try makeCatalog())

        // The conflict carries the server record. Reading it again from
        // inside the engine callback could stall on a retry cooldown.
        server.inject(.failNextRead)
        let result = try await second.publishBatch([note])
        XCTAssertNil(result.error)
        XCTAssertEqual(result.acknowledgedIDs, [note.id])
    }

    func testRejectedSaveIsReportedAndSucceedsWhenRetried() async throws {
        let notes = try (0..<3).map { try makeNote("note \($0)") }
        let rejected = notes[1].id
        let transport = try await open("device")
        _ = try await transport.bootstrap(proposing: try makeCatalog())
        server.inject(.failSave(.quotaExceeded) { $0.recordName == rejected })

        let result = try await transport.publishBatch(notes)
        XCTAssertNotNil(result.error)
        XCTAssertEqual(
            result.acknowledgedIDs, Set(notes.map(\.id)).subtracting([rejected])
        )
        XCTAssertFalse(server.recordNames.contains(rejected))

        let retry = try await transport.publishBatch([notes[1]])
        XCTAssertNil(retry.error)
        XCTAssertEqual(retry.acknowledgedIDs, [rejected])
    }

    func testTransientSaveFailureIsNotAcknowledged() async throws {
        let note = try makeNote("offline edit")
        let transport = try await open("device")
        _ = try await transport.bootstrap(proposing: try makeCatalog())
        server.inject(.failSave(.networkFailure) { _ in true })

        let result = try await transport.publishBatch([note])
        XCTAssertNotNil(result.error)
        XCTAssertEqual(result.acknowledgedIDs, [])

        let retry = try await transport.publishBatch([note])
        XCTAssertNil(retry.error)
        XCTAssertEqual(retry.acknowledgedIDs, [note.id])
    }

    func testCrashAfterServerSaveCompletesAfterRestart() async throws {
        let note = try makeNote("saved before crash")
        let transport = try await open("device")
        _ = try await transport.bootstrap(proposing: try makeCatalog())
        server.inject(.crashAfterServerSave)

        let result = try await transport.publishBatch([note])
        XCTAssertEqual(result.acknowledgedIDs, [])
        XCTAssertTrue(server.recordNames.contains(note.id))
        await transport.retire()

        let restarted = try await open("device")
        let retry = try await restarted.publishBatch([note])
        XCTAssertNil(retry.error)
        XCTAssertEqual(retry.acknowledgedIDs, [note.id])
    }

    func testCrashDuringFetchReplaysEveryRecord() async throws {
        let catalog = try makeCatalog()
        let notes = try (0..<8).map { try makeNote("note \($0)") }
        let first = try await open("device-a")
        _ = try await first.bootstrap(proposing: catalog)
        _ = try await first.publishBatch(notes)

        let second = try await open("device-b")
        _ = try await second.bootstrap(proposing: catalog)
        // The first page replays the locally buffered catalog; the next one
        // asks the engine.
        let buffered = try await second.fetch(after: nil)
        server.inject(.crashAfterFetchedChanges)
        do {
            _ = try await second.fetch(after: buffered.cursor)
            XCTFail("The injected crash should interrupt the fetch")
        } catch {}
        await second.retire()

        let restarted = try await open("device-b")
        let received = try await fetchAll(restarted).records
        XCTAssertEqual(
            Set(received.map(\.id)), Set(notes.map(\.id) + [catalog.id])
        )
    }

    func testAccountChangesHaltOnlyForAnotherUser() async throws {
        let transport = try await open("device")
        _ = try await transport.bootstrap(proposing: try makeCatalog())
        let engine = try XCTUnwrap(server.latestEngine)
        let user = try await server.userRecordID()

        await engine.deliver(.accountChange(.signIn(user)))
        let unaffected = await transport.haltStatus()
        XCTAssertNil(unaffected)

        await engine.deliver(.accountChange(.switchAccounts))
        let halted = await transport.haltStatus()
        XCTAssertNotNil(halted)
        do {
            _ = try await transport.publishBatch([try makeNote("after switch")])
            XCTFail("A switched account must not receive uploads")
        } catch {
            XCTAssertEqual(error as? SyncError, .scopeChanged)
        }
        XCTAssertEqual(server.recordNames, [CloudKitTransportMode.notebook.bootstrapName])
    }

    func testDeletedZoneHaltsFetch() async throws {
        let transport = try await open("device")
        _ = try await transport.bootstrap(proposing: try makeCatalog())
        _ = try await transport.publishBatch([try makeNote("before reset")])
        let cursor = try await fetchAll(transport).cursor
        server.deleteZone()

        do {
            _ = try await transport.fetch(after: cursor)
            XCTFail("A deleted zone must halt sync")
        } catch {
            XCTAssertEqual(
                error as? CloudKitSyncTransportError, .unexpectedDeletion
            )
        }
        let halted = await transport.haltStatus()
        XCTAssertNotNil(halted)
    }

    func testDeletedZoneIsNotSilentlyRecreatedByTheNextPass() async throws {
        let transport = try await open("device")
        _ = try await transport.bootstrap(proposing: try makeCatalog())
        _ = try await fetchAll(transport)
        server.deleteZone()

        // Every coordinator pass starts with bootstrap. It must not re-seed
        // an empty cloud before the deletion has been noticed.
        do {
            _ = try await transport.bootstrap(proposing: try makeCatalog())
            XCTFail("A deleted zone must halt sync")
        } catch {
            XCTAssertEqual(
                error as? CloudKitSyncTransportError, .unexpectedDeletion
            )
        }
        XCTAssertEqual(server.recordNames, [])
        let halted = await transport.haltStatus()
        XCTAssertNotNil(halted)

        let restarted = try await open("device")
        let stillHalted = await restarted.haltStatus()
        XCTAssertNotNil(stillHalted, "The halt must survive a restart")
    }

    func testUploadAfterZoneDeletionHalts() async throws {
        let transport = try await open("device")
        _ = try await transport.bootstrap(proposing: try makeCatalog())
        server.deleteZone()

        let result = try await transport.publishBatch([try makeNote("late")])
        XCTAssertEqual(result.acknowledgedIDs, [])
        XCTAssertEqual(
            result.error as? CloudKitSyncTransportError, .unexpectedDeletion
        )
        XCTAssertEqual(server.recordNames, [])
        let halted = await transport.haltStatus()
        XCTAssertNotNil(halted)
    }

    func testUploadsBeyondOneRequestLeaveNoStagedAssets() async throws {
        // More pending saves than CloudKit accepts per request, e.g. after a
        // long offline period with automatic engine scheduling.
        let notes = try (0..<300).map { try makeNote("note \($0)") }
        let transport = try await open("device")
        _ = try await transport.bootstrap(proposing: try makeCatalog())

        let result = try await transport.publishBatch(notes)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.acknowledgedIDs.count, notes.count)
        XCTAssertEqual(try stagedAssetCount("device"), 0)
    }

    func testRetryRecoveryPreservesStateAndPublishesPendingNote() async throws {
        for damage in ["missing", "invalid cooldown", "invalid deadline"] {
            let device = "recovery-" + damage.replacingOccurrences(of: " ", with: "-")
            let transport = try await open(device)
            _ = try await transport.bootstrap(proposing: try makeCatalog())
            let note = try makeNote("pending fictional note")
            server.inject(.failSave(.quotaExceeded) { $0.recordName == note.id })
            let failed = try await transport.publishBatch([note])
            XCTAssertNotNil(failed.error)
            await transport.retire()

            let directory = root.appending(path: device)
            let stateFile = directory.appending(path: "cloudkit-sync-state.json")
            var before = try XCTUnwrap(JSONSerialization.jsonObject(
                with: Data(contentsOf: stateFile)
            ) as? [String: Any])
            before["retryNotBefore"] = damage == "invalid deadline"
                ? "invalid" : Date().timeIntervalSinceReferenceDate + 3_600
            try JSONSerialization.data(withJSONObject: before).write(to: stateFile)
            let cooldownFile = directory.appending(path: "cloudkit-availability-retry.json")
            if FileManager.default.fileExists(atPath: cooldownFile.path) {
                try FileManager.default.removeItem(at: cooldownFile)
            }
            if damage == "invalid cooldown" {
                try Data("{".utf8).write(to: cooldownFile)
            }

            let recovered = try await open(device)
            let didRecover = await recovered.recoveredRetryMetadata
            XCTAssertTrue(didRecover, damage)
            var after = try XCTUnwrap(JSONSerialization.jsonObject(
                with: Data(contentsOf: stateFile)
            ) as? [String: Any])
            XCTAssertNil(after["retryNotBefore"])
            before.removeValue(forKey: "retryNotBefore")
            after.removeValue(forKey: "retryNotBefore")
            XCTAssertEqual(before as NSDictionary, after as NSDictionary, damage)

            let published = try await recovered.publishBatch([note])
            XCTAssertNil(published.error)
            XCTAssertEqual(published.acknowledgedIDs, [note.id])
            XCTAssertTrue(server.recordNames.contains(note.id))
            await recovered.retire()
            let reopened = try await open(device)
            let recoveredAgain = await reopened.recoveredRetryMetadata
            XCTAssertFalse(recoveredAgain, damage)
            await reopened.retire()
        }
    }

    // MARK: Helpers

    private func open(_ device: String) async throws -> CloudKitSyncTransport {
        try await CloudKitSyncTransport.makeNotebook(
            services: server.services,
            containerIdentifier: server.containerIdentifier,
            stateDirectory: root.appending(path: device)
        )
    }

    private func fetchAll(
        _ transport: CloudKitSyncTransport
    ) async throws -> (records: [SyncRecord], cursor: String) {
        var cursor: String?
        var records: [SyncRecord] = []
        while true {
            let page = try await transport.fetch(after: cursor)
            records += page.records
            cursor = page.cursor
            if !page.hasMore { return (records, page.cursor) }
        }
    }

    private func stagedAssetCount(_ device: String) throws -> Int {
        let assets = root.appending(path: device).appending(path: "assets")
        let generations = try FileManager.default.contentsOfDirectory(
            at: assets, includingPropertiesForKeys: nil
        )
        return try generations.reduce(0) {
            $0 + (try FileManager.default.contentsOfDirectory(
                atPath: $1.path
            ).count)
        }
    }

    private func makeCatalog() throws -> SyncRecord {
        SyncRecord(
            catalog: try NotebookCatalogDocument(notebookID: notebookID)
                .snapshot()
        )
    }

    private func makeNote(_ text: String) throws -> SyncRecord {
        let document = try NoteDocument(noteID: UUID())
        try document.replaceAll(with: text)
        return SyncRecord(snapshot: document.snapshot(), notebookID: notebookID)
    }
}
