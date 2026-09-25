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
    @ObservationIgnored private let storagePrefix = "meh.md.navigation."
    @ObservationIgnored private var notebookID: UUID?
    @ObservationIgnored private var selectionLoadGeneration = 0
    @ObservationIgnored private var recentLoadGeneration = 0
    @ObservationIgnored private var isLoadingPreferences = false

    private(set) var selectedID: UUID?
    private(set) var selectedSession: NoteSession?
    private(set) var lastNoteID: UUID?
    private(set) var restorationMessage: String?
    private(set) var recentSessions: [UUID: NoteSession] = [:]
    var isRecentsExpanded = true { didSet { persistIfReady() } }
    var isTreeExpanded = true { didSet { persistIfReady() } }
    var isTrashExpanded = false { didSet { persistIfReady() } }
    var expandedFolderIDs: Set<UUID> = [] { didSet { persistIfReady() } }

    private var positions: [UUID: Data] = [:]

    init(replica: NotebookReplica, store: UserDefaults = .standard) {
        self.replica = replica
        self.store = store
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

    /// Restores the last active note after startup without changing Recents.
    func restoreLastSelection() async {
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
            if let session = try? await replica.openNote(id, allowingRecovery: true) {
                loaded[id] = session
            }
        }
        guard generation == recentLoadGeneration, ids == recentNoteIDs else { return }
        recentSessions = loaded
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
        notebookID.map { storagePrefix + $0.uuidString }
    }

    private func pruneUnavailable() {
        let recentEligibleNotes = recentEligibleNoteIDs
        let selectableNotes = selectableNoteIDs
        let folders = availableFolderIDs
        let oldLastNote = lastNoteID
        let oldFolders = expandedFolderIDs
        let oldPositions = positions
        expandedFolderIDs.formIntersection(folders)
        positions = positions.filter { selectableNotes.contains($0.key) }
        recentSessions = recentSessions.filter { recentNoteIDs.contains($0.key) }
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
        isLoadingPreferences = true
        defer { isLoadingPreferences = false }
        selectedID = nil
        selectedSession = nil
        lastNoteID = nil
        restorationMessage = nil
        recentSessions = [:]
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
