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
    var adoptedLegacyHeads: Set<String>?
}

/// Finite whole-notebook exchanges. Cloud scheduling can invoke this same
/// coordinator later; cursor progress always follows durable document writes.
@MainActor
@Observable
public final class NotebookSyncCoordinator {
    public private(set) var status: NoteSyncCoordinator.Status = .idle
    public private(set) var progress: NotebookSyncProgress?
    @ObservationIgnored public private(set) var lastError: (any Error)?
    @ObservationIgnored private let replica: NotebookReplica
    @ObservationIgnored private let transport: any SyncTransport
    @ObservationIgnored private let stateURL: URL
    @ObservationIgnored private let proposalURL: URL
    @ObservationIgnored private let diagnosticLog: NotebookSyncEventLog?
    @ObservationIgnored private var inFlight = false

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

    public func synchronize(legacyNote: NoteSnapshot? = nil) async {
        guard !inFlight else { return }
        let startedAt = Date()
        inFlight = true
        status = .syncing
        lastError = nil
        diagnosticLog?.record("pass_start")
        updateProgress(
            phase: .checking,
            receivedRecords: 0,
            completedNotes: 0,
            totalNotes: 0
        )
        defer { inFlight = false }
        do {
            try await exchange(legacyNote: legacyNote)
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
            lastError = error
            diagnosticLog?.record(
                "pass_error:" + NotebookSyncEventLog.errorCode(error),
                counts: [
                    "durationMilliseconds": Self.durationMilliseconds(since: startedAt)
                ]
            )
            status = .failed(error.localizedDescription)
        }
    }

    private func exchange(legacyNote: NoteSnapshot?) async throws {
        try await replica.load()
        var state = try loadState()
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
        let proposal = try durableProposal(legacyNote: legacyNote)
        let bootstrapRecord =
            replica.catalogSnapshot.map { SyncRecord(catalog: $0) } ?? proposal.record
        if let expected = state.notebookID, expected != bootstrapRecord.notebookID {
            throw SyncError.identityConflict
        }
        let seed = try await transport.bootstrap(proposing: bootstrapRecord)
        try seed.validate()
        guard seed.protocolVersion == 2, seed.kind == .catalog,
            let notebookID = seed.notebookID
        else { throw SyncError.invalidRecord }
        if let expected = state.notebookID, expected != notebookID {
            throw SyncError.identityConflict
        }
        try await replica.acceptSeed(seed)
        state.notebookID = notebookID
        try save(state)
        if let legacy = proposal.legacyNote {
            try await replica.adoptLegacy(legacy)
            state.adoptedLegacyHeads = legacy.heads
            try save(state)
        }
        let remembered = state.deletedIDs.union(try replica.deletedIDs)
        let checkpoints = state.appliedHeads.merging(state.acknowledgedHeads) { $0.union($1) }
        if try await !replica.containsHistory(checkpoints, deleted: remembered) {
            diagnosticLog?.record("replay_missing_history")
            state.cursor = nil
            state.appliedHeads = [:]
            state.acknowledgedHeads = [:]
            try save(state)
        }

        var replayedInvalidCursor = false
        var pages = 0
        updateProgress(phase: .receiving)
        while true {
            try Task.checkCancellation()
            let page: SyncPage
            do { page = try await transport.fetch(after: state.cursor) } catch SyncError
                .invalidCursor where !replayedInvalidCursor
            {
                diagnosticLog?.record("replay_invalid_cursor")
                state.cursor = nil
                try save(state)
                replayedInvalidCursor = true
                continue
            }
            for record in page.records {
                try await replica.apply(record)
                updateProgress(
                    phase: .receiving,
                    receivedRecords: (progress?.receivedRecords ?? 0) + 1
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
            if !page.hasMore { break }
            if pages >= 1_000 {
                throw SyncError.unavailable(
                    "Notebook sync paused after too many pages. Retry to continue.")
            }
        }

        let outgoing = try await replica.records()
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
            totalNotes: pendingNotes.count
        )
        for start in stride(from: 0, to: pendingNotes.count, by: 50) {
            try Task.checkCancellation()
            let end = min(start + 50, pendingNotes.count)
            let capturedBatch = Array(pendingNotes[start..<end])
            let deleted = try replica.deletedIDs
            let batch = capturedBatch.filter { !deleted.contains($0.snapshot.noteID) }
            let skipped = capturedBatch.count - batch.count
            if skipped > 0 {
                state.deletedIDs.formUnion(deleted)
                try save(state)
                updateProgress(
                    phase: .uploadingNotes,
                    totalNotes: max(0, (progress?.totalNotes ?? 0) - skipped)
                )
            }
            guard !batch.isEmpty else { continue }
            try await publish(
                batch,
                state: &state,
                completedNoteCount: batch.count
            )
        }
        if let pendingCatalog {
            updateProgress(phase: .uploadingCatalog)
            try await publish([pendingCatalog], state: &state, completedNoteCount: 0)
        }
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
                updateProgress(phase: .cleaningUp)
                diagnosticLog?.record("deletion_cleanup_start", counts: ["items": deleted.count])
                try await transport.purgeDeletedNotes(deleted, notebookID: notebookID)
                diagnosticLog?.record("deletion_cleanup_end", counts: ["items": deleted.count])
            }
        }
        let current = try await replica.records()
        status =
            current.allSatisfy { state.acknowledgedHeads[$0.documentKey] == $0.snapshot.heads }
            ? .exchanged(Date()) : .pending
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
                        + result.acknowledgedIDs.count
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
        totalNotes: Int? = nil
    ) {
        progress = NotebookSyncProgress(
            phase: phase,
            receivedRecords: receivedRecords ?? progress?.receivedRecords ?? 0,
            completedNotes: completedNotes ?? progress?.completedNotes ?? 0,
            totalNotes: totalNotes ?? progress?.totalNotes ?? 0,
            lastProgressAt: Date()
        )
    }

    private static func durationMilliseconds(since start: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(start) * 1_000))
    }

    private struct Proposal: Codable {
        let scope: String
        let record: SyncRecord
        let legacyNote: NoteSnapshot?
        var retiredLegacyNoteID: UUID? = nil
    }

    /// The active V2 path intentionally does not decode a retained V1 body.
    /// This lets it recover the durable catalog even when that obsolete field
    /// can no longer be decoded as a `NoteSnapshot`.
    private struct ProposalWithoutLegacy: Decodable {
        let scope: String
        let record: SyncRecord
        let retiredLegacyNoteID: UUID?
        let containsLegacyNote: Bool

        private enum CodingKeys: String, CodingKey {
            case scope
            case record
            case legacyNote
            case retiredLegacyNoteID
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            scope = try container.decode(String.self, forKey: .scope)
            record = try container.decode(SyncRecord.self, forKey: .record)
            retiredLegacyNoteID = try container.decodeIfPresent(
                UUID.self, forKey: .retiredLegacyNoteID)
            if container.contains(.legacyNote) {
                containsLegacyNote = try !container.decodeNil(forKey: .legacyNote)
            } else {
                containsLegacyNote = false
            }
        }
    }

    /// The development app no longer consumes legacy proposal bodies. Drop
    /// them during local cleanup too, even when cloud setup is unavailable.
    static func removeDeletedLegacyProposal(
        in directory: URL, notebookID: UUID, deletedIDs: Set<UUID>
    ) throws {
        guard !deletedIDs.isEmpty else { return }
        let url = directory.appending(path: "notebook-proposal.json")
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch CocoaError.fileReadNoSuchFile { return }
        let metadata = try JSONDecoder().decode(ProposalWithoutLegacy.self, from: data)
        if metadata.record.notebookID != notebookID {
            let state = try JSONDecoder().decode(NotebookSyncState.self, from: Data(
                contentsOf: directory.appending(path: "notebook-sync-state.json")))
            guard state.notebookID == notebookID, state.scope == metadata.scope else {
                throw SyncError.identityConflict
            }
        }
        try metadata.record.validate()
        guard metadata.containsLegacyNote else { return }
        // Retain a readable old identity for the explicit legacy test adapter;
        // malformed, unused V1 payloads must not block notebook cleanup.
        let old = try? JSONDecoder().decode(Proposal.self, from: data)
        let retired = Proposal(
            scope: metadata.scope, record: metadata.record, legacyNote: nil,
            retiredLegacyNoteID: metadata.retiredLegacyNoteID ?? old?.legacyNote?.noteID)
        try SyncFileIO.replace(JSONEncoder().encode(retired), at: url)
    }

    private func durableProposal(legacyNote: NoteSnapshot?) throws -> Proposal {
        if legacyNote == nil { return try durableProposalWithoutLegacy() }

        let proposal: Proposal
        do {
            proposal = try JSONDecoder().decode(Proposal.self, from: Data(contentsOf: proposalURL))
        } catch CocoaError.fileReadNoSuchFile {
            let snapshot: NotebookCatalogSnapshot
            if let existing = replica.catalogSnapshot {
                snapshot = existing
            } else {
                let catalog = try NotebookCatalogDocument()
                if let legacyNote {
                    _ = try NoteDocument(snapshot: legacyNote)
                    try catalog.add(id: legacyNote.noteID, kind: .note, name: "note.md")
                }
                snapshot = catalog.snapshot()
            }
            proposal = Proposal(
                scope: transport.scope, record: SyncRecord(catalog: snapshot),
                legacyNote: legacyNote)
            try SyncFileIO.replace(JSONEncoder().encode(proposal), at: proposalURL)
        }
        guard proposal.scope == transport.scope else { throw SyncError.scopeChanged }
        try proposal.record.validate()
        guard proposal.record.protocolVersion == 2, proposal.record.kind == .catalog else {
            throw SyncError.invalidRecord
        }
        if let retired = proposal.retiredLegacyNoteID {
            if let legacyNote, legacyNote.noteID != retired { throw SyncError.identityConflict }
            return proposal
        }
        if let legacy = proposal.legacyNote { _ = try NoteDocument(snapshot: legacy) }
        if let legacyNote {
            guard let prior = proposal.legacyNote, prior.noteID == legacyNote.noteID else {
                throw SyncError.identityConflict
            }
            // A restarted migration may supply a newer legacy revision. Its
            // identity/history must still match the durable original proposal.
            let merged = try NoteDocument(snapshot: prior)
            try merged.merge(NoteDocument(snapshot: legacyNote))
            let updated = Proposal(
                scope: proposal.scope, record: proposal.record, legacyNote: merged.snapshot())
            try SyncFileIO.replace(JSONEncoder().encode(updated), at: proposalURL)
            return updated
        }
        return proposal
    }

    private func durableProposalWithoutLegacy() throws -> Proposal {
        var proposal: Proposal
        do {
            let stored = try JSONDecoder().decode(
                ProposalWithoutLegacy.self,
                from: Data(contentsOf: proposalURL)
            )
            guard stored.scope == transport.scope else { throw SyncError.scopeChanged }
            try stored.record.validate()
            guard stored.record.protocolVersion == 2, stored.record.kind == .catalog else {
                throw SyncError.invalidRecord
            }
            proposal = Proposal(
                scope: stored.scope,
                record: stored.record,
                legacyNote: nil,
                retiredLegacyNoteID: stored.retiredLegacyNoteID
            )
            if stored.containsLegacyNote {
                try SyncFileIO.replace(JSONEncoder().encode(proposal), at: proposalURL)
            }
        } catch CocoaError.fileReadNoSuchFile {
            let snapshot: NotebookCatalogSnapshot
            if let existing = replica.catalogSnapshot {
                snapshot = existing
            } else {
                snapshot = try NotebookCatalogDocument().snapshot()
            }
            proposal = Proposal(
                scope: transport.scope,
                record: SyncRecord(catalog: snapshot),
                legacyNote: nil
            )
            try SyncFileIO.replace(JSONEncoder().encode(proposal), at: proposalURL)
        }
        guard proposal.scope == transport.scope else { throw SyncError.scopeChanged }
        try proposal.record.validate()
        guard proposal.record.protocolVersion == 2, proposal.record.kind == .catalog else {
            throw SyncError.invalidRecord
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
