import CloudKit
import Foundation
import Observation

struct NotebookSyncState: Codable {
    var version = 2
    let scope: String
    var notebookID: UUID?
    var cursor: String?
    var appliedHeads: [String: Set<String>] = [:]
    var acknowledgedHeads: [String: Set<String>] = [:]
    var deletedIDs: Set<UUID> = []
}

/// Finite whole-notebook exchanges. Cloud scheduling can invoke this same
/// coordinator later; cursor progress always follows durable document writes.
@MainActor
@Observable
public final class NotebookSyncCoordinator {
    public enum Status: Equatable, Sendable {
        case idle
        case syncing
        case pending
        case exchanged(Date)
        case failed(String)
    }

    public private(set) var status: Status = .idle
    public private(set) var progress: NotebookSyncProgress?
    @ObservationIgnored public private(set) var lastError: (any Error)?
    @ObservationIgnored private let replica: NotebookReplica
    @ObservationIgnored private let transport: any SyncTransport
    @ObservationIgnored private let stateURL: URL
    @ObservationIgnored private let proposalURL: URL
    @ObservationIgnored private let diagnosticLog: NotebookSyncEventLog?
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private var progressMeter = NotebookSyncProgressMeter()
    @ObservationIgnored private var skippedUploadCount = 0
    @ObservationIgnored private var phaseStartedAt = ContinuousClock.now
    @ObservationIgnored private var validatedProposalCache: ValidatedProposalCache?

    public init(
        replica: NotebookReplica,
        transport: any SyncTransport,
        diagnosticLog: NotebookSyncEventLog? = nil
    ) {
        self.replica = replica
        self.transport = transport
        self.diagnosticLog = diagnosticLog
        stateURL = replica.directory.appending(path: "notebook-sync-state.json")
        proposalURL = replica.directory.appending(path: "notebook-proposal.json")
    }

    /// A local catalog is remotely joined only after its canonical V2 seed
    /// identity has been saved with this transport scope.
    public func hasDurableBinding() throws -> Bool {
        let state = try loadState()
        guard let notebookID = state.notebookID else { return false }
        return replica.catalogSnapshot?.notebookID == notebookID
    }

    /// Reads an existing local binding without account discovery or network work.
    /// A provisional state without an accepted notebook has no bound scope.
    public static func boundScope(for replica: NotebookReplica) throws -> String? {
        let url = replica.directory.appending(path: "notebook-sync-state.json")
        let state: NotebookSyncState
        do {
            state = try JSONDecoder().decode(
                NotebookSyncState.self, from: Data(contentsOf: url)
            )
        } catch CocoaError.fileReadNoSuchFile { return nil }
        guard state.version == 2,
              !state.scope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw SyncError.invalidRecord }
        guard let notebookID = state.notebookID else { return nil }
        guard replica.catalogSnapshot?.notebookID == notebookID else {
            throw SyncError.identityConflict
        }
        return state.scope
    }

    public func synchronize() async {
        guard !inFlight else { return }
        let startedAt = Date()
        inFlight = true
        progressMeter = NotebookSyncProgressMeter()
        skippedUploadCount = 0
        progress = nil
        status = .syncing
        lastError = nil
        diagnosticLog?.record("pass_start")
        updateProgress(
            phase: .checking,
            receivedRecords: 0,
            completedNotes: 0,
            totalNotes: 0
        )
        defer {
            inFlight = false
            if let previous = progress {
                progress = NotebookSyncProgress(
                    phase: previous.phase,
                    receivedRecords: previous.receivedRecords,
                    completedNotes: previous.completedNotes,
                    totalNotes: previous.totalNotes,
                    lastProgressAt: previous.lastProgressAt,
                    overallFraction: previous.overallFraction,
                    completedUnits: previous.completedUnits,
                    totalUnits: previous.totalUnits
                )
            }
        }
        await transport.setReceiveActivityHandler { [weak self] activity in
            await self?.updateReceiveActivity(activity)
        }
        await transport.setCleanupProgressHandler { [weak self] work in
            await self?.updateCleanupProgress(work)
        }
        await transport.setDiagnosticsHandler { [weak diagnosticLog] event, counts in
            await diagnosticLog?.record(event, counts: counts)
        }
        do {
            try await exchange()
            let isPending = status == .pending
            diagnosticLog?.record(
                "pass_end",
                counts: [
                    "durationMilliseconds": Self.durationMilliseconds(since: startedAt),
                    "pending": isPending ? 1 : 0,
                ]
            )
            if isPending { diagnosticLog?.record("pass_pending") }
            progress = nil
        } catch {
            let failure = namedOversizedError(error)
            lastError = failure
            diagnosticLog?.record(
                "pass_error:" + NotebookSyncEventLog.errorCode(failure),
                counts: [
                    "durationMilliseconds": Self.durationMilliseconds(since: startedAt)
                ]
            )
            status = .failed(failure.localizedDescription)
        }
        await transport.endExchange()
        await transport.setReceiveActivityHandler(nil)
        await transport.setCleanupProgressHandler(nil)
        await transport.setDiagnosticsHandler(nil)
        await diagnosticLog?.flush()
    }

    /// Reads only local transport metadata; it never discovers cleanup plans.
    public func snapshotMaintenanceStatus() async throws -> SyncSnapshotMaintenanceStatus? {
        guard let notebookID = try loadState().notebookID else { return nil }
        return try await transport.snapshotMaintenanceStatus(notebookID: notebookID)
    }

    /// Optional maintenance owns no sync progress or successful-exchange state.
    /// The workspace cancels and awaits this task before starting another sync.
    public func cleanupSnapshots() async throws -> SyncSnapshotCleanupReport {
        guard !inFlight, case .exchanged = status,
              let notebookID = try loadState().notebookID else {
            throw SyncError.unavailable("Sync notes before cleaning up iCloud copies.")
        }
        try Task.checkCancellation()
        inFlight = true
        defer { inFlight = false }
        await transport.setDiagnosticsHandler { [weak diagnosticLog] event, counts in
            await diagnosticLog?.record(event, counts: counts)
        }
        diagnosticLog?.record("snapshot_maintenance_start")
        do {
            let report = try await transport.cleanupRedundantSnapshots(notebookID: notebookID)
            diagnosticLog?.record("snapshot_maintenance_end", counts: [
                "deleted": report.deletedSnapshotCount,
                "compressedBytes": report.deletedCompressedPayloadBytes,
            ])
            await transport.setDiagnosticsHandler(nil)
            await diagnosticLog?.flush()
            return report
        } catch {
            diagnosticLog?.record("snapshot_maintenance_error:" + NotebookSyncEventLog.errorCode(error))
            await transport.setDiagnosticsHandler(nil)
            await diagnosticLog?.flush()
            throw error
        }
    }

    private func namedOversizedError(_ error: any Error) -> any Error {
        guard let failure = error as? CloudKitSyncTransportError,
              case let .snapshotTooLarge(documentID, kind, _) = failure else {
            return error
        }
        var displayName: String?
        if let snapshot = replica.catalogSnapshot,
           let catalog = try? NotebookCatalogDocument(snapshot: snapshot) {
            if documentID == snapshot.notebookID {
                displayName = "Notebook catalog"
            } else if let items = try? catalog.items() {
                displayName = items.first { $0.id == documentID }?.name
            }
        }
        return CloudKitSyncTransportError.snapshotTooLarge(
            documentID: documentID, kind: kind, displayName: displayName
        )
    }

    private func exchange() async throws {
        try await replica.load()
        var state = try loadState()
        try replica.validateOfflineJoinScope(transport.scope)
        diagnosticLog?.record(
            "checkpoints_loaded",
            counts: [
                "acknowledgedDocuments": state.acknowledgedHeads.count,
                "appliedDocuments": state.appliedHeads.count,
                "cursorPresent": state.cursor == nil ? 0 : 1,
            ]
        )
        // Bind before any network mutation. Deletions survive a catalog
        // rollback and are reapplied before old files can be republished.
        try await replica.rememberDeletions(state.deletedIDs)
        state.deletedIDs.formUnion(try replica.deletedIDs)
        try save(state)
        let proposal = try durableProposal()
        let bootstrapRecord =
            replica.catalogSnapshot.map { SyncRecord(catalog: $0) } ?? proposal.record
        if let expected = state.notebookID, expected != bootstrapRecord.notebookID {
            throw SyncError.identityConflict
        }
        updateProgress(phase: .checking, waiting: true)
        diagnosticLog?.record("bootstrap_start")
        let seed = try await transport.bootstrap(proposing: bootstrapRecord)
        diagnosticLog?.record("bootstrap_end")
        updateProgress(phase: .checking)
        guard seed.protocolVersion == 2, seed.kind == .catalog,
            let notebookID = seed.notebookID
        else { throw SyncError.invalidRecord }
        if let expected = state.notebookID, expected != notebookID {
            throw SyncError.identityConflict
        }
        // Acceptance validates the record or reuses an exact, durable match.
        if state.notebookID == nil {
            try await replica.acceptFirstSyncSeed(seed, scope: transport.scope)
        } else {
            try await replica.acceptSeed(seed)
        }
        state.notebookID = notebookID
        try save(state)
        try replica.completeFirstSyncJoin(scope: transport.scope, notebookID: notebookID)
        let remembered = state.deletedIDs.union(try replica.deletedIDs)
        let checkpoints = state.appliedHeads.merging(state.acknowledgedHeads) { $0.union($1) }
        diagnosticLog?.record("history_check_start", counts: ["checkpoints": checkpoints.count])
        let hasHistory = try await replica.containsHistory(
            checkpoints, deleted: remembered,
            scanProgress: { [weak self] completed, total in
                self?.updateProgress(
                    phase: .checking, phaseFraction: 0.5 * Self.fraction(completed, total),
                    completedUnits: completed, totalUnits: total
                )
            },
            progress: { [weak self] completed, total in
                self?.updateProgress(
                    phase: .checking, phaseFraction: 0.5 + 0.5 * Self.fraction(completed, total),
                    completedUnits: completed, totalUnits: total
                )
            }
        )
        diagnosticLog?.record("history_check_end", counts: ["matched": hasHistory ? 1 : 0])
        if !hasHistory {
            diagnosticLog?.record("replay_missing_history")
            state.cursor = nil
            state.appliedHeads = [:]
            state.acknowledgedHeads = [:]
            try save(state)
        }

        try await transport.beginExchange()
        var replayedInvalidCursor = false
        var pages = 0
        updateProgress(phase: .receiving, waiting: true)
        while true {
            try Task.checkCancellation()
            let page: SyncPage
            updateProgress(phase: .receiving, waiting: true, clearUnits: true)
            diagnosticLog?.record("page_fetch_start", counts: ["page": pages + 1])
            do { page = try await transport.fetch(after: state.cursor) } catch SyncError
                .invalidCursor where !replayedInvalidCursor
            {
                diagnosticLog?.record("replay_invalid_cursor")
                state.cursor = nil
                try save(state)
                replayedInvalidCursor = true
                continue
            }
            diagnosticLog?.record("page_fetch_returned", counts: [
                "page": pages + 1, "records": page.records.count,
                "hasMore": page.hasMore ? 1 : 0,
            ])
            updateProgress(phase: .receiving, completedUnits: 0, totalUnits: page.records.count)
            var applied = 0
            for record in page.records {
                updateProgress(
                    phase: .receiving,
                    activeNoteIDs: record.kind == .note ? [record.snapshot.noteID] : []
                )
                try await replica.apply(record)
                applied += 1
                updateProgress(
                    phase: .receiving,
                    receivedRecords: (progress?.receivedRecords ?? 0) + 1,
                    // Only the final page has a known remaining denominator.
                    // Leave room for the durable page checkpoint below.
                    phaseFraction: page.hasMore ? nil
                        : 0.9 * Self.fraction(applied, page.records.count),
                    completedUnits: applied, totalUnits: page.records.count
                )
            }
            if page.hasMore && page.cursor == state.cursor { throw SyncError.invalidCursor }
            let persisted = try await replica.records(includeUnlisted: true)
            let persistedByKey = Dictionary(
                uniqueKeysWithValues: persisted.map { ($0.documentKey, $0) })
            var exactAcknowledgements = 0
            for record in page.records
            where persistedByKey[record.documentKey]?.snapshot.heads == record.snapshot.heads {
                state.acknowledgedHeads[record.documentKey] = record.snapshot.heads
                exactAcknowledgements += 1
            }
            state.appliedHeads = Dictionary(
                uniqueKeysWithValues: persisted.map { ($0.documentKey, $0.snapshot.heads) })
            state.deletedIDs.formUnion(try replica.deletedIDs)
            state.cursor = page.cursor
            try save(state)
            diagnosticLog?.record(
                "page_received",
                counts: [
                    "exactAcknowledgements": exactAcknowledgements,
                    "records": page.records.count,
                ]
            )
            pages += 1
            if !page.hasMore {
                updateProgress(phase: .receiving, phaseFraction: 1)
                break
            }
            if pages >= 1_000 {
                throw SyncError.unavailable(
                    "Notebook sync paused after too many pages. Retry to continue.")
            }
        }

        updateProgress(phase: .comparing)
        diagnosticLog?.record("outgoing_scan_start")
        let outgoing = try await replica.records(progress: { [weak self] completed, total in
            self?.updateProgress(
                phase: .comparing, phaseFraction: Self.fraction(completed, total),
                completedUnits: completed, totalUnits: total
            )
        })
        diagnosticLog?.record("outgoing_scan_end", counts: ["records": outgoing.count])
        let pendingNotes = outgoing.filter {
            $0.kind == .note
                && state.acknowledgedHeads[$0.documentKey] != $0.snapshot.heads
        }
        let pendingCatalog = outgoing.first {
            $0.kind == .catalog
                && state.acknowledgedHeads[$0.documentKey] != $0.snapshot.heads
        }
        let notes = outgoing.filter { $0.kind == .note }
        let noAcknowledgement = notes.filter {
            state.acknowledgedHeads[$0.documentKey] == nil
        }.count
        let changedSinceAcknowledgement = notes.filter {
            guard let acknowledged = state.acknowledgedHeads[$0.documentKey] else {
                return false
            }
            return acknowledged != $0.snapshot.heads
        }.count
        let matchingAppliedWithoutAcknowledgement = notes.filter {
            state.acknowledgedHeads[$0.documentKey] == nil
                && state.appliedHeads[$0.documentKey] == $0.snapshot.heads
        }.count
        diagnosticLog?.record(
            "pending_notes",
            counts: [
                "changedSinceAcknowledgement": changedSinceAcknowledgement,
                "matchingAppliedWithoutAcknowledgement":
                    matchingAppliedWithoutAcknowledgement,
                "noAcknowledgement": noAcknowledgement,
                "total": pendingNotes.count,
            ]
        )
        updateProgress(
            phase: .uploadingNotes,
            completedNotes: 0,
            totalNotes: pendingNotes.count,
            phaseFraction: pendingNotes.isEmpty ? 1 : 0,
            completedUnits: 0, totalUnits: pendingNotes.count
        )
        var oversizedError: CloudKitSyncTransportError?
        for start in stride(from: 0, to: pendingNotes.count, by: 50) {
            try Task.checkCancellation()
            let end = min(start + 50, pendingNotes.count)
            let capturedBatch = Array(pendingNotes[start..<end])
            let deleted = try replica.deletedIDs
            let batch = capturedBatch.filter { !deleted.contains($0.snapshot.noteID) }
            let skipped = capturedBatch.count - batch.count
            if skipped > 0 {
                skippedUploadCount += skipped
                state.deletedIDs.formUnion(deleted)
                try save(state)
                updateProgress(
                    phase: .uploadingNotes,
                    totalNotes: max(0, (progress?.totalNotes ?? 0) - skipped),
                    phaseFraction: Self.fraction(
                        (progress?.completedNotes ?? 0) + skippedUploadCount, pendingNotes.count
                    ),
                    completedUnits: (progress?.completedNotes ?? 0) + skippedUploadCount
                )
            }
            guard !batch.isEmpty else { continue }
            do {
                updateProgress(
                    phase: .uploadingNotes,
                    activeNoteIDs: batch.map { $0.snapshot.noteID }
                )
                try await publish(
                    batch,
                    state: &state,
                    completedNoteCount: batch.count
                )
            } catch let error as CloudKitSyncTransportError {
                guard case .snapshotTooLarge = error else { throw error }
                oversizedError = oversizedError ?? error
            }
        }
        if let pendingCatalog {
            updateProgress(phase: .uploadingCatalog)
            try await publish([pendingCatalog], state: &state, completedNoteCount: 0)
        }
        updateProgress(phase: .uploadingCatalog, phaseFraction: 1)
        state.deletedIDs.formUnion(try replica.deletedIDs)
        try save(state)
        // Purge only identities represented by a remotely acknowledged catalog.
        // A deletion made during an upload remains pending until its own marker
        // has been published; removing its body earlier could strand a peer.
        if let publishedCatalog = outgoing.first(where: { $0.kind == .catalog }),
            state.acknowledgedHeads[publishedCatalog.documentKey]
                == publishedCatalog.snapshot.heads,
            let snapshot = publishedCatalog.catalogSnapshot
        {
            let deleted = Set(try NotebookCatalogDocument(snapshot: snapshot)
                .items().filter(\.isPermanentlyDeleted).map(\.id))
            if !deleted.isEmpty {
                updateProgress(phase: .cleaningUp, cleanupItemCount: deleted.count)
                diagnosticLog?.record("deletion_cleanup_start", counts: ["items": deleted.count])
                try await transport.purgeDeletedNotes(deleted, notebookID: notebookID)
                diagnosticLog?.record("deletion_cleanup_end", counts: ["items": deleted.count])
            }
        }
        if let oversizedError { throw oversizedError }
        updateProgress(phase: .finalizing)
        diagnosticLog?.record("final_scan_start")
        let current = try await replica.records(progress: { [weak self] completed, total in
            self?.updateProgress(
                phase: .finalizing, phaseFraction: Self.fraction(completed, total),
                completedUnits: completed, totalUnits: total
            )
        })
        diagnosticLog?.record("final_scan_end", counts: ["records": current.count])
        status =
            current.allSatisfy { state.acknowledgedHeads[$0.documentKey] == $0.snapshot.heads }
            ? .exchanged(Date()) : .pending
        if case .exchanged = status { progressMeter.finish() }
    }

    private func publish(
        _ records: [SyncRecord],
        state: inout NotebookSyncState,
        completedNoteCount: Int
    ) async throws {
        let expectedIDs = Set(records.map(\.id))
        guard expectedIDs.count == records.count else { throw SyncError.invalidRecord }
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        let startEvent = completedNoteCount > 0 ? "note_batch_start" : "catalog_batch_start"
        let resultEvent = completedNoteCount > 0 ? "note_batch_result" : "catalog_batch_result"
        diagnosticLog?.record(startEvent, counts: ["requested": records.count])
        let result: SyncBatchResult
        do {
            result = try await transport.publishBatch(records)
        } catch {
            diagnosticLog?.record(
                resultEvent,
                counts: ["acknowledged": 0, "error": 1, "requested": records.count]
            )
            throw error
        }
        diagnosticLog?.record(
            resultEvent,
            counts: [
                "acknowledged": result.acknowledgedIDs.count,
                "error": result.error == nil ? 0 : 1,
                "requested": records.count,
            ]
        )
        guard result.acknowledgedIDs.isSubset(of: expectedIDs) else {
            throw SyncError.invalidRecord
        }
        for id in result.acknowledgedIDs {
            guard let record = byID[id] else { throw SyncError.invalidRecord }
            state.acknowledgedHeads[record.documentKey] = record.snapshot.heads
        }
        if !result.acknowledgedIDs.isEmpty {
            state.deletedIDs.formUnion(try replica.deletedIDs)
            try save(state)
            diagnosticLog?.record("batch_checkpoint_saved", counts: [
                "acknowledged": result.acknowledgedIDs.count
            ])
            if completedNoteCount > 0 {
                updateProgress(
                    phase: .uploadingNotes,
                    completedNotes: (progress?.completedNotes ?? 0)
                        + result.acknowledgedIDs.count,
                    phaseFraction: Self.fraction(
                        (progress?.completedNotes ?? 0) + result.acknowledgedIDs.count
                            + skippedUploadCount,
                        progress?.totalUnits ?? progress?.totalNotes ?? 0
                    ),
                    completedUnits: (progress?.completedNotes ?? 0)
                        + result.acknowledgedIDs.count + skippedUploadCount
                )
            }
        }
        if let error = result.error { throw error }
        guard result.acknowledgedIDs == expectedIDs else {
            throw SyncError.unavailable("The sync service did not acknowledge every record.")
        }
    }

    private func updateProgress(
        phase: NotebookSyncProgress.Phase,
        receivedRecords: Int? = nil,
        completedNotes: Int? = nil,
        totalNotes: Int? = nil,
        activeNoteIDs: [UUID] = [],
        cleanupItemCount: Int? = nil,
        phaseFraction: Double? = nil,
        completedUnits: Int? = nil,
        totalUnits: Int? = nil,
        waiting: Bool = false,
        clearUnits: Bool = false
    ) {
        let previous = progress
        let phaseChanged = previous?.phase != phase
        if phaseChanged {
            if let previous {
                let elapsed = phaseStartedAt.duration(to: .now).components
                diagnosticLog?.record("phase_end:" + previous.phase.rawValue, counts: [
                    "duration_ms": Int(elapsed.seconds * 1_000
                        + elapsed.attoseconds / 1_000_000_000_000_000)
                ])
            }
            phaseStartedAt = .now
            diagnosticLog?.record("phase_start:" + phase.rawValue)
        }
        progress = NotebookSyncProgress(
            phase: phase,
            receivedRecords: receivedRecords ?? progress?.receivedRecords ?? 0,
            completedNotes: completedNotes ?? progress?.completedNotes ?? 0,
            totalNotes: totalNotes ?? progress?.totalNotes ?? 0,
            lastProgressAt: Date(),
            activeNoteIDs: activeNoteIDs,
            cleanupItemCount: cleanupItemCount ?? (phaseChanged ? 0 : previous?.cleanupItemCount ?? 0),
            overallFraction: progressMeter.advance(phase: phase, completion: phaseFraction),
            completedUnits: completedUnits ?? (phaseChanged || clearUnits ? nil : previous?.completedUnits),
            totalUnits: totalUnits ?? (phaseChanged || clearUnits ? nil : previous?.totalUnits),
            waitingSince: waiting ? previous?.waitingSince ?? Date() : nil
        )
    }

    private func updateReceiveActivity(_ activity: SyncReceiveActivity) {
        guard inFlight, let phase = progress?.phase,
              phase == .receiving || phase == .checkingRemoteHistory else { return }
        updateProgress(
            phase: .checkingRemoteHistory,
            waiting: activity == .waitingForCloud, clearUnits: true
        )
    }

    private func updateCleanupProgress(_ work: SyncCleanupProgress) {
        guard inFlight, let phase = progress?.phase,
              phase == .cleaningUp || phase == .cleaningUpSnapshots else { return }
        let completion = Self.fraction(work.completedCount, work.totalCount)
        let phaseFraction = phase == .cleaningUp ? completion
            : work.stage == .survivorVerification ? completion * 0.5 : 0.5 + completion * 0.5
        updateProgress(phase: phase, phaseFraction: phaseFraction,
                       completedUnits: work.completedCount, totalUnits: work.totalCount)
    }

    private static func fraction(_ completed: Int, _ total: Int) -> Double {
        total > 0 ? min(1, max(0, Double(completed) / Double(total))) : 1
    }

    private static func durationMilliseconds(since start: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(start) * 1_000))
    }

    /// Unknown keys are ignored, so proposals written by builds that still
    /// migrated the single-note app decode without their obsolete fields.
    private struct Proposal: Codable {
        let scope: String
        let record: SyncRecord
    }

    private struct ValidatedProposalCache {
        let serialized: Data
        let proposal: Proposal
    }

    /// Fields of the retired single-note migration. They can hold a note
    /// body, so they are scrubbed rather than left on disk.
    private static let legacyProposalKeys = ["legacyNote", "retiredLegacyNoteID"]

    private static func containsLegacyFields(_ data: Data) throws -> Bool {
        guard let object = try JSONSerialization.jsonObject(with: data)
            as? [String: Any] else { throw SyncError.invalidRecord }
        return legacyProposalKeys.contains { object[$0] != nil }
    }

    /// Remove a single-note body left in the proposal by an older build,
    /// e.g. after permanent deletion, even when cloud setup is unavailable.
    static func removeLegacyProposalBody(in directory: URL) throws {
        let url = directory.appending(path: "notebook-proposal.json")
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch CocoaError.fileReadNoSuchFile { return }
        guard try containsLegacyFields(data) else { return }
        let proposal = try JSONDecoder().decode(Proposal.self, from: data)
        try proposal.record.validate()
        try SyncFileIO.replace(JSONEncoder().encode(proposal), at: url)
    }

    private func durableProposal() throws -> Proposal {
        var serialized: Data
        let proposal: Proposal
        do {
            serialized = try Data(contentsOf: proposalURL)
            if let cached = validatedProposalCache,
                cached.serialized == serialized
            {
                proposal = cached.proposal
            } else {
                validatedProposalCache = nil
                let stored = try JSONDecoder().decode(
                    Proposal.self, from: serialized)
                guard stored.scope == transport.scope else {
                    throw SyncError.scopeChanged
                }
                guard stored.record.protocolVersion == 2,
                    stored.record.kind == .catalog
                else { throw SyncError.invalidRecord }
                try stored.record.validate()
                if try Self.containsLegacyFields(serialized) {
                    serialized = try JSONEncoder().encode(stored)
                    try SyncFileIO.replace(serialized, at: proposalURL)
                }
                proposal = stored
            }
        } catch CocoaError.fileReadNoSuchFile {
            validatedProposalCache = nil
            let snapshot: NotebookCatalogSnapshot
            if let existing = replica.catalogSnapshot {
                snapshot = existing
            } else {
                snapshot = try NotebookCatalogDocument().snapshot()
            }
            proposal = Proposal(
                scope: transport.scope,
                record: SyncRecord(catalog: snapshot)
            )
            try proposal.record.validate()
            serialized = try JSONEncoder().encode(proposal)
            try SyncFileIO.replace(serialized, at: proposalURL)
        }
        guard proposal.scope == transport.scope else { throw SyncError.scopeChanged }
        guard proposal.record.protocolVersion == 2, proposal.record.kind == .catalog else {
            throw SyncError.invalidRecord
        }
        // Count both the freshly read JSON and the decoded snapshot retained
        // by the proposal. Oversized catalogs are validated on every pass.
        let retainedBytes = serialized.count + proposal.record.snapshot.data.count
            + proposal.record.snapshot.heads.count * 128
        if retainedBytes <= 16 * 1_024 * 1_024 {
            validatedProposalCache = ValidatedProposalCache(
                serialized: serialized,
                proposal: proposal
            )
        } else {
            validatedProposalCache = nil
        }
        return proposal
    }

    private func loadState() throws -> NotebookSyncState {
        let state: NotebookSyncState
        do {
            state = try JSONDecoder().decode(
                NotebookSyncState.self, from: Data(contentsOf: stateURL))
        } catch CocoaError.fileReadNoSuchFile { return NotebookSyncState(scope: transport.scope) }
        guard state.version == 2 else { throw SyncError.invalidRecord }
        guard state.scope == transport.scope else { throw SyncError.scopeChanged }
        if let current = replica.catalogSnapshot, let expected = state.notebookID,
            current.notebookID != expected
        {
            throw SyncError.identityConflict
        }
        return state
    }

    private func save(_ state: NotebookSyncState) throws {
        try SyncFileIO.replace(JSONEncoder().encode(state), at: stateURL)
    }
}
