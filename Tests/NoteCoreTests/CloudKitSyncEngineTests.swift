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

    func testFormatOneUploadSpansFencedBatchesWithoutMissingNotes() async throws {
        let catalog = try makeCatalog()
        let notes = try (0..<251).map { try makeNote("queued note \($0)") }
        let sender = try await open("large-format-one-sender")
        _ = try await sender.bootstrap(proposing: catalog)
        let previousBatches = server.atomicSaveBatches.count

        let result = try await sender.publishBatch(notes)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.acknowledgedIDs, Set(notes.map(\.id)))
        let batches = Array(server.atomicSaveBatches.dropFirst(previousBatches))
        XCTAssertGreaterThan(batches.count, 1)
        let canonical = CloudKitTransportMode.notebook.bootstrapName
        for batch in batches {
            XCTAssertLessThanOrEqual(batch.count, 250)
            XCTAssertEqual(batch.filter { $0 == canonical }.count, 1)
        }
        XCTAssertEqual(
            Set(batches.flatMap { $0 }.filter { $0 != canonical }),
            Set(notes.map(\.id))
        )

        let receiver = try await open("large-format-one-receiver")
        _ = try await receiver.bootstrap(proposing: catalog)
        let received = try await fetchAll(receiver).records
        XCTAssertEqual(received.count, notes.count + 1)
        XCTAssertEqual(
            Set(received.map(\.id)), Set(notes.map(\.id) + [catalog.id])
        )
        for note in notes {
            XCTAssertEqual(received.first { $0.id == note.id }, note)
        }
        await sender.retire()
        await receiver.retire()
    }

    func testFormatOneCanonicalRaceRetriesWithoutLosingNotes() async throws {
        let catalog = try makeCatalog()
        let peerNote = try makeNote("peer's independent edit")
        let localNotes = try [
            makeNote("first queued local edit"),
            makeNote("second queued local edit")
        ]
        let peer = try await open("format-one-peer")
        _ = try await peer.bootstrap(proposing: catalog)
        try await peer.publish(peerNote)
        let local = try await open("format-one-local")
        _ = try await local.bootstrap(proposing: catalog)
        let engine = try XCTUnwrap(server.latestEngine)
        engine.stopAfterFailedBatch = true
        engine.throwPartialFailureAfterFailedBatch = true
        let previousSends = engine.sendChangesCount

        // Change only the live control tag's compatibility requirement to
        // the same supported format, after the publisher reads its old tag.
        // The fake server rejects the entire stale atomic batch, and its
        // engine ends the send after that rollback, as live CloudKit can.
        server.inject(.advanceCanonicalBeforeSave(requiredVersion: 1))
        let result = try await local.publishBatch(localNotes)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.acknowledgedIDs, Set(localNotes.map(\.id)))
        XCTAssertEqual(engine.sendChangesCount - previousSends, 2)
        let halt = await local.haltStatus()
        XCTAssertNil(halt)

        let expected = Set([catalog.id, peerNote.id] + localNotes.map(\.id))
        for transport in [local, peer] {
            let received = try await fetchAll(transport).records
            XCTAssertEqual(Set(received.map(\.id)), expected)
            for note in [peerNote] + localNotes {
                XCTAssertEqual(received.first { $0.id == note.id }, note)
            }
        }
        let control = try await server.record(for: CKRecord.ID(
            recordName: CloudKitTransportMode.notebook.bootstrapName,
            zoneID: server.zoneID
        ))
        XCTAssertEqual(
            try CloudKitNotebookFormatGate.read(control).catalogFormatVersion,
            1
        )
        await local.retire()
        await peer.retire()
    }

    func testCompatibleCanonicalRaceRetryIsBoundedAndRetainsOutbox() async throws {
        let transport = try await open("bounded-canonical-race")
        _ = try await transport.bootstrap(proposing: try makeCatalog())
        let engine = try XCTUnwrap(server.latestEngine)
        engine.stopAfterFailedBatch = true
        engine.throwPartialFailureAfterFailedBatch = true
        let previousSends = engine.sendChangesCount
        for _ in 0..<CloudKitSyncTransport.maximumCanonicalPublicationAttempts {
            server.inject(.advanceCanonicalBeforeSave(requiredVersion: 1))
        }
        let note = try makeNote("retained after repeated contention")
        let result = try await transport.publishBatch([note])
        XCTAssertEqual(result.acknowledgedIDs, [])
        XCTAssertEqual(result.error as? CloudKitSyncTransportError,
                       .uploadNotAcknowledged)
        XCTAssertEqual(engine.sendChangesCount - previousSends,
                       CloudKitSyncTransport.maximumCanonicalPublicationAttempts)
        XCTAssertFalse(server.recordNames.contains(note.id))
        let state = try JSONDecoder().decode(CloudKitTransportState.self,
            from: Data(contentsOf: root.appending(path: "bounded-canonical-race")
                .appending(path: "cloudkit-sync-state.json")))
        XCTAssertEqual(state.outbox[note.id], note)
        let halt = await transport.haltStatus()
        XCTAssertNil(halt)
        let retry = try await transport.publishBatch([note])
        XCTAssertNil(retry.error)
        XCTAssertEqual(retry.acknowledgedIDs, [note.id])
        await transport.retire()
    }

    func testFutureCanonicalRaceIsRejectedWithoutAnotherSend() async throws {
        let transport = try await open("future-canonical-race")
        _ = try await transport.bootstrap(proposing: try makeCatalog())
        let engine = try XCTUnwrap(server.latestEngine)
        engine.stopAfterFailedBatch = true
        engine.throwPartialFailureAfterFailedBatch = true
        let previousSends = engine.sendChangesCount
        let note = try makeNote("must never cross the future gate")
        let future = NotebookSyncFormat.supportedVersion + 1
        server.inject(.advanceCanonicalBeforeSave(requiredVersion: future))
        let result = try await transport.publishBatch([note])
        XCTAssertEqual(result.acknowledgedIDs, [])
        XCTAssertEqual(result.error as? SyncError,
                       .updateRequired(requiredVersion: future))
        XCTAssertEqual(engine.sendChangesCount - previousSends, 1)
        XCTAssertFalse(server.recordNames.contains(note.id))
        let halt = await transport.haltStatus()
        XCTAssertNotNil(halt)
        await transport.retire()
    }

    func testAtomicQuotaFailureDoesNotTriggerCanonicalRaceRetry() async throws {
        let transport = try await open("real-atomic-failure")
        _ = try await transport.bootstrap(proposing: try makeCatalog())
        let engine = try XCTUnwrap(server.latestEngine)
        engine.stopAfterFailedBatch = true
        engine.throwPartialFailureAfterFailedBatch = true
        let previousSends = engine.sendChangesCount
        let note = try makeNote("quota rejection remains retryable later")
        server.inject(.failSave(.quotaExceeded) { $0.recordName == note.id })
        let result = try await transport.publishBatch([note])
        XCTAssertEqual(result.acknowledgedIDs, [])
        XCTAssertNotNil(result.error)
        XCTAssertEqual(engine.sendChangesCount - previousSends, 1)
        XCTAssertFalse(server.recordNames.contains(note.id))
        await transport.retire()
    }

    func testCleanupRetriesAfterPeerAlreadyDeletedOneBody() async throws {
        try await verifyCleanupRace(alreadyDeleted: true)
    }

    func testCleanupRetriesAfterCompatibleCanonicalPublication() async throws {
        try await verifyCleanupRace(alreadyDeleted: false)
    }

    private func verifyCleanupRace(alreadyDeleted: Bool) async throws {
        let document = try NotebookCatalogDocument(notebookID: notebookID)
        let deleted = try [makeNote("deleted revision one"),
                           makeNote("deleted revision two")]
        let retained = try makeNote("live note must survive cleanup")
        for note in deleted + [retained] {
            try document.add(id: note.snapshot.noteID, kind: .note,
                             name: "\(note.snapshot.noteID).md")
        }
        let transport = try await open("cleanup-device")
        _ = try await transport.bootstrap(proposing:
            SyncRecord(catalog: document.snapshot()))
        let uploaded = try await transport.publishBatch(deleted + [retained])
        XCTAssertNil(uploaded.error)
        XCTAssertEqual(uploaded.acknowledgedIDs,
            Set((deleted + [retained]).map(\.id)))
        let deletedIDs = Set(deleted.map { $0.snapshot.noteID })
        try document.markPermanentlyDeleted(deletedIDs)
        try await transport.publish(SyncRecord(catalog: document.snapshot()))
        _ = try await fetchAll(transport)

        if alreadyDeleted {
            server.inject(.deleteBeforeModify(recordName: deleted[0].id))
        } else {
            server.inject(.advanceCanonicalBeforeSave(requiredVersion: 1))
        }
        try await transport.purgeDeletedNotes(deletedIDs, notebookID: notebookID)
        XCTAssertTrue(server.recordNames.contains(retained.id))
        for note in deleted {
            XCTAssertFalse(server.recordNames.contains(note.id))
        }
        let state = try JSONDecoder().decode(CloudKitTransportState.self,
            from: Data(contentsOf: root.appending(path: "cleanup-device")
                .appending(path: "cloudkit-sync-state.json")))
        XCTAssertTrue(state.pendingRemoteDeletionIDs.isEmpty)
        let halt = await transport.haltStatus()
        XCTAssertNil(halt)
        try await transport.purgeDeletedNotes(deletedIDs, notebookID: notebookID)
        let received = try await fetchAll(transport).records
        XCTAssertEqual(received.first { $0.id == retained.id }, retained)
        XCTAssertFalse(received.contains { deletedIDs.contains($0.snapshot.noteID) })
        await transport.retire()
    }

    func testRestoredFormatOneOutboxPublishesThroughBackgroundEngine() async throws {
        let catalog = try makeCatalog()
        let note = try makeNote("queued before restart")
        let transport = try await open("background-device")
        _ = try await transport.bootstrap(proposing: catalog)
        server.inject(.failNextRead)
        let queued = try await transport.publishBatch([note])
        XCTAssertTrue(queued.acknowledgedIDs.isEmpty)
        XCTAssertFalse(server.recordNames.contains(note.id))
        await transport.retire()

        let restarted = try await open("background-device")
        let engine = try XCTUnwrap(server.latestEngine)
        let previousBatches = server.atomicSaveBatches.count
        try await engine.sendChanges(.init(scope: .zoneIDs([server.zoneID])))
        let batches = Array(server.atomicSaveBatches.dropFirst(previousBatches))
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(Set(try XCTUnwrap(batches.first)),
            [note.id, CloudKitTransportMode.notebook.bootstrapName])
        let halt = await restarted.haltStatus()
        XCTAssertNil(halt)
        let state = try JSONDecoder().decode(CloudKitTransportState.self,
            from: Data(contentsOf: root.appending(path: "background-device")
                .appending(path: "cloudkit-sync-state.json")))
        XCTAssertTrue(state.outbox.isEmpty)
        let received = try await fetchAll(restarted).records
        XCTAssertEqual(received.first { $0.id == note.id }, note)
        await restarted.retire()
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

    func testConflictIsAcknowledgedFromServerRecord() async throws {
        let note = try makeNote("shared")
        let first = try await open("device-a")
        _ = try await first.bootstrap(proposing: try makeCatalog())
        _ = try await first.publishBatch([note])
        let second = try await open("device-b")
        _ = try await second.bootstrap(proposing: try makeCatalog())

        // The publication first reads the canonical format gate. The
        // immutable snapshot conflict itself carries the server record.
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
