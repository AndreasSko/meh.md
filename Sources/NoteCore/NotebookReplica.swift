import Foundation
import Observation

public enum NotebookReplicaError: Error, Equatable {
    case notJoined, busy, catalogNeedsRecovery, catalogUnavailable
    case noteUnavailable(UUID)
    case permanentlyDeleted(UUID)
}

public enum NotebookDeletionError: Error, Equatable, LocalizedError {
    case invalidSelection
    case notebookIdentityMismatch
    case itemNoLongerInTrash(UUID)

    public var errorDescription: String? {
        switch self {
        case .invalidSelection:
            "The permanent deletion selection is invalid."
        case .notebookIdentityMismatch:
            "The deletion selection belongs to another notebook."
        case .itemNoLongerInTrash:
            "An item in the selection is no longer in Trash. Review the selection again."
        }
    }
}

/// The exact identities shown to the user before permanent deletion. A later
/// child is never added implicitly when this snapshot is executed.
public struct NotebookDeletionSelection: Equatable, Sendable {
    public let notebookID: UUID
    public let ids: Set<UUID>
    public let items: [NotebookItem]
    public let rootID: UUID?

    public var count: Int { ids.count }

    fileprivate init(
        notebookID: UUID,
        ids: Set<UUID>,
        items: [NotebookItem],
        rootID: UUID?
    ) {
        self.notebookID = notebookID
        self.ids = ids
        self.items = items
        self.rootID = rootID
    }
}

/// Owns one local notebook. Only opened notes retain editor sessions; remote
/// updates to unopened notes are merged directly through their file stores.
@MainActor
@Observable
public final class NotebookReplica {
    public let directory: URL
    public private(set) var catalogSnapshot: NotebookCatalogSnapshot?
    public private(set) var placements: [NotebookPlacement] = []
    public private(set) var hasPendingImport: Bool
    public private(set) var deletionCleanupErrorMessage: String?
    @ObservationIgnored private var catalog: NotebookCatalogDocument?
    @ObservationIgnored private let storage: NotebookCatalogStorage
    @ObservationIgnored private let importStorage: NotebookImportStorage
    @ObservationIgnored private let deletionStorage: NotebookDeletionStorage
    @ObservationIgnored private var sessions: [UUID: NoteSession] = [:]
    @ObservationIgnored private var sessionLoads: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var rememberedDeletions: Set<UUID> = []
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var writingCatalog = false
    @ObservationIgnored private var writeWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored var importFaultInjector: ((NotebookImportStage) throws -> Void)?
    @ObservationIgnored var deletionFaultInjector: ((NotebookDeletionStage) throws -> Void)?

    public init(directory: URL) {
        self.directory = directory
        storage = NotebookCatalogStorage(directory: directory)
        importStorage = NotebookImportStorage(directory: directory)
        deletionStorage = NotebookDeletionStorage(directory: directory)
        hasPendingImport = importStorage.hasPendingImport
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
        case .firstLaunch:
            guard !deletionStorage.hasLedger else {
                throw NotebookReplicaError.catalogUnavailable
            }
        case .current(let snapshot):
            let document = try NotebookCatalogDocument(snapshot: snapshot)
            rememberedDeletions = try deletionStorage.load(
                notebookID: document.notebookID
            )
            try install(snapshot)
            let observed = Set(try document.items()
                .filter(\.isPermanentlyDeleted).map(\.id))
            rememberedDeletions = try deletionStorage.record(
                observed,
                notebookID: document.notebookID
            )
            let represented = Set(try document.items().map(\.id))
            if !rememberedDeletions.intersection(represented)
                .subtracting(observed).isEmpty
            {
                try await persistCatalog(document.fork())
            }
        case .recoveryRequired: throw NotebookReplicaError.catalogNeedsRecovery
        case .blocked: throw NotebookReplicaError.catalogUnavailable
        }
        hasPendingImport = importStorage.hasPendingImport
        loaded = true
        tryBestEffortDeletionCleanup()
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

    public func importMarkdown(_ plan: NotebookImportPlan) async throws {
        guard let catalog else { throw NotebookReplicaError.notJoined }
        guard !hasPendingImport, !importStorage.hasPendingImport else {
            hasPendingImport = true
            throw NotebookImportError.pendingImportExists
        }
        try validate(plan, against: catalog)
        guard !plan.entries.isEmpty else { return }
        let snapshots: [NoteSnapshot] = try plan.entries.compactMap { entry in
            guard entry.kind == .note, let text = entry.text else { return nil }
            return try NoteDocument(
                noteID: entry.id, text: text,
                metadata: NoteMetadata(
                    createdAt: entry.createdAt, modifiedAt: entry.modifiedAt)
            ).snapshot()
        }
        let journal = NotebookImportJournal(
            notebookID: catalog.notebookID,
            plan: plan,
            snapshots: snapshots
        )

        try await withCatalogWrite {
            do {
                for snapshot in snapshots {
                    switch await self.noteStorage(snapshot.noteID).load() {
                    case .firstLaunch:
                        break
                    case .current, .recoveryRequired, .blocked:
                        throw NotebookImportError.bodyConflict(snapshot.noteID)
                    }
                }
                try self.importStorage.create(journal)
                self.hasPendingImport = true
                try self.importFaultInjector?(.journalSaved)
                try await self.finishImport(journal)
            } catch {
                self.hasPendingImport = self.importStorage.hasPendingImport
                throw error
            }
        }
    }

    public func resumePendingImport() async throws {
        guard catalog != nil else { throw NotebookReplicaError.notJoined }
        try await withCatalogWrite {
            do {
                let journal = try self.importStorage.load()
                self.hasPendingImport = true
                _ = try self.validateJournal(journal)
                try await self.finishImport(journal)
            } catch {
                self.hasPendingImport = self.importStorage.hasPendingImport
                throw error
            }
        }
    }

    public func setAsidePendingImport() async throws -> URL {
        try await withCatalogWrite {
            do {
                let destination = try self.importStorage.setAside { url in
                    try self.importFaultInjector?(.journalSetAside(url))
                }
                self.hasPendingImport = false
                return destination
            } catch {
                self.hasPendingImport = self.importStorage.hasPendingImport
                throw error
            }
        }
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

    /// Read the durable sibling order without opening editor sessions.
    public func orderedChildren(
        parentID: UUID?, inTrash: Bool = false
    ) -> [NotebookPlacement] {
        NotebookOrdering.orderedChildren(
            placements, parentID: parentID, inTrash: inTrash)
    }

    public func reorder(
        _ ids: [UUID], parentID: UUID?, before: UUID?
    ) async throws {
        try await withCatalogWrite {
            guard let catalog = self.catalog else {
                throw NotebookReplicaError.notJoined
            }
            let next = try catalog.fork()
            try next.reorder(ids, parentID: parentID, before: before)
            try await self.persistCatalog(next)
        }
    }

    /// Sorting materializes a new manual order; it never installs a live rule.
    public func sortChildren(
        parentID: UUID?, by order: NotebookSortOrder
    ) async throws {
        try await withCatalogWrite {
            guard let catalog = self.catalog else {
                throw NotebookReplicaError.notJoined
            }
            // Recovered display roots need an explicit move to repair their parent.
            let children = self.orderedChildren(parentID: parentID)
                .filter { $0.item.parentID == parentID }
            var dates: [UUID: NoteMetadata] = [:]
            if order != .nameAscending && order != .nameDescending {
                for child in children where child.item.kind == .note {
                    let id = child.item.id
                    if let session = self.sessions[id] {
                        if let load = self.sessionLoads[id] { await load.value }
                        try await session.flush()
                        // A separate storage read can lag behind live edits
                        // received after flush returns to the main actor.
                        guard let snapshot = session.currentSnapshot,
                              snapshot.noteID == id else {
                            throw NotebookReplicaError.noteUnavailable(id)
                        }
                        dates[id] = try NoteDocument(snapshot: snapshot).metadata
                        continue
                    }
                    switch await self.noteStorage(id).load() {
                    case .current(let snapshot):
                        guard snapshot.noteID == id else {
                            throw NotebookReplicaError.noteUnavailable(id)
                        }
                        dates[id] = try NoteDocument(snapshot: snapshot).metadata
                    case .firstLaunch:
                        // Catalogs may arrive before bodies. Unknown dates
                        // sort last without creating or recovering a note.
                        dates[id] = NoteMetadata(createdAt: nil, modifiedAt: nil)
                    case .recoveryRequired, .blocked:
                        throw NotebookReplicaError.noteUnavailable(id)
                    }
                }
            }
            let sorted = children.sorted { left, right in
                if left.item.kind != right.item.kind {
                    return left.item.kind == .folder
                }
                if left.item.kind == .note {
                    let leftDate: Date?
                    let rightDate: Date?
                    switch order {
                    case .createdNewest, .createdOldest:
                        leftDate = dates[left.item.id]?.createdAt
                        rightDate = dates[right.item.id]?.createdAt
                    case .modifiedNewest, .modifiedOldest:
                        leftDate = dates[left.item.id]?.modifiedAt
                        rightDate = dates[right.item.id]?.modifiedAt
                    case .nameAscending, .nameDescending:
                        leftDate = nil
                        rightDate = nil
                    }
                    if leftDate != rightDate {
                        guard let leftDate else { return false }
                        guard let rightDate else { return true }
                        return order == .createdNewest || order == .modifiedNewest
                            ? leftDate > rightDate : leftDate < rightDate
                    }
                }
                let comparison = left.displayName.localizedStandardCompare(right.displayName)
                if comparison == .orderedSame {
                    return left.item.id.uuidString < right.item.id.uuidString
                }
                return order == .nameDescending
                    ? comparison == .orderedDescending : comparison == .orderedAscending
            }
            let next = try catalog.fork()
            try next.reorder(sorted.map(\.item.id), parentID: parentID, before: nil)
            try await self.persistCatalog(next)
        }
    }

    public func setTrashed(_ id: UUID, _ trashed: Bool) async throws {
        try ensureAlive(id)
        let next = try catalog!.fork()
        try next.setTrashed(id, trashed)
        try await saveCatalog(next)
    }

    /// Capture all items currently shown in Trash, or one Trash subtree. The
    /// returned IDs are the complete destructive scope presented for review.
    public func deletionSelection(
        rootID: UUID? = nil
    ) throws -> NotebookDeletionSelection {
        guard let catalog else { throw NotebookReplicaError.notJoined }
        let trash = placements.filter(\.isInTrash)
        let byID = Dictionary(uniqueKeysWithValues: trash.map { ($0.item.id, $0) })
        let selectedIDs: Set<UUID>
        if let rootID {
            guard byID[rootID] != nil else {
                throw NotebookDeletionError.itemNoLongerInTrash(rootID)
            }
            var descendants: Set<UUID> = [rootID]
            var changed = true
            while changed {
                let before = descendants.count
                for placement in trash where placement.parentID.map(descendants.contains) == true {
                    descendants.insert(placement.item.id)
                }
                changed = descendants.count != before
            }
            selectedIDs = descendants
        } else {
            selectedIDs = Set(trash.map(\.item.id))
        }
        let items = trash
            .filter { selectedIDs.contains($0.item.id) }
            .sorted { left, right in
                if left.displayName != right.displayName {
                    return left.displayName.localizedStandardCompare(right.displayName)
                        == .orderedAscending
                }
                return left.item.id.uuidString < right.item.id.uuidString
            }
            .map(\.item)
        return NotebookDeletionSelection(
            notebookID: catalog.notebookID,
            ids: selectedIDs,
            items: items,
            rootID: rootID
        )
    }

    /// Persist the exact confirmed identities before removing any local body.
    /// Cleanup failures remain retryable and do not undo durable markers.
    public func permanentlyDelete(
        _ selection: NotebookDeletionSelection
    ) async throws {
        try await withCatalogWrite {
            guard let catalog = self.catalog else {
                throw NotebookReplicaError.notJoined
            }
            guard selection.notebookID == catalog.notebookID else {
                throw NotebookDeletionError.notebookIdentityMismatch
            }
            guard selection.ids == Set(selection.items.map(\.id)) else {
                throw NotebookDeletionError.invalidSelection
            }

            let items = Dictionary(uniqueKeysWithValues: try catalog.items().map {
                ($0.id, $0)
            })
            let trashIDs = Set(self.placements.filter(\.isInTrash).map(\.item.id))
            for id in selection.ids {
                guard let item = items[id] else {
                    throw NotebookDeletionError.invalidSelection
                }
                guard item.isPermanentlyDeleted || trashIDs.contains(id) else {
                    throw NotebookDeletionError.itemNoLongerInTrash(id)
                }
            }

            self.rememberedDeletions = try self.deletionStorage.record(
                selection.ids,
                notebookID: catalog.notebookID
            )
            self.applyRememberedDeletions()
            try self.deletionFaultInjector?(.ledgerSaved)

            let next = try catalog.fork()
            try next.markPermanentlyDeleted(selection.ids)
            try await self.persistCatalog(next)
            try self.deletionFaultInjector?(.catalogSaved)
            await self.drainDeletedSessions(selection.ids)
            self.tryBestEffortDeletionCleanup()
        }
    }

    /// Retry cleanup after a permissions or filesystem failure. The durable
    /// deletion ledger remains authoritative whether this succeeds or throws.
    public func cleanupDeletedContent() async throws {
        try await withCatalogWrite {
            do {
                guard !self.rememberedDeletions.isEmpty else {
                    self.deletionCleanupErrorMessage = nil
                    return
                }
                try await self.reconcileDeletionLedgerIntoCatalog()
                await self.drainDeletedSessions(self.rememberedDeletions)
                try self.performDeletionCleanup()
                self.deletionCleanupErrorMessage = nil
            } catch {
                self.deletionCleanupErrorMessage = Self.message(for: error)
                throw error
            }
        }
    }

    /// Record permanent intent received through synchronization.
    func markPermanentlyDeleted(_ ids: Set<UUID>) async throws {
        guard let catalog else { throw NotebookReplicaError.notJoined }
        let next = try catalog.fork()
        try next.markPermanentlyDeleted(ids)
        try await saveCatalog(next)
    }

    public func openNote(
        _ id: UUID,
        allowingRecovery: Bool = false
    ) async throws -> NoteSession {
        await waitForWrites()
        try ensureAlive(id)
        guard try catalog!.items().contains(where: { $0.id == id && $0.kind == .note }) else {
            throw NotebookReplicaError.noteUnavailable(id)
        }
        if let session = sessions[id] {
            if let load = sessionLoads[id] { await load.value }
            try ensureAlive(id)
            guard session.isEditingEnabled || allowingRecovery && session.canAttemptRecovery else {
                throw NotebookReplicaError.noteUnavailable(id)
            }
            return session
        }
        let session = NoteSession(
            storage: ExistingNotebookNoteStorage(expectedID: id, base: noteStorage(id)))
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
        guard session.isEditingEnabled || allowingRecovery && session.canAttemptRecovery else {
            sessions[id] = nil
            throw NotebookReplicaError.noteUnavailable(id)
        }
        return session
    }

    public func recoverCatalogFromPrevious() async throws {
        guard !loaded || catalog == nil else { return }
        guard !writingCatalog else { throw NotebookReplicaError.busy }
        writingCatalog = true
        defer {
            writingCatalog = false
            let waiters = writeWaiters
            writeWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }

        let snapshot: NotebookCatalogSnapshot
        switch await storage.load() {
        case .current(let current):
            snapshot = current
        case .recoveryRequired(let recovery):
            snapshot = try await storage.recover(recovery)
        case .firstLaunch, .blocked:
            throw NotebookReplicaError.catalogUnavailable
        }
        let recovered = try NotebookCatalogDocument(snapshot: snapshot)
        rememberedDeletions.formUnion(try deletionStorage.load(
            notebookID: recovered.notebookID
        ))
        try await persistCatalog(NotebookCatalogDocument(snapshot: snapshot))
        loaded = true
        tryBestEffortDeletionCleanup()
    }

    public func persistedNoteSnapshots() async throws -> [NoteSnapshot] {
        try await records().compactMap { record in
            record.kind == .note ? record.snapshot : nil
        }
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
        let deleted = try deletedIDs
        await drainDeletedSessions(deleted)
        tryBestEffortDeletionCleanup()
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
        try await withCatalogWrite {
            try await self.reconcileDeletionLedgerIntoCatalog()
        }
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
        try await withCatalogWrite {
            guard let catalog = self.catalog else {
                self.rememberedDeletions.formUnion(ids)
                self.applyRememberedDeletions()
                return
            }
            self.rememberedDeletions = try self.deletionStorage.record(
                ids,
                notebookID: catalog.notebookID
            )
            self.applyRememberedDeletions()
            try await self.reconcileDeletionLedgerIntoCatalog()
            await self.drainDeletedSessions(self.rememberedDeletions)
            self.tryBestEffortDeletionCleanup()
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

    private func validate(
        _ plan: NotebookImportPlan,
        against catalog: NotebookCatalogDocument
    ) throws {
        guard Set(plan.entries.map(\.id)).count == plan.entries.count else {
            throw NotebookImportError.invalidPlan
        }
        let entries = Dictionary(uniqueKeysWithValues: plan.entries.map { ($0.id, $0) })
        for entry in plan.entries {
            do { try NotebookName.validate(entry.name) } catch {
                throw NotebookImportError.invalidPlan
            }
            switch entry.kind {
            case .folder where entry.text != nil:
                throw NotebookImportError.invalidPlan
            case .note where entry.text == nil:
                throw NotebookImportError.invalidPlan
            default:
                break
            }
            if let parentID = entry.parentID {
                guard let parent = entries[parentID], parent.kind == .folder else {
                    throw NotebookImportError.invalidPlan
                }
            }
        }
        for entry in plan.entries {
            guard entry.createdAt.map({ $0.noteTimestamp != nil }) ?? true,
                entry.modifiedAt.map({ $0.noteTimestamp != nil }) ?? true
            else { throw NotebookImportError.invalidPlan }
            var seen = Set<UUID>()
            var parentID = entry.parentID
            while let id = parentID {
                guard seen.insert(id).inserted, id != entry.id,
                    let parent = entries[id]
                else { throw NotebookImportError.invalidPlan }
                parentID = parent.parentID
            }
        }
        let existing = Set(try catalog.items().map(\.id))
        if let conflict = plan.entries.first(where: { existing.contains($0.id) }) {
            throw NotebookImportError.identityConflict(conflict.id)
        }

    }

    private func validateJournal(
        _ journal: NotebookImportJournal
    ) throws -> [UUID: NoteSnapshot] {
        do {
            let placeholder = try NotebookCatalogDocument()
            try validate(journal.plan, against: placeholder)
        } catch {
            throw NotebookImportError.corruptJournal
        }
        var snapshots: [UUID: NoteSnapshot] = [:]
        for snapshot in journal.snapshots {
            guard snapshots.updateValue(snapshot, forKey: snapshot.noteID) == nil else {
                throw NotebookImportError.corruptJournal
            }
        }
        let noteEntries = journal.plan.entries.filter { $0.kind == .note }
        guard snapshots.count == journal.snapshots.count,
            Set(noteEntries.map(\.id)) == Set(snapshots.keys)
        else { throw NotebookImportError.corruptJournal }
        for entry in noteEntries {
            guard let stored = snapshots[entry.id],
                let document = try? NoteDocument(snapshot: stored),
                let text = try? document.text,
                let metadata = try? document.metadata,
                let expectedText = entry.text,
                text.utf8.elementsEqual(expectedText.utf8),
                metadata.createdAt == entry.createdAt?.noteTimestamp,
                metadata.modifiedAt == entry.modifiedAt?.noteTimestamp
            else { throw NotebookImportError.corruptJournal }
        }
        return snapshots
    }

    private func finishImport(_ journal: NotebookImportJournal) async throws {
        let snapshots = try validateJournal(journal)
        let latest = try await latestCatalogForImport()
        guard latest.notebookID == journal.notebookID else {
            throw NotebookImportError.notebookIdentityMismatch
        }
        let existing = Dictionary(uniqueKeysWithValues: try latest.items().map { ($0.id, $0) })
        let present = journal.plan.entries.filter { existing[$0.id] != nil }
        if !present.isEmpty {
            guard present.count == journal.plan.entries.count else {
                throw NotebookImportError.catalogConflict
            }
            for entry in journal.plan.entries {
                guard existing[entry.id]?.kind == entry.kind else {
                    throw NotebookImportError.identityConflict(entry.id)
                }
            }
            for entry in journal.plan.entries where entry.kind == .note {
                guard let item = existing[entry.id],
                    let staged = snapshots[entry.id]
                else { throw NotebookImportError.corruptJournal }
                if item.isPermanentlyDeleted { continue }
                if let session = sessions[entry.id] {
                    if let load = sessionLoads[entry.id] { await load.value }
                    guard session.isEditingEnabled else {
                        throw NotebookImportError.bodyConflict(entry.id)
                    }
                    try await session.flush()
                }
                try await verifyImportedBody(staged, id: entry.id)
            }
            try install(latest.snapshot())
            try importStorage.remove()
            hasPendingImport = false
            return
        }

        for entry in journal.plan.entries where entry.kind == .note {
            guard let staged = snapshots[entry.id] else {
                throw NotebookImportError.corruptJournal
            }
            let bodyStorage = noteStorage(entry.id)
            switch await bodyStorage.load() {
            case .firstLaunch:
                try importFaultInjector?(.beforeBody(entry.id))
                try await bodyStorage.save(staged)
                try importFaultInjector?(.bodySaved(entry.id))
            case .current(let current):
                try verifyImportedBody(current, contains: staged, id: entry.id)
            case .recoveryRequired, .blocked:
                throw NotebookImportError.bodyConflict(entry.id)
            }
        }

        let next = try catalogWithImport(journal.plan, basedOn: latest)
        try importFaultInjector?(.beforeCatalog)
        do {
            try await persistCatalog(next)
        } catch is NotebookCatalogStorageError {
            throw NotebookImportError.catalogConflict
        }
        try importFaultInjector?(.catalogSaved)
        try importStorage.remove()
        hasPendingImport = false
    }

    private func verifyImportedBody(
        _ staged: NoteSnapshot,
        id: UUID
    ) async throws {
        switch await noteStorage(id).load() {
        case .current(let current):
            try verifyImportedBody(current, contains: staged, id: id)
        case .firstLaunch, .recoveryRequired, .blocked:
            throw NotebookImportError.bodyConflict(id)
        }
    }

    private func verifyImportedBody(
        _ current: NoteSnapshot,
        contains staged: NoteSnapshot,
        id: UUID
    ) throws {
        guard current.noteID == id,
            let document = try? NoteDocument(snapshot: current),
            staged.heads.isSubset(of: document.historyHeads)
        else { throw NotebookImportError.bodyConflict(id) }
    }

    private func latestCatalogForImport() async throws -> NotebookCatalogDocument {
        guard let current = catalog else { throw NotebookReplicaError.notJoined }
        guard case .current(let snapshot) = await storage.load() else {
            throw NotebookImportError.catalogConflict
        }
        let latest = try NotebookCatalogDocument(snapshot: snapshot)
        guard current.notebookID == latest.notebookID,
            current.heads.isSubset(of: latest.historyHeads)
        else { throw NotebookImportError.catalogConflict }
        return latest
    }

    private func catalogWithImport(
        _ plan: NotebookImportPlan,
        basedOn catalog: NotebookCatalogDocument
    ) throws -> NotebookCatalogDocument {
        try catalog.forkAddingImportEntries(plan.entries)
    }

    private func waitForWrites() async {
        while writingCatalog {
            await withCheckedContinuation { writeWaiters.append($0) }
        }
    }

    private func saveCatalog(_ next: NotebookCatalogDocument) async throws {
        try await withCatalogWrite { try await self.persistCatalog(next) }
    }

    private func withCatalogWrite<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
        guard !writingCatalog else { throw NotebookReplicaError.busy }
        writingCatalog = true
        defer {
            writingCatalog = false
            let waiters = writeWaiters
            writeWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        return try await operation()
    }

    private func persistCatalog(_ next: NotebookCatalogDocument) async throws {
        let represented = Set(try next.items().map(\.id))
        let alreadyDeleted = Set(try next.items().filter(\.isPermanentlyDeleted).map(\.id))
        let missing = rememberedDeletions.intersection(represented).subtracting(alreadyDeleted)
        if !missing.isEmpty { try next.markPermanentlyDeleted(missing) }
        let durableIDs = Set(try next.items()
            .filter(\.isPermanentlyDeleted).map(\.id))
        rememberedDeletions = try deletionStorage.record(
            rememberedDeletions.union(durableIDs),
            notebookID: next.notebookID
        )
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

    private func applyRememberedDeletions() {
        for id in rememberedDeletions { sessions[id]?.markPermanentlyDeleted() }
        placements.removeAll { rememberedDeletions.contains($0.item.id) }
    }

    private func drainDeletedSessions(_ ids: Set<UUID>) async {
        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let session = sessions[id] else { continue }
            session.markPermanentlyDeleted()
            if let load = sessionLoads[id] { await load.value }
            session.markPermanentlyDeleted()
            await session.waitForPendingSave()
            session.discardPermanentlyDeletedContent()
        }
    }

    private func tryBestEffortDeletionCleanup() {
        do {
            try performDeletionCleanup()
            deletionCleanupErrorMessage = nil
        } catch {
            deletionCleanupErrorMessage = Self.message(for: error)
        }
    }

    private func performDeletionCleanup() throws {
        guard !rememberedDeletions.isEmpty,
            let notebookID = catalog?.notebookID
        else { return }
        try deletionStorage.cleanupNoteDirectories(
            rememberedDeletions,
            afterStage: { try deletionFaultInjector?($0) }
        )
        for id in rememberedDeletions {
            sessions[id] = nil
            sessionLoads[id] = nil
        }
        try importStorage.scrub(
            deletedIDs: rememberedDeletions,
            notebookID: notebookID
        )
        hasPendingImport = importStorage.hasPendingImport
        try NotebookSyncCoordinator.removeDeletedLegacyProposal(
            in: directory,
            notebookID: notebookID,
            deletedIDs: rememberedDeletions
        )
        try deletionFaultInjector?(.importJournalsScrubbed)
    }

    private func reconcileDeletionLedgerIntoCatalog() async throws {
        guard let catalog else { throw NotebookReplicaError.notJoined }
        let represented = Set(try catalog.items().map(\.id))
        let deleted = Set(try catalog.items()
            .filter(\.isPermanentlyDeleted).map(\.id))
        let missing = rememberedDeletions.intersection(represented)
            .subtracting(deleted)
        if !missing.isEmpty { try await persistCatalog(catalog.fork()) }
    }

    private static func message(for error: Error) -> String {
        let message = error.localizedDescription.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return message.isEmpty ? String(describing: error) : message
    }
}

struct ExistingNotebookNoteStorage: NoteStorage {
    let expectedID: UUID
    let base: NoteFileStorage
    func load() async -> NoteLoadResult {
        let loaded = await base.load()
        switch loaded {
        case .firstLaunch:
            return .blocked(NoteLoadFailure(current: .absent, previous: .absent))
        case .current(let snapshot) where snapshot.noteID != expectedID:
            return .blocked(NoteLoadFailure(current: .corrupt, previous: .absent))
        case .recoveryRequired(let recovery) where recovery.previous.noteID != expectedID:
            return .blocked(
                NoteLoadFailure(current: recovery.currentFailure, previous: .corrupt))
        default:
            return loaded
        }
    }
    func save(_ snapshot: NoteSnapshot) async throws {
        guard snapshot.noteID == expectedID else {
            throw NoteFileStorageError.noteIdentityMismatch
        }
        try await base.save(snapshot)
    }
    func recover(_ recovery: NoteRecovery) async throws -> NoteSnapshot {
        guard recovery.previous.noteID == expectedID else {
            throw NoteFileStorageError.noteIdentityMismatch
        }
        let snapshot = try await base.recover(recovery)
        guard snapshot.noteID == expectedID else {
            throw NoteFileStorageError.noteIdentityMismatch
        }
        return snapshot
    }
}

private extension NoteSession {
    var canAttemptRecovery: Bool {
        switch status {
        case .recoveryRequired, .blocked: true
        default: false
        }
    }
}

extension SyncRecord {
    var documentKey: String { "\(kind.rawValue):\(snapshot.noteID.uuidString)" }
}
