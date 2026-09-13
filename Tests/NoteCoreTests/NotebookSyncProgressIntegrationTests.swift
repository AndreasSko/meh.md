import Foundation
import XCTest

@testable import NoteCore

@MainActor
final class NotebookSyncProgressIntegrationTests: XCTestCase {
    func testHTTPBatchingLeavesConcurrentEditPendingThenAcknowledgesIt()
        async throws
    {
        guard
            let endpoint = ProcessInfo.processInfo.environment[
                "MEH_NOTEBOOK_HTTP_URL"
            ],
            let url = URL(string: endpoint),
            url.host == "127.0.0.1"
        else {
            throw XCTSkip(
                "Set MEH_NOTEBOOK_HTTP_URL to a disposable loopback service"
            )
        }

        let root = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let base = LocalSyncTransport(
            baseURL: url,
            workspace: "batch-progress-\(UUID().uuidString)",
            protocolVersion: 2
        )
        let transport = PausingHTTPBatchTransport(base: base)
        let local = NotebookReplica(directory: root.appending(path: "local"))
        let coordinator = NotebookSyncCoordinator(
            replica: local,
            transport: transport
        )
        await coordinator.synchronize()
        try assertExchanged(coordinator.status)

        for index in 0..<51 {
            _ = try await local.createNote(
                name: "Note \(index).md",
                text: "revision one \(index)"
            )
        }

        let firstPass = Task { await coordinator.synchronize() }
        let captured = await transport.waitForFirstFullNoteBatch()
        XCTAssertEqual(captured.count, 50)
        XCTAssertEqual(coordinator.progress?.phase, .uploadingNotes)
        XCTAssertEqual(coordinator.progress?.completedNotes, 0)
        XCTAssertEqual(coordinator.progress?.totalNotes, 51)

        let editedRecord = try XCTUnwrap(captured.first)
        do {
            let editor = try await local.openNote(editedRecord.snapshot.noteID)
            try editor.replaceAll(with: "revision two while uploading")
            try await editor.flush()
            await transport.resumeFirstFullNoteBatch()
        } catch {
            await transport.resumeFirstFullNoteBatch()
            throw error
        }
        await firstPass.value

        guard case .pending = coordinator.status else {
            return XCTFail("The newer local revision should remain pending")
        }
        XCTAssertNil(coordinator.progress)
        let firstPassNoteBatchSizes = await transport.noteBatchSizes()
        XCTAssertEqual(firstPassNoteBatchSizes, [50, 1])

        await coordinator.synchronize()
        try assertExchanged(coordinator.status)
        XCTAssertNil(coordinator.progress)
        let acknowledgedNoteBatchSizes = await transport.noteBatchSizes()
        XCTAssertEqual(acknowledgedNoteBatchSizes, [50, 1, 1])

        let remote = NotebookReplica(directory: root.appending(path: "remote"))
        let remoteCoordinator = NotebookSyncCoordinator(
            replica: remote,
            transport: base
        )
        await remoteCoordinator.synchronize()
        try assertExchanged(remoteCoordinator.status)
        XCTAssertEqual(
            remote.placements.filter { $0.item.kind == .note }.count,
            51
        )
        let remoteEditor = try await remote.openNote(
            editedRecord.snapshot.noteID
        )
        XCTAssertEqual(remoteEditor.text, "revision two while uploading")

        let priorBatches = await transport.allBatchCount()
        await coordinator.synchronize()
        try assertExchanged(coordinator.status)
        XCTAssertNil(coordinator.progress)
        let finalBatchCount = await transport.allBatchCount()
        XCTAssertEqual(finalBatchCount, priorBatches)
    }

    private func assertExchanged(
        _ status: NoteSyncCoordinator.Status
    ) throws {
        guard case .exchanged = status else {
            XCTFail("Expected an acknowledged sync, got \(status)")
            throw SyncError.unavailable("Expected an acknowledged sync")
        }
    }
}

private actor PausingHTTPBatchTransport: SyncTransport {
    nonisolated let scope: String

    private let base: LocalSyncTransport
    private var batches: [[SyncRecord]] = []
    private var firstFullNoteBatch: [SyncRecord]?
    private var firstBatchWaiter: CheckedContinuation<[SyncRecord], Never>?
    private var firstBatchRelease: CheckedContinuation<Void, Never>?
    private var shouldPauseFirstFullNoteBatch = true

    init(base: LocalSyncTransport) {
        self.base = base
        scope = base.scope
    }

    func bootstrap(proposing record: SyncRecord) async throws -> SyncRecord {
        try await base.bootstrap(proposing: record)
    }

    func publish(_ record: SyncRecord) async throws {
        try await base.publish(record)
    }

    func publishBatch(
        _ records: [SyncRecord]
    ) async throws -> SyncBatchResult {
        batches.append(records)
        if shouldPauseFirstFullNoteBatch,
            records.count == 50,
            records.allSatisfy({ $0.kind == .note })
        {
            shouldPauseFirstFullNoteBatch = false
            firstFullNoteBatch = records
            firstBatchWaiter?.resume(returning: records)
            firstBatchWaiter = nil
            await withCheckedContinuation { continuation in
                firstBatchRelease = continuation
            }
        }
        return try await base.publishBatch(records)
    }

    func fetch(after cursor: String?) async throws -> SyncPage {
        try await base.fetch(after: cursor)
    }

    func retryNotBefore() async -> Date? {
        await base.retryNotBefore()
    }

    func waitForFirstFullNoteBatch() async -> [SyncRecord] {
        if let firstFullNoteBatch { return firstFullNoteBatch }
        return await withCheckedContinuation { continuation in
            firstBatchWaiter = continuation
        }
    }

    func resumeFirstFullNoteBatch() {
        firstBatchRelease?.resume()
        firstBatchRelease = nil
    }

    func noteBatchSizes() -> [Int] {
        batches.filter { $0.allSatisfy { $0.kind == .note } }.map(\.count)
    }

    func allBatchCount() -> Int { batches.count }
}
