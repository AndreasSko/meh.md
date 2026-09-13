import Foundation

/// A fresh sync workspace joins the server's actual Automerge seed before
/// editing. Existing notes are never replaced. A fresh offline installation
/// can write locally; a later different server identity pauses synchronization.
public actor SyncBootstrapStorage: NoteStorage {
    private let storage: any NoteStorage
    private let transport: any SyncTransport
    private let proposalURL: URL

    public init(
        storage: any NoteStorage,
        transport: any SyncTransport,
        proposalURL: URL
    ) {
        self.storage = storage
        self.transport = transport
        self.proposalURL = proposalURL
    }

    public func load() async -> NoteLoadResult {
        let existing = await storage.load()
        guard case .firstLaunch = existing else { return existing }
        let proposal: SyncRecord
        do {
            proposal = try durableProposal()
        } catch {
            return .blocked(NoteLoadFailure(current: .unreadable, previous: .absent))
        }
        let seed: SyncRecord
        do {
            seed = try await transport.bootstrap(proposing: proposal)
        } catch {
            // The server may have accepted the proposal before the response
            // was lost. Reuse its identity even when starting offline.
            do {
                try await storage.save(proposal.snapshot)
                return .current(proposal.snapshot)
            } catch {
                return .blocked(NoteLoadFailure(current: .unreadable, previous: .absent))
            }
        }
        do {
            try seed.validate()
            try await storage.save(seed.snapshot)
            return .current(seed.snapshot)
        } catch {
            return .blocked(NoteLoadFailure(
                current: .unreadable, previous: .absent
            ))
        }
    }

    private struct Proposal: Codable {
        let scope: String
        let record: SyncRecord
    }

    private func durableProposal() throws -> SyncRecord {
        let proposal: Proposal
        do {
            let data = try Data(contentsOf: proposalURL)
            proposal = try JSONDecoder().decode(Proposal.self, from: data)
        } catch CocoaError.fileReadNoSuchFile {
            proposal = Proposal(
                scope: transport.scope,
                record: SyncRecord(snapshot: try NoteDocument().snapshot())
            )
            try SyncFileIO.replace(JSONEncoder().encode(proposal), at: proposalURL)
        }
        guard proposal.scope == transport.scope else { throw SyncError.scopeChanged }
        try proposal.record.validate()
        return proposal.record
    }

    public func save(_ snapshot: NoteSnapshot) async throws {
        try await storage.save(snapshot)
    }

    public func recover(_ recovery: NoteRecovery) async throws -> NoteSnapshot {
        try await storage.recover(recovery)
    }
}
