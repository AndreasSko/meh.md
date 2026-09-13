import Foundation
import Observation

public enum NotebookReplicaError: Error, Equatable {
    case notJoined, busy, catalogNeedsRecovery, catalogUnavailable
    case noteUnavailable(UUID)
    case permanentlyDeleted(UUID)
}

/// Owns one local notebook. Only opened notes retain editor sessions; remote
/// updates to unopened notes are merged directly through their file stores.
@MainActor
@Observable
public final class NotebookReplica {
    public let directory: URL
    public private(set) var catalogSnapshot: NotebookCatalogSnapshot?
    public private(set) var placements: [NotebookPlacement] = []
    @ObservationIgnored private var catalog: NotebookCatalogDocument?
    @ObservationIgnored private let storage: NotebookCatalogStorage
    @ObservationIgnored private var sessions: [UUID: NoteSession] = [:]
    @ObservationIgnored private var sessionLoads: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var rememberedDeletions: Set<UUID> = []
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var writingCatalog = false
    @ObservationIgnored private var writeWaiters: [CheckedContinuation<Void, Never>] = []

    public init(directory: URL) {
        self.directory = directory
        storage = NotebookCatalogStorage(directory: directory)
    }

    public func load() async throws {
        guard !loaded else { return }
        guard !writingCatalog else { throw NotebookReplicaError.busy }
        writingCatalog = true
        defer {
            writingCatalog = false
            let waiters = writeWaiters
            writeWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        switch await storage.load() {
        case .firstLaunch: break
        case .current(let snapshot): try install(snapshot)
        case .recoveryRequired: throw NotebookReplicaError.catalogNeedsRecovery
        case .blocked: throw NotebookReplicaError.catalogUnavailable
        }
        loaded = true
    }

    public var deletedIDs: Set<UUID> {
        get throws {
            guard let catalog else { return rememberedDeletions }
            return rememberedDeletions.union(
                try catalog.items().filter(\.isPermanentlyDeleted).map(\.id))
        }
    }

    /// Local-only initialization is explicit. Network joining must use a
    /// durable proposal and the canonical seed instead of this method.
    public func createLocalNotebook() async throws {
        try await load()
        guard catalog == nil else { return }
        try await saveCatalog(NotebookCatalogDocument())
    }

    public func createNote(name: String, text: String = "", parentID: UUID? = nil) async throws
        -> UUID
    {
        guard let catalog else { throw NotebookReplicaError.notJoined }
        let next = try catalog.fork()
        let note = try NoteDocument(text: text)
        // Validate metadata before writing the body. Persist the body before
        // its catalog reference; interrupted operations may leave an orphan.
        try next.add(id: note.noteID, kind: .note, name: name, parentID: parentID)
        try await withCatalogWrite {
            try await self.noteStorage(note.noteID).save(note.snapshot())
            try await self.persistCatalog(next)
        }
        return note.noteID
    }

    public func createFolder(name: String, parentID: UUID? = nil) async throws -> UUID {
        guard let catalog else { throw NotebookReplicaError.notJoined }
        let next = try catalog.fork()
        let id = try next.add(kind: .folder, name: name, parentID: parentID)
        try await saveCatalog(next)
        return id
    }

    public func rename(_ id: UUID, to name: String) async throws {
        try ensureAlive(id)
        let next = try catalog!.fork()
        try next.rename(id, to: name)
        try await saveCatalog(next)
    }

    public func move(_ id: UUID, to parentID: UUID?) async throws {
        try ensureAlive(id)
        let next = try catalog!.fork()
        try next.move(id, to: parentID)
        try await saveCatalog(next)
    }

    public func setTrashed(_ id: UUID, _ trashed: Bool) async throws {
        try ensureAlive(id)
        let next = try catalog!.fork()
        try next.setTrashed(id, trashed)
        try await saveCatalog(next)
    }

    /// Record confirmed permanent intent. Physical cleanup and user controls
    /// remain separate; this layer prevents subsequent edits/resurrection.
    func markPermanentlyDeleted(_ ids: Set<UUID>) async throws {
        guard let catalog else { throw NotebookReplicaError.notJoined }
        let next = try catalog.fork()
        try next.markPermanentlyDeleted(ids)
        try await saveCatalog(next)
    }

    public func openNote(_ id: UUID) async throws -> NoteSession {
        await waitForWrites()
        try ensureAlive(id)
        guard try catalog!.items().contains(where: { $0.id == id && $0.kind == .note }) else {
            throw NotebookReplicaError.noteUnavailable(id)
        }
        if let session = sessions[id] {
            if let load = sessionLoads[id] { await load.value }
            try ensureAlive(id)
            guard session.isEditingEnabled else { throw NotebookReplicaError.noteUnavailable(id) }
            return session
        }
        let session = NoteSession(storage: ExistingNotebookNoteStorage(base: noteStorage(id)))
        // Register before suspension so a received update joins this same
        // session instead of creating an independent writer for the file.
        sessions[id] = session
        let load = Task { await session.load() }
        sessionLoads[id] = load
        await load.value
        sessionLoads[id] = nil
        if try deletedIDs.contains(id) {
            session.markPermanentlyDeleted()
            throw NotebookReplicaError.permanentlyDeleted(id)
        }
        guard session.isEditingEnabled else {
            sessions[id] = nil
            throw NotebookReplicaError.noteUnavailable(id)
        }
        return session
    }

    func acceptSeed(_ record: SyncRecord) async throws {
        try record.validate()
        guard let snapshot = record.catalogSnapshot else { throw SyncError.invalidRecord }
        if let catalog {
            let next = try catalog.fork()
            try next.merge(NotebookCatalogDocument(snapshot: snapshot))
            try await saveCatalog(next)
        } else {
            try await saveCatalog(NotebookCatalogDocument(snapshot: snapshot))
        }
    }

    func apply(_ record: SyncRecord) async throws {
        try record.validate()
        guard let catalog, record.protocolVersion == 2,
            record.notebookID == catalog.notebookID
        else { throw SyncError.identityConflict }
        if record.kind == .catalog {
            try await acceptSeed(record)
            return
        }
        let id = record.snapshot.noteID
        if try catalog.items().contains(where: { $0.id == id && $0.kind != .note }) {
            throw SyncError.identityConflict
        }
        if try deletedIDs.contains(id) { return }
        if let session = sessions[id] {
            if let load = sessionLoads[id] { await load.value }
            if try deletedIDs.contains(id) { return }
            guard session.isEditingEnabled else { throw NotebookReplicaError.noteUnavailable(id) }
            try session.mergeRemote(record.snapshot)
            try await session.flush()
            return
        }
        // Unopened note writes must not overlap an open/load or another
        // download. A single MainActor operation guard serializes this path.
        try await withCatalogWrite {
            let store = self.noteStorage(id)
            switch await store.load() {
            case .firstLaunch:
                try await store.save(record.snapshot)
            case .current(let snapshot):
                let local = try NoteDocument(snapshot: snapshot)
                try local.merge(NoteDocument(snapshot: record.snapshot))
                if local.heads != snapshot.heads { try await store.save(local.snapshot()) }
            case .recoveryRequired, .blocked:
                throw NotebookReplicaError.noteUnavailable(id)
            }
        }
    }

    /// Preserve a legacy body only after confirming canonical membership.
    /// All replicas of the migrated V1 note reuse the seed's one catalog entry.
    func adoptLegacy(_ snapshot: NoteSnapshot) async throws {
        guard let catalog,
            try catalog.items().contains(where: { $0.id == snapshot.noteID && $0.kind == .note })
        else {
            throw SyncError.identityConflict
        }
        try await apply(SyncRecord(snapshot: snapshot, notebookID: catalog.notebookID))
    }

    func records(includeUnlisted: Bool = false) async throws -> [SyncRecord] {
        await waitForWrites()
        guard let catalog else { throw NotebookReplicaError.notJoined }
        for (id, session) in sessions where !(try deletedIDs.contains(id)) {
            if let load = sessionLoads[id] { await load.value }
            try await session.flush()
        }
        let deleted = try deletedIDs
        let listed = Set(try catalog.items().filter { $0.kind == .note }.map(\.id))
        var records: [SyncRecord] = []
        for id in try storedNoteIDs().sorted(by: { $0.uuidString < $1.uuidString })
        where !deleted.contains(id) && (includeUnlisted || listed.contains(id)) {
            switch await noteStorage(id).load() {
            case .current(let snapshot):
                guard snapshot.noteID == id else { throw SyncError.identityConflict }
                records.append(SyncRecord(snapshot: snapshot, notebookID: catalog.notebookID))
            case .firstLaunch: continue
            case .recoveryRequired, .blocked: throw NotebookReplicaError.noteUnavailable(id)
            }
        }
        // Bodies before metadata reduces missing-content intervals but the
        // receiver must remain correct for either arrival order.
        records.append(SyncRecord(catalog: catalogSnapshot!))
        return records
    }

    func containsHistory(_ checkpoints: [String: Set<String>], deleted: Set<UUID>) async throws
        -> Bool
    {
        let records = try await records(includeUnlisted: true)
        let indexed = Dictionary(uniqueKeysWithValues: records.map { ($0.documentKey, $0) })
        for (key, heads) in checkpoints {
            if key.hasPrefix("note:"), let id = UUID(uuidString: String(key.dropFirst(5))),
                deleted.contains(id)
            {
                continue
            }
            guard let record = indexed[key] else { return false }
            let history: Set<String>
            if let catalog = record.catalogSnapshot {
                history = try NotebookCatalogDocument(snapshot: catalog).historyHeads
            } else {
                history = try NoteDocument(snapshot: record.snapshot).historyHeads
            }
            if !heads.isSubset(of: history) { return false }
        }
        return true
    }

    func rememberDeletions(_ ids: Set<UUID>) async throws {
        rememberedDeletions.formUnion(ids)
        for id in ids { sessions[id]?.markPermanentlyDeleted() }
        placements.removeAll { ids.contains($0.item.id) }
        if let catalog {
            let represented = Set(try catalog.items().map(\.id))
            let deleted = Set(try catalog.items().filter(\.isPermanentlyDeleted).map(\.id))
            if !ids.intersection(represented).subtracting(deleted).isEmpty {
                try await saveCatalog(catalog.fork())
            }
        }
    }

    func noteStorage(_ id: UUID) -> NoteFileStorage {
        NoteFileStorage(directory: directory.appending(path: "notes/\(id.uuidString)"))
    }

    private func storedNoteIDs() throws -> [UUID] {
        let url = directory.appending(path: "notes")
        do {
            return try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil
            )
            .compactMap { UUID(uuidString: $0.lastPathComponent) }
        } catch CocoaError.fileReadNoSuchFile { return [] }
    }

    private func ensureAlive(_ id: UUID) throws {
        guard let catalog else { throw NotebookReplicaError.notJoined }
        guard try catalog.items().contains(where: { $0.id == id }) else {
            throw NotebookCatalogError.itemNotFound
        }
        if try deletedIDs.contains(id) { throw NotebookReplicaError.permanentlyDeleted(id) }
    }

    private func waitForWrites() async {
        while writingCatalog {
            await withCheckedContinuation { writeWaiters.append($0) }
        }
    }

    private func saveCatalog(_ next: NotebookCatalogDocument) async throws {
        try await withCatalogWrite { try await self.persistCatalog(next) }
    }

    private func withCatalogWrite(_ operation: () async throws -> Void) async throws {
        guard !writingCatalog else { throw NotebookReplicaError.busy }
        writingCatalog = true
        defer {
            writingCatalog = false
            let waiters = writeWaiters
            writeWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        try await operation()
    }

    private func persistCatalog(_ next: NotebookCatalogDocument) async throws {
        let represented = Set(try next.items().map(\.id))
        let alreadyDeleted = Set(try next.items().filter(\.isPermanentlyDeleted).map(\.id))
        let missing = rememberedDeletions.intersection(represented).subtracting(alreadyDeleted)
        if !missing.isEmpty { try next.markPermanentlyDeleted(missing) }
        try await storage.save(next.snapshot())
        try install(next.snapshot())
    }

    private func install(_ snapshot: NotebookCatalogSnapshot) throws {
        let document = try NotebookCatalogDocument(snapshot: snapshot)
        let nextPlacements = try document.placements().filter {
            !rememberedDeletions.contains($0.item.id)
        }
        catalog = document
        catalogSnapshot = snapshot
        placements = nextPlacements
        for id in try deletedIDs { sessions[id]?.markPermanentlyDeleted() }
    }
}

private struct ExistingNotebookNoteStorage: NoteStorage {
    let base: NoteFileStorage
    func load() async -> NoteLoadResult {
        let loaded = await base.load()
        if case .firstLaunch = loaded {
            return .blocked(NoteLoadFailure(current: .absent, previous: .absent))
        }
        return loaded
    }
    func save(_ snapshot: NoteSnapshot) async throws { try await base.save(snapshot) }
    func recover(_ recovery: NoteRecovery) async throws -> NoteSnapshot {
        try await base.recover(recovery)
    }
}

extension SyncRecord {
    var documentKey: String { "\(kind.rawValue):\(snapshot.noteID.uuidString)" }
}
