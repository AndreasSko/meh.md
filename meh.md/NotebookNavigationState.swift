import Foundation
import NoteCore
import Observation

/// Scene-owned navigation preferences. Recents activity and pins live in the
/// shared catalog; this state keeps only navigation and preview sessions local.
@MainActor
@Observable
final class NotebookNavigationState {
    private let replica: NotebookReplica
    @ObservationIgnored private let store: UserDefaults
    @ObservationIgnored private let sceneID: UUID?
    @ObservationIgnored private let storagePrefix = "meh.md.navigation."
    @ObservationIgnored private var notebookID: UUID?
    @ObservationIgnored private var selectionLoadGeneration = 0
    @ObservationIgnored private var recentLoadGeneration = 0
    @ObservationIgnored private var recentPreviewLoadGeneration = 0
    @ObservationIgnored private var cachedRecentPreviewRevision: NotebookSearchRevision?
    @ObservationIgnored private var recentPreviewCacheOrder: [UUID] = []
    @ObservationIgnored private var isLoadingPreferences = false
    @ObservationIgnored private var hasStoredPreferences = false

    private(set) var selectedID: UUID?
    private(set) var selectedSession: NoteSession?
    private(set) var lastNoteID: UUID?
    private(set) var restorationMessage: String?
    private(set) var recentSessions: [UUID: NoteSession] = [:]
    /// Bounded row excerpts for expanded Recents, without editor sessions.
    private(set) var recentPreviewText: [UUID: String] = [:]
    var isRecentsExpanded = true { didSet { persistIfReady() } }
    var isTreeExpanded = true { didSet { persistIfReady() } }
    var isTrashExpanded = false { didSet { persistIfReady() } }
    var expandedFolderIDs: Set<UUID> = [] { didSet { persistIfReady() } }

    private var positions: [UUID: Data] = [:]

    /// Pass a stable scene ID (for example, from SceneStorage) for each window.
    /// Omitting it retains the legacy notebook-wide preference behavior.
    init(replica: NotebookReplica, store: UserDefaults = .standard, sceneID: UUID? = nil) {
        self.replica = replica
        self.store = store
        self.sceneID = sceneID
        notebookID = replica.catalogSnapshot?.notebookID
        loadPreferences()
        pruneUnavailable()
    }

    /// Call after the replica's catalog changes. It prunes vanished or trashed
    /// items without treating remote content changes as local activity.
    func refreshAvailability() {
        let currentNotebookID = replica.catalogSnapshot?.notebookID
        if currentNotebookID != notebookID {
            notebookID = currentNotebookID
            selectionLoadGeneration += 1
            recentLoadGeneration += 1
            recentPreviewLoadGeneration += 1
            selectedID = nil
            selectedSession = nil
            recentSessions = [:]
            loadPreferences()
        }
        pruneUnavailable()
    }

    /// Remembers the last opened note without changing the edited-note order.
    func recordOpened(_ id: UUID) {
        guard lastNoteID != id, recentEligibleNoteIDs.contains(id) else { return }
        restorationMessage = nil
        lastNoteID = id
        savePreferences()
    }

    /// The shared catalog owns recent ordering; this scene only reads it.
    var recentNoteIDs: [UUID] { replica.recentNotes.map(\.id) }
    var allRecentNoteIDs: [UUID] { replica.allRecentNotes.map(\.id) }
    var recentPreviewRevision: NotebookSearchRevision { replica.searchRevision }

    /// Installs a note the scene has already flushed and opened successfully.
    /// Trash notes may remain active, but are never remembered in Recents.
    @discardableResult
    func installSelection(
        _ id: UUID,
        session: NoteSession,
        recordActivity: Bool
    ) -> Bool {
        guard selectableNoteIDs.contains(id) else { return false }
        if let snapshot = session.currentSnapshot, snapshot.noteID != id { return false }
        selectionLoadGeneration += 1
        restorationMessage = nil
        selectedID = id
        selectedSession = session
        if recordActivity { recordOpened(id) }
        return true
    }

    func clearSelection() {
        selectedID = nil
        selectedSession = nil
        recordClosed()
    }

    /// Returning to the compact browser ends restoration, while the hidden
    /// editor keeps its session and can finish saving its position.
    func recordClosed() {
        selectionLoadGeneration += 1
        lastNoteID = nil
        restorationMessage = nil
        savePreferences()
    }

    /// Restores this window's saved note, or opens a requested note for a new
    /// window that has no saved selection yet.
    func restoreLastSelection(preferredNoteID: UUID? = nil) async {
        let startingGeneration = selectionLoadGeneration
        if !hasStoredPreferences,
           let preferredNoteID,
           recentEligibleNoteIDs.contains(preferredNoteID),
           let session = try? await replica.openNote(preferredNoteID, allowingRecovery: true),
           session.currentSnapshot?.noteID == nil
                || session.currentSnapshot?.noteID == preferredNoteID
        {
            guard startingGeneration == selectionLoadGeneration else { return }
            _ = installSelection(preferredNoteID, session: session, recordActivity: true)
            return
        }
        guard startingGeneration == selectionLoadGeneration else { return }
        guard let id = lastNoteID else { return }
        guard recentEligibleNoteIDs.contains(id) else {
            lastNoteID = nil
            restorationMessage = "Last note unavailable. Choose another note."
            savePreferences()
            return
        }
        selectionLoadGeneration += 1
        let generation = selectionLoadGeneration
        guard let session = try? await replica.openNote(id, allowingRecovery: true)
        else {
            guard generation == selectionLoadGeneration, lastNoteID == id else { return }
            lastNoteID = nil
            restorationMessage = "Last note unavailable. Choose another note."
            savePreferences()
            return
        }
        guard generation == selectionLoadGeneration,
              lastNoteID == id,
              recentEligibleNoteIDs.contains(id),
              session.currentSnapshot?.noteID == nil || session.currentSnapshot?.noteID == id
        else { return }
        restorationMessage = nil
        selectedID = id
        selectedSession = session
    }

    /// Opens displayed Recents sessions without recording activity.
    func loadRecentSessions() async {
        recentLoadGeneration += 1
        let generation = recentLoadGeneration
        let ids = recentNoteIDs
        var loaded: [UUID: NoteSession] = [:]
        for id in ids where recentEligibleNoteIDs.contains(id) {
            guard !Task.isCancelled, generation == recentLoadGeneration else { return }
            if let session = try? await replica.openNote(id, allowingRecovery: true) {
                loaded[id] = session
            }
        }
        guard !Task.isCancelled, generation == recentLoadGeneration,
              ids == recentNoteIDs else { return }
        recentSessions = loaded
    }

    /// Request the visible rows plus a small prefetch margin. Work is bounded
    /// to 64 rows per request; the cache keeps the 128 most recently requested
    /// excerpts. New viewport requests supersede earlier asynchronous loads.
    func loadRecentPreviews(for requestedIDs: [UUID]) async {
        recentPreviewLoadGeneration += 1
        let generation = recentPreviewLoadGeneration
        let revision = recentPreviewRevision
        if cachedRecentPreviewRevision != revision {
            recentPreviewText = [:]
            recentPreviewCacheOrder = []
            cachedRecentPreviewRevision = revision
        }
        let available = Set(allRecentNoteIDs)
        var seen: Set<UUID> = []
        let ids = requestedIDs.filter {
            available.contains($0) && seen.insert($0).inserted
        }.prefix(64)
        for id in ids {
            guard !Task.isCancelled, generation == recentPreviewLoadGeneration,
                  revision == recentPreviewRevision else { return }
            if recentPreviewText[id] == nil {
                let source: String?
                do {
                    source = try await replica.noteTextPrefix(for: id)
                } catch {
                    if Task.isCancelled { return }
                    continue
                }
                guard !Task.isCancelled,
                      generation == recentPreviewLoadGeneration,
                      revision == recentPreviewRevision,
                      Set(allRecentNoteIDs).contains(id) else { return }
                guard let source else { continue }
                recentPreviewText[id] = NotebookRecentPreview.text(from: source)
            }
            recentPreviewCacheOrder.removeAll { $0 == id }
            recentPreviewCacheOrder.append(id)
            while recentPreviewCacheOrder.count > 128 {
                recentPreviewText[recentPreviewCacheOrder.removeFirst()] = nil
            }
            await Task.yield()
        }
    }

    func position(for id: UUID) -> Data? {
        positions[id]
    }

    func setPosition(_ position: Data?, for id: UUID) {
        guard selectableNoteIDs.contains(id) else { return }
        positions[id] = position
        savePreferences()
    }

    func setFolderExpanded(_ id: UUID, isExpanded: Bool) {
        guard availableFolderIDs.contains(id) else { return }
        if isExpanded {
            expandedFolderIDs.insert(id)
        } else {
            expandedFolderIDs.remove(id)
        }
    }

    private var selectableNoteIDs: Set<UUID> {
        Set(replica.placements.lazy.filter {
            $0.item.kind == .note && !$0.item.isPermanentlyDeleted
        }.map(\.item.id))
    }

    private var recentEligibleNoteIDs: Set<UUID> {
        Set(replica.placements.lazy.filter {
            $0.item.kind == .note && !$0.isInTrash && !$0.item.isPermanentlyDeleted
        }.map(\.item.id))
    }

    private var availableFolderIDs: Set<UUID> {
        Set(replica.placements.lazy.filter {
            $0.item.kind == .folder && !$0.isInTrash && !$0.item.isPermanentlyDeleted
        }.map(\.item.id))
    }

    private var storageKey: String? {
        notebookID.map { notebookID in
            let notebookKey = storagePrefix + notebookID.uuidString
            return sceneID.map { notebookKey + ".scene." + $0.uuidString } ?? notebookKey
        }
    }

    private func migrateLegacyPreferencesIfNeeded() {
        guard let notebookID, let sceneID, let storageKey,
              store.data(forKey: storageKey) == nil else { return }
        let legacyKey = storagePrefix + notebookID.uuidString
        let claimKey = legacyKey + ".migratedScene"
        guard store.string(forKey: claimKey) == nil,
              let legacyData = store.data(forKey: legacyKey) else { return }
        store.set(legacyData, forKey: storageKey)
        store.set(sceneID.uuidString, forKey: claimKey)
    }

    private func pruneUnavailable() {
        let recentEligibleNotes = recentEligibleNoteIDs
        let selectableNotes = selectableNoteIDs
        let folders = availableFolderIDs
        let oldLastNote = lastNoteID
        let oldFolders = expandedFolderIDs
        let oldPositions = positions
        let wasLoadingPreferences = isLoadingPreferences
        isLoadingPreferences = true
        expandedFolderIDs.formIntersection(folders)
        isLoadingPreferences = wasLoadingPreferences
        positions = positions.filter { selectableNotes.contains($0.key) }
        recentSessions = recentSessions.filter { recentNoteIDs.contains($0.key) }
        let allRecentIDs = Set(allRecentNoteIDs)
        recentPreviewText = recentPreviewText.filter { allRecentIDs.contains($0.key) }
        recentPreviewCacheOrder.removeAll { !allRecentIDs.contains($0) }
        if lastNoteID.map({ !recentEligibleNotes.contains($0) }) == true {
            lastNoteID = nil
        }
        if oldLastNote != lastNoteID
            || oldFolders != expandedFolderIDs || oldPositions != positions
        {
            savePreferences()
        }
    }

    private func loadPreferences() {
        migrateLegacyPreferencesIfNeeded()
        isLoadingPreferences = true
        defer { isLoadingPreferences = false }
        hasStoredPreferences = false
        selectedID = nil
        selectedSession = nil
        lastNoteID = nil
        restorationMessage = nil
        recentSessions = [:]
        recentPreviewText = [:]
        recentPreviewCacheOrder = []
        cachedRecentPreviewRevision = nil
        isRecentsExpanded = true
        isTreeExpanded = true
        isTrashExpanded = false
        expandedFolderIDs = []
        positions = [:]
        guard let storageKey, let data = store.data(forKey: storageKey) else {
            return
        }
        guard let preferences = try? JSONDecoder().decode(
            StoredPreferences.self, from: data
        ) else {
            store.removeObject(forKey: storageKey)
            return
        }
        hasStoredPreferences = true
        lastNoteID = preferences.lastNoteID
        isRecentsExpanded = preferences.isRecentsExpanded
        isTreeExpanded = preferences.isTreeExpanded
        isTrashExpanded = preferences.isTrashExpanded ?? false
        expandedFolderIDs = Set(preferences.expandedFolderIDs)
        positions = preferences.positions
    }

    private func persistIfReady() {
        if !isLoadingPreferences { savePreferences() }
    }

    private func savePreferences() {
        guard let storageKey else { return }
        let preferences = StoredPreferences(
            lastNoteID: lastNoteID,
            isRecentsExpanded: isRecentsExpanded,
            isTreeExpanded: isTreeExpanded,
            isTrashExpanded: isTrashExpanded,
            expandedFolderIDs: Array(expandedFolderIDs),
            positions: positions
        )
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        store.set(data, forKey: storageKey)
        hasStoredPreferences = true
    }
}

private struct StoredPreferences: Codable {
    let lastNoteID: UUID?
    // Kept solely so existing local navigation preferences continue to decode.
    // Synchronized Recents deliberately do not read or write this value.
    let recentNoteIDs: [UUID]?
    let isRecentsExpanded: Bool
    let isTreeExpanded: Bool
    let isTrashExpanded: Bool?
    let expandedFolderIDs: [UUID]
    let positions: [UUID: Data]

    init(
        lastNoteID: UUID?,
        isRecentsExpanded: Bool,
        isTreeExpanded: Bool,
        isTrashExpanded: Bool?,
        expandedFolderIDs: [UUID],
        positions: [UUID: Data]
    ) {
        self.lastNoteID = lastNoteID
        recentNoteIDs = nil
        self.isRecentsExpanded = isRecentsExpanded
        self.isTreeExpanded = isTreeExpanded
        self.isTrashExpanded = isTrashExpanded
        self.expandedFolderIDs = expandedFolderIDs
        self.positions = positions
    }
}
