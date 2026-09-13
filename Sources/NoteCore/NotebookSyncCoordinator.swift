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
    @ObservationIgnored private let replica: NotebookReplica
    @ObservationIgnored private let transport: any SyncTransport
    @ObservationIgnored private let stateURL: URL
    @ObservationIgnored private let proposalURL: URL
    @ObservationIgnored private var inFlight = false

    public init(replica: NotebookReplica, transport: any SyncTransport) {
        self.replica = replica
        self.transport = transport
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
        inFlight = true
        status = .syncing
        defer { inFlight = false }
        do {
            try await exchange(legacyNote: legacyNote)
        } catch { status = .failed(error.localizedDescription) }
    }

    private func exchange(legacyNote: NoteSnapshot?) async throws {
        try await replica.load()
        var state = try loadState()
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
            state.cursor = nil
            state.appliedHeads = [:]
            state.acknowledgedHeads = [:]
            try save(state)
        }

        var replayedInvalidCursor = false
        var pages = 0
        while true {
            try Task.checkCancellation()
            let page: SyncPage
            do { page = try await transport.fetch(after: state.cursor) } catch SyncError
                .invalidCursor where !replayedInvalidCursor
            {
                state.cursor = nil
                try save(state)
                replayedInvalidCursor = true
                continue
            }
            for record in page.records { try await replica.apply(record) }
            if page.hasMore && page.cursor == state.cursor { throw SyncError.invalidCursor }
            let persisted = try await replica.records(includeUnlisted: true)
            state.appliedHeads = Dictionary(
                uniqueKeysWithValues: persisted.map { ($0.documentKey, $0.snapshot.heads) })
            state.deletedIDs.formUnion(try replica.deletedIDs)
            state.cursor = page.cursor
            try save(state)
            pages += 1
            if !page.hasMore { break }
            if pages >= 1_000 {
                throw SyncError.unavailable(
                    "Notebook sync paused after too many pages. Retry to continue.")
            }
        }

        let outgoing = try await replica.records()
        for record in outgoing
        where state.acknowledgedHeads[record.documentKey] != record.snapshot.heads {
            try Task.checkCancellation()
            // A user can delete while another record is in flight. Avoid
            // sending a body once permanent intent is known on this device.
            if record.kind == .note, try replica.deletedIDs.contains(record.snapshot.noteID) {
                continue
            }
            try await transport.publish(record)
            state.acknowledgedHeads[record.documentKey] = record.snapshot.heads
            try save(state)
        }
        state.deletedIDs.formUnion(try replica.deletedIDs)
        try save(state)
        let current = try await replica.records()
        status =
            current.allSatisfy { state.acknowledgedHeads[$0.documentKey] == $0.snapshot.heads }
            ? .exchanged(Date()) : .pending
    }

    private struct Proposal: Codable {
        let scope: String
        let record: SyncRecord
        let legacyNote: NoteSnapshot?
    }

    private func durableProposal(legacyNote: NoteSnapshot?) throws -> Proposal {
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
