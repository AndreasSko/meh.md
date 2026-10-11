import Foundation
import NoteCore

#if DEBUG
/// A per-run in-memory transport for the sync status UI fixture.
/// Optional acknowledgements hold real coordinator phases until UI automation
/// has observed them; ordinary preview recordings retain timed progression.
actor NotebookSyncStatusPreviewTransport: SyncTransport {
    nonisolated let scope: String
    private let base: InMemorySyncTransport
    private let phaseDelay: Duration
    private let retryDeadline: Date?
    private let usesAcknowledgements: Bool
    private var acknowledgements = 0
    private var didGateFetch = false
    private var didGateUpload = false
    private var receiveActivityHandler: SyncReceiveActivityHandler?

    init(
        runID: String,
        phaseDelay: Duration = .seconds(5),
        retryNotBefore: Date? = nil,
        usesAcknowledgements: Bool = false
    ) {
        scope = "sync-status-preview-\(runID)"
        base = InMemorySyncTransport(
            scope: scope,
            store: InMemorySyncStore(),
            pageSize: 2
        )
        self.phaseDelay = phaseDelay
        retryDeadline = retryNotBefore
        self.usesAcknowledgements = usesAcknowledgements
    }

    func bootstrap(proposing record: SyncRecord) async throws -> SyncRecord {
        try await pause()
        return try await base.bootstrap(proposing: record)
    }

    func publish(_ record: SyncRecord) async throws {
        try await pause()
        try await base.publish(record)
    }

    func publishBatch(_ records: [SyncRecord]) async throws -> SyncBatchResult {
        if usesAcknowledgements, !didGateUpload {
            didGateUpload = true
            try await waitForAcknowledgement(3)
        }
        try await pause()
        return try await base.publishBatch(records)
    }

    func fetch(after cursor: String?) async throws -> SyncPage {
        let gate = usesAcknowledgements && !didGateFetch
        didGateFetch = true
        if gate { try await waitForAcknowledgement(1) }
        try await pause()
        await receiveActivityHandler?(.checkingHistory)
        if gate { try await waitForAcknowledgement(2) }
        try await pause()
        return try await base.fetch(after: cursor)
    }

    func setReceiveActivityHandler(
        _ handler: SyncReceiveActivityHandler?
    ) async {
        receiveActivityHandler = handler
    }

    func purgeDeletedNotes(
        _ noteIDs: Set<UUID>, notebookID: UUID
    ) async throws {
        try await pause()
        try await base.purgeDeletedNotes(noteIDs, notebookID: notebookID)
    }

    func cleanupRedundantSnapshots(
        notebookID: UUID
    ) async throws -> SyncSnapshotCleanupReport {
        try await pause()
        return try await base.cleanupRedundantSnapshots(notebookID: notebookID)
    }

    func retryNotBefore() async -> Date? { retryDeadline }

    func acknowledgePhase() { acknowledgements += 1 }

    private func waitForAcknowledgement(_ count: Int) async throws {
        // Polling yields the actor and remains cancellation-aware. Elapsed
        // time never releases a phase; only a UI test acknowledgement does.
        while acknowledgements < count {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func pause() async throws {
        try Task.checkCancellation()
        guard !usesAcknowledgements else { return }
        try await Task.sleep(for: phaseDelay)
    }
}
#endif
