import Foundation
import NoteCore

#if DEBUG
/// A per-run in-memory transport for the sync status UI fixture.
/// Delays expose real coordinator phases long enough for UI automation and
/// screen recordings to capture them.
actor NotebookSyncStatusPreviewTransport: SyncTransport {
    nonisolated let scope: String
    private let base: InMemorySyncTransport
    private let phaseDelay: Duration
    private let retryDeadline: Date?
    private var receiveActivityHandler: SyncReceiveActivityHandler?

    init(
        runID: String,
        phaseDelay: Duration = .seconds(5),
        retryNotBefore: Date? = nil
    ) {
        scope = "sync-status-preview-\(runID)"
        base = InMemorySyncTransport(
            scope: scope,
            store: InMemorySyncStore(),
            pageSize: 2
        )
        self.phaseDelay = phaseDelay
        retryDeadline = retryNotBefore
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
        try await pause()
        return try await base.publishBatch(records)
    }

    func fetch(after cursor: String?) async throws -> SyncPage {
        try await pause()
        await receiveActivityHandler?(.checkingHistory)
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

    private func pause() async throws {
        try await Task.sleep(for: phaseDelay)
    }
}
#endif
