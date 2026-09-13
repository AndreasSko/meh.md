import Foundation
import Observation

@MainActor
@Observable
public final class NoteSyncCoordinator {
    public enum Status: Equatable, Sendable {
        case idle
        case syncing
        case pending
        case exchanged(Date)
        case failed(String)
    }

    public private(set) var status: Status = .idle
    @ObservationIgnored private let session: NoteSession
    @ObservationIgnored private let transport: any SyncTransport
    @ObservationIgnored private let storage: SyncStateStorage
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private var lastAcknowledgedHeads: Set<String> = []
    @ObservationIgnored private var restoredProgress = false

    public init(
        session: NoteSession,
        transport: any SyncTransport,
        stateURL: URL
    ) {
        self.session = session
        self.transport = transport
        storage = SyncStateStorage(url: stateURL)
    }

    public func noteDidSave() {
        guard !inFlight, let snapshot = session.persistedSnapshot else { return }
        if snapshot.heads != lastAcknowledgedHeads { status = .pending }
    }

    /// Restore the last known acknowledgment without requiring the network.
    public func restoreStatus() async {
        guard !inFlight, !restoredProgress,
              session.persistedSnapshot != nil else { return }
        do {
            let state = try await storage.load(scope: transport.scope)
            guard !inFlight, !restoredProgress else { return }
            restoredProgress = true
            lastAcknowledgedHeads = state.acknowledgedHeads
            if session.currentSnapshot?.heads == lastAcknowledgedHeads {
                status = state.lastExchange.map(Status.exchanged) ?? .idle
            } else { status = .pending }
        } catch {
            guard !inFlight else { return }
            status = .failed(error.localizedDescription)
        }
    }

    /// One finite exchange. Calls never overlap; another activation, saved
    /// edit, timer, or explicit retry can request a later exchange.
    public func synchronize() async {
        guard !inFlight else { return }
        inFlight = true
        status = .syncing
        defer { inFlight = false }
        do {
            try await session.flush()
            var state = try await storage.load(scope: transport.scope)
            if let current = session.persistedSnapshot {
                let history = try NoteDocument(snapshot: current).historyHeads
                let checkpoint = (state.appliedHeads ?? [])
                    .union(state.acknowledgedHeads)
                if !checkpoint.isSubset(of: history) {
                    // Explicit previous-file recovery can roll back the note
                    // without rolling back its separate sync metadata.
                    state.cursor = nil
                    state.appliedHeads = nil
                    state.acknowledgedHeads = []
                }
            }
            // Persist account/workspace binding before the first network write.
            try await storage.save(state)
            guard let initial = session.persistedSnapshot else {
                throw SyncError.localSaveRequired
            }
            let seed = try await transport.bootstrap(
                proposing: SyncRecord(snapshot: initial)
            )
            try seed.validate()
            try session.mergeRemote(seed.snapshot)
            try await session.flush()

            var replayedInvalidCursor = false
            var pageCount = 0
            while true {
                try Task.checkCancellation()
                let page: SyncPage
                do {
                    page = try await transport.fetch(after: state.cursor)
                } catch SyncError.invalidCursor where !replayedInvalidCursor {
                    state.cursor = nil
                    try await storage.save(state)
                    replayedInvalidCursor = true
                    continue
                }
                for record in page.records {
                    try record.validate()
                    try session.mergeRemote(record.snapshot)
                }
                // A crash before this commit simply causes replay. The
                // immutable records make duplicate merges harmless.
                try await session.flush()
                if page.hasMore && page.cursor == state.cursor {
                    throw SyncError.invalidCursor
                }
                state.cursor = page.cursor
                state.appliedHeads = session.persistedSnapshot?.heads
                try await storage.save(state)
                pageCount += 1
                guard pageCount <= 1_000 else {
                    throw SyncError.unavailable("Sync paused after too many pages. Retry to continue.")
                }
                if !page.hasMore { break }
            }

            try await session.flush()
            guard let outgoing = session.persistedSnapshot else {
                throw SyncError.localSaveRequired
            }
            if outgoing.heads != state.acknowledgedHeads {
                try await transport.publish(SyncRecord(snapshot: outgoing))
                // A lost response or crash before bookkeeping means retry,
                // never a permanently forgotten upload.
                state.acknowledgedHeads = outgoing.heads
                try await storage.save(state)
            }
            lastAcknowledgedHeads = state.acknowledgedHeads
            let exchangedAt = Date()
            state.lastExchange = exchangedAt
            try await storage.save(state)
            restoredProgress = true
            status = session.currentSnapshot?.heads == lastAcknowledgedHeads
                ? .exchanged(exchangedAt) : .pending
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}
