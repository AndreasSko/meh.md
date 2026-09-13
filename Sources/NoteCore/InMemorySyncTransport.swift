import CryptoKit
import Foundation

/// Shared state for deterministic sync and failure-path tests.
public actor InMemorySyncStore {
    private struct Workspace {
        var seedID: String?
        var records: [SyncRecord?] = []
        var recordsByID: [String: SyncRecord] = [:]
        var notebookID: UUID?
        var deletedNoteIDs = Set<UUID>()
    }

    private var workspaces: [String: Workspace] = [:]
    private var isOffline = false
    private var acknowledgementsToLose = 0

    public init() {}

    /// Makes every operation fail until delivery is restored.
    public func setOffline(_ offline: Bool) {
        isOffline = offline
    }

    /// Persists the next successful mutation, then reports a delivery failure.
    public func loseNextAcknowledgement() {
        acknowledgementsToLose += 1
    }

    fileprivate func bootstrap(
        scope: String,
        proposing record: SyncRecord
    ) throws -> SyncRecord {
        try requireDelivery()
        try validate(record)

        var workspace = workspaces[scope, default: Workspace()]
        let canonical: SyncRecord
        if let seedID = workspace.seedID,
           let seed = workspace.recordsByID[seedID] {
            canonical = seed
        } else {
            try append(record, to: &workspace)
            workspace.seedID = record.id
            workspace.notebookID = record.notebookID
            canonical = record
        }
        workspaces[scope] = workspace
        try acknowledgeMutation()
        return canonical
    }

    fileprivate func publish(scope: String, record: SyncRecord) throws {
        try requireDelivery()
        try validate(record)

        var workspace = workspaces[scope, default: Workspace()]
        if record.protocolVersion == 2 {
            if let notebookID = workspace.notebookID,
               notebookID != record.notebookID {
                throw SyncError.invalidRecord
            }
            workspace.notebookID = record.notebookID
        }
        if record.protocolVersion == 2, record.kind == .note,
           workspace.deletedNoteIDs.contains(record.snapshot.noteID) {
            workspaces[scope] = workspace
            try acknowledgeMutation()
            return
        }
        try append(record, to: &workspace)
        workspaces[scope] = workspace
        try acknowledgeMutation()
    }

    fileprivate func fetch(
        scope: String,
        after cursor: String?,
        pageSize: Int
    ) throws -> SyncPage {
        try requireDelivery()
        let workspace = workspaces[scope, default: Workspace()]
        let offset = try decode(cursor: cursor, scope: scope)
        guard offset <= workspace.records.count else {
            throw SyncError.invalidCursor
        }

        let end = min(offset + pageSize, workspace.records.count)
        return SyncPage(
            records: workspace.records[offset..<end].compactMap { $0 },
            cursor: encodeCursor(scope: scope, offset: end),
            hasMore: end < workspace.records.count
        )
    }

    private func append(
        _ record: SyncRecord,
        to workspace: inout Workspace
    ) throws {
        if let existing = workspace.recordsByID[record.id] {
            guard existing == record else {
                throw SyncError.invalidRecord
            }
            return
        }
        workspace.records.append(record)
        workspace.recordsByID[record.id] = record
    }

    fileprivate func purgeDeletedNotes(
        scope: String, noteIDs: Set<UUID>, notebookID: UUID
    ) throws {
        try requireDelivery()
        var workspace = workspaces[scope, default: Workspace()]
        guard workspace.notebookID == notebookID else {
            throw SyncError.invalidRecord
        }
        workspace.deletedNoteIDs.formUnion(noteIDs)
        for index in workspace.records.indices {
            guard let record = workspace.records[index],
                  record.kind == .note,
                  workspace.deletedNoteIDs.contains(record.snapshot.noteID)
            else { continue }
            workspace.records[index] = nil
            workspace.recordsByID[record.id] = nil
        }
        workspaces[scope] = workspace
        try acknowledgeMutation()
    }

    private func requireDelivery() throws {
        if isOffline {
            throw SyncError.unavailable("The in-memory sync store is offline.")
        }
    }

    private func validate(_ record: SyncRecord) throws {
        do {
            try record.validate()
        } catch {
            throw SyncError.invalidRecord
        }
    }

    private func acknowledgeMutation() throws {
        guard acknowledgementsToLose > 0 else { return }
        acknowledgementsToLose -= 1
        throw SyncError.unavailable(
            "The sync change was stored, but its acknowledgement was lost."
        )
    }

    private func encodeCursor(scope: String, offset: Int) -> String {
        "v1:\(scopeDigest(scope)):\(offset)"
    }

    private func decode(cursor: String?, scope: String) throws -> Int {
        guard let cursor else { return 0 }
        let pieces = cursor.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 3,
              pieces[0] == "v1",
              pieces[1] == Substring(scopeDigest(scope)),
              let offset = Int(pieces[2]),
              offset >= 0 else {
            throw SyncError.invalidCursor
        }
        return offset
    }

    private func scopeDigest(_ scope: String) -> String {
        SHA256.hash(data: Data(scope.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
    }
}

/// A transport backed by an actor that can be shared by several test clients.
public struct InMemorySyncTransport: SyncTransport, Sendable {
    public nonisolated let scope: String
    public let store: InMemorySyncStore
    public let pageSize: Int

    public init(
        scope: String,
        store: InMemorySyncStore = InMemorySyncStore(),
        pageSize: Int = 100
    ) {
        self.scope = scope
        self.store = store
        self.pageSize = max(1, pageSize)
    }

    public func bootstrap(proposing record: SyncRecord) async throws
        -> SyncRecord {
        try await store.bootstrap(scope: scope, proposing: record)
    }

    public func publish(_ record: SyncRecord) async throws {
        try await store.publish(scope: scope, record: record)
    }

    public func fetch(after cursor: String?) async throws -> SyncPage {
        try await store.fetch(
            scope: scope,
            after: cursor,
            pageSize: pageSize
        )
    }

    public func purgeDeletedNotes(
        _ noteIDs: Set<UUID>, notebookID: UUID
    ) async throws {
        try await store.purgeDeletedNotes(
            scope: scope, noteIDs: noteIDs, notebookID: notebookID
        )
    }
}
