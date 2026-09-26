import Foundation
@testable import NoteCore
import XCTest

final class CloudKitHaltLifecycleTests: XCTestCase {
    func testOutgoingBatchStopsBeforeReadingForEveryHaltCause()
        async throws
    {
        for reason in ["fatal", "account", "remote deletion", "retired"] {
            let probe = BatchProbe()
            await probe.stop(reason: reason)
            let batch = try await CloudKitOutgoingBatchPreparer
                .assemble(
                    allowed: { await probe.allowed() },
                    readOutbox: {
                        await probe.didRead()
                        return [:]
                    },
                    stage: { _ in
                        await probe.didStage()
                        return ["id": 1]
                    },
                    construct: { _ in
                        await probe.didConstruct()
                        return 1
                    },
                    release: { ids in await probe.didRelease(ids) }
                )
            XCTAssertNil(batch)
            let counts = await probe.counts()
            XCTAssertEqual(counts.reads, 0, reason)
            XCTAssertEqual(counts.stages, 0, reason)
            XCTAssertEqual(counts.constructions, 0, reason)
        }
    }

    func testOutgoingBatchRechecksAfterSuspendedStoreRead() async throws {
        let probe = BatchProbe()
        let pause = BatchPause()
        let task = Task {
            try await CloudKitOutgoingBatchPreparer.assemble(
                allowed: { await probe.allowed() },
                readOutbox: {
                    await pause.park()
                    await probe.didRead()
                    return [:]
                },
                stage: { _ in
                    await probe.didStage()
                    return ["id": 1]
                },
                construct: { _ -> Int? in
                    await probe.didConstruct()
                    return 1
                },
                release: { ids in await probe.didRelease(ids) }
            )
        }
        await pause.waitUntilParked()
        await probe.stop(reason: "fatal")
        await pause.resume()
        let result = try await task.value
        XCTAssertNil(result)
        let counts = await probe.counts()
        XCTAssertEqual(counts.reads, 1)
        XCTAssertEqual(counts.stages, 0)
        XCTAssertEqual(counts.constructions, 0)
    }

    func testOutgoingBatchReleasesLeasesAfterSuspendedConstruction()
        async throws
    {
        let probe = BatchProbe()
        let pause = BatchPause()
        let task = Task {
            try await CloudKitOutgoingBatchPreparer.assemble(
                allowed: { await probe.allowed() },
                readOutbox: {
                    await probe.didRead()
                    return [:]
                },
                stage: { _ in
                    await probe.didStage()
                    return ["snapshot": 1]
                },
                construct: { _ -> Int? in
                    await pause.park()
                    await probe.didConstruct()
                    return 1
                },
                release: { ids in await probe.didRelease(ids) }
            )
        }
        await pause.waitUntilParked()
        await probe.stop(reason: "account")
        await pause.resume()
        let result = try await task.value
        XCTAssertNil(result)
        let counts = await probe.counts()
        XCTAssertEqual(counts.stages, 1)
        XCTAssertEqual(counts.constructions, 1)
        XCTAssertEqual(counts.released, ["snapshot"])
    }

    func testRetiredStoreRejectsLateAcknowledgementBeforeReplacementOpens()
        async throws
    {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CloudKitTransportStateStore(
            directory: directory,
            accountRecordName: "account",
            zoneName: "zone"
        )
        let record = try makeRecord()
        try await store.update { $0.outbox[record.id] = record }
        let committer = CloudKitEventCommitter(store: store)

        await store.retire()
        do {
            try await committer.commitSent([
                CloudKitAcknowledgedRecord(id: record.id, record: record)
            ])
            XCTFail("A retired writer accepted a late acknowledgement")
        } catch is CloudKitRetiredTransportError {}

        let replacement = try CloudKitTransportStateStore(
            directory: directory,
            accountRecordName: "account",
            zoneName: "zone"
        )
        let state = await replacement.snapshot()
        XCTAssertEqual(state.outbox[record.id], record)
        XCTAssertTrue(state.inbox.isEmpty)
        try await replacement.update { $0.retryNotBefore = Date() }
        do {
            try await store.update { $0.outbox.removeAll() }
            XCTFail("The old writer changed replacement state")
        } catch is CloudKitRetiredTransportError {}
        let unchanged = await replacement.snapshot()
        XCTAssertEqual(unchanged.outbox[record.id], record)
    }

    func testWriteFailureLeavesFetchedSentAndEngineStateWorkReplayable()
        async throws
    {
        for phase in ["fetched", "sent", "engine", "direct"] {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let pending = try makeRecord()
            let original = try CloudKitTransportStateStore(
                directory: directory,
                accountRecordName: "account",
                zoneName: "zone"
            )
            try await original.update { $0.outbox[pending.id] = pending }
            let failing = try CloudKitTransportStateStore(
                directory: directory,
                accountRecordName: "account",
                zoneName: "zone",
                writeState: { _, _ in throw POSIXError(.ENOSPC) }
            )
            let committer = CloudKitEventCommitter(store: failing)
            do {
                switch phase {
                case "fetched":
                    let remote = try makeRecord()
                    try await committer.commitFetched([remote])
                case "sent":
                    try await committer.commitSent([
                        CloudKitAcknowledgedRecord(
                            id: pending.id, record: pending
                        )
                    ])
                case "engine":
                    try await committer.commitEngineState(Data("new".utf8))
                default:
                    try await failing.update { $0.retryNotBefore = Date() }
                }
                XCTFail("Expected \(phase) state write to fail")
            } catch is CloudKitStateWriteFailure {}
            // Direct writes bypass the event committer. Their failure must
            // still be synchronously visible to transport health/batch gates.
            let failure = try XCTUnwrap(failing.writeHealth.failure, phase)
            XCTAssertTrue(CloudKitSyncHaltStatus(error: failure).isRecoverable)

            let reopened = try CloudKitTransportStateStore(
                directory: directory,
                accountRecordName: "account",
                zoneName: "zone"
            )
            let state = await reopened.snapshot()
            XCTAssertEqual(state.outbox[pending.id], pending, phase)
            XCTAssertTrue(state.inbox.isEmpty, phase)
            XCTAssertNil(state.engineState, phase)
            if phase == "sent" {
                // The remote upload succeeded, but its local acknowledgement
                // failed. Reconcile that same result after reconstruction.
                let replacementCommitter = CloudKitEventCommitter(store: reopened)
                let acknowledgement = CloudKitAcknowledgedRecord(
                    id: pending.id, record: pending
                )
                let first = try await replacementCommitter.commitSent([acknowledgement])
                let duplicate = try await replacementCommitter.commitSent([acknowledgement])
                XCTAssertEqual(first, 1)
                XCTAssertEqual(duplicate, 0)
                let reconciled = await reopened.snapshot()
                XCTAssertTrue(reconciled.outbox.isEmpty)
                XCTAssertEqual(reconciled.inbox, [pending])
            }
        }
    }

    func testOnlyKnownLocalWriteErrorsAllowReconstruction() {
        let noSpace = CloudKitSyncHaltStatus(error:
            CloudKitStateWriteFailure(underlyingError: POSIXError(.ENOSPC))
        )
        XCTAssertEqual(noSpace.reason, .localStorageFailure)
        XCTAssertTrue(noSpace.isRecoverable)
        XCTAssertEqual(
            (noSpace.underlyingError as NSError).code,
            Int(ENOSPC)
        )

        let unknownWrite = CloudKitSyncHaltStatus(error:
            CloudKitStateWriteFailure(underlyingError: POSIXError(.EIO))
        )
        XCTAssertEqual(unknownWrite.reason, .localStorageFailure)
        XCTAssertFalse(unknownWrite.isRecoverable)
        XCTAssertFalse(CloudKitSyncHaltStatus(
            error: CloudKitSyncTransportError.corruptState
        ).isRecoverable)
        XCTAssertEqual(CloudKitSyncHaltStatus(
            error: SyncError.scopeChanged
        ).reason, .accountChanged)
    }

    private func makeRecord() throws -> SyncRecord {
        let document = try NoteDocument(noteID: UUID())
        try document.replaceAll(with: "pending upload")
        return SyncRecord(snapshot: document.snapshot())
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "CloudKitHaltLifecycleTests-\(UUID().uuidString)"
        )
    }
}

private actor BatchProbe {
    private var stoppedReason: String?
    private var reads = 0
    private var stages = 0
    private var constructions = 0
    private var released = Set<String>()

    func allowed() -> Bool { stoppedReason == nil }
    func stop(reason: String) { stoppedReason = reason }
    func didRead() { reads += 1 }
    func didStage() { stages += 1 }
    func didConstruct() { constructions += 1 }
    func didRelease(_ ids: Set<String>) { released.formUnion(ids) }
    func counts() -> (
        reads: Int, stages: Int, constructions: Int, released: Set<String>
    ) {
        (reads, stages, constructions, released)
    }
}

private actor BatchPause {
    private var parked = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func park() async {
        parked = true
        entryWaiter?.resume()
        entryWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilParked() async {
        guard !parked else { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }

    func resume() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
