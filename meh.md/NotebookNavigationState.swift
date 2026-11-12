import Foundation
import NoteCore
import Observation

struct NotebookSnippetReturn: Equatable {
    let noteID: UUID
    let snippetID: UUID
}

/// Scene-owned navigation preferences. Recents activity and pins live in the
/// shared catalog; this state keeps only navigation and preview sessions local.
@MainActor
@Observable
final class NotebookNavigationState {
    private let replica: NotebookReplica
    @ObservationIgnored private let store: UserDefaults
    @ObservationIgnored private let sceneID: UUID?
    @ObservationIgnored private let storagePrefix = "meh.md.navigation."
    private var notebookID: UUID?
    @ObservationIgnored private var selectionLoadGeneration = 0
    @ObservationIgnored private var recentLoadGeneration = 0
    @ObservationIgnored private var previewLoadGeneration = 0
    /// What each cached excerpt was read from, so only changed notes reload.
    @ObservationIgnored private var previewSources: [UUID: PreviewSource] = [:]
    @ObservationIgnored private var previewCacheOrder: [UUID] = []
    @ObservationIgnored private var isLoadingPreferences = false
    @ObservationIgnored private var hasStoredPreferences = false

    private(set) var selectedID: UUID? {
        didSet {
            if selectedID != snippetReturn?.snippetID { snippetReturn = nil }
        }
    }
    /// The note a selected snippet was opened from for editing. It ends once
    /// the selection leaves the snippet.
    private(set) var snippetReturn: NotebookSnippetReturn?
    /// A snippet to insert once its note's editor is ready again.
    @ObservationIgnored var pendingSnippetInsertion: NotebookSnippetReturn?
    private(set) var selectedSession: NoteSession?
    private(set) var lastNoteID: UUID?
    private(set) var restorationMessage: String?
    private(set) var recentSessions: [UUID: NoteSession] = [:]
    /// Bounded row excerpts for Recents and Files, without editor sessions.
    private(set) var previewText: [UUID: String] = [:]
    /// How long edits must pause before row excerpts refresh.
    @ObservationIgnored var previewRefreshDelay: Duration = .seconds(2)
    var isRecentsExpanded = true { didSet { persistIfReady() } }
    var isTreeExpanded = true { didSet { persistIfReady() } }
    var isTrashExpanded = false { didSet { persistIfReady() } }
    var expandedFolderIDs: Set<UUID> = [] { didSet { persistIfReady() } }
    /// Folders opened only to show a note picked in Recents. The next pick
    /// in Recents closes them again, unless they were kept meanwhile.
    private(set) var recentRevealFolderIDs: Set<UUID> = []

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

    /// Call once the snippet is selected, after it was opened from `noteID`.
    func beginSnippetEdit(_ snippetID: UUID, from noteID: UUID) {
        guard selectedID == snippetID, noteID != snippetID else { return }
        snippetReturn = NotebookSnippetReturn(noteID: noteID, snippetID: snippetID)
    }

    /// Call after the replica's catalog changes. It prunes vanished or trashed
    /// items without treating remote content changes as local activity.
    func refreshAvailability() {
        let currentNotebookID = replica.catalogSnapshot?.notebookID
        if currentNotebookID != notebookID {
            notebookID = currentNotebookID
            selectionLoadGeneration += 1
            recentLoadGeneration += 1
            previewLoadGeneration += 1
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

    /// The Settings › Appearance key for how many notes Recents shows.
    static let recentCountKey = "library.recentCount"
    static let recentCountRange = 3...15
    static let defaultRecentCount = 5

    /// The Settings › Appearance key for a preview line under notes in Files.
    static let filePreviewsKey = "library.filePreviews"

    /// How many notes Recents shows before More. Every pin always shows.
    var recentCount = NotebookNavigationState.defaultRecentCount

    /// The shared catalog owns recent ordering; this scene only reads it.
    var recentNoteIDs: [UUID] {
        let count = max(recentCount, replica.pinnedRecentCount)
        return replica.allRecentNotes.prefix(count).map(\.id)
    }
    /// Changes whenever the Recents sessions must load again. Switching to
    /// another notebook, for example after combining, clears them even when
    /// the same notes lead Recents.
    var recentSessionsRequest: NotebookRecentSessionsRequest {
        NotebookRecentSessionsRequest(notebookID: notebookID, ids: recentNoteIDs)
    }
    var allRecentNoteIDs: [UUID] { replica.allRecentNotes.map(\.id) }
    var previewRevision: NotebookSearchRevision { replica.searchRevision }

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

    /// Keeps the requested excerpts current while the rows are shown.
    /// Missing excerpts load right away. Edits refresh them only after typing
    /// pauses, so writing never waits on Recents or Files.
    func maintainPreviews(for requestedIDs: [UUID]) async {
        var loaded = previewRevision
        await loadPreviews(for: requestedIDs)
        for await revision in Observations({ self.previewRevision }) {
            guard revision != loaded else { continue }
            var pending = revision
            while true {
                do { try await Task.sleep(for: previewRefreshDelay) } catch { return }
                let current = previewRevision
                if current == pending { break }
                pending = current
            }
            await loadPreviews(for: requestedIDs)
            loaded = pending
        }
    }

    /// Request the visible rows of Recents and Files plus a small prefetch
    /// margin. Work is bounded to 64 rows per request; the cache keeps the
    /// 128 most recently requested excerpts. Only missing excerpts and those
    /// of changed notes load again; the rest keep showing until replaced.
    func loadPreviews(for requestedIDs: [UUID]) async {
        previewLoadGeneration += 1
        let generation = previewLoadGeneration
        let revision = previewRevision
        let available = recentEligibleNoteIDs
        var seen: Set<UUID> = []
        let ids = requestedIDs.filter {
            available.contains($0) && seen.insert($0).inserted
        }.prefix(64)
        for id in ids {
            guard !Task.isCancelled, generation == previewLoadGeneration else { return }
            let source = PreviewSource(id, in: revision)
            if previewText[id] == nil || previewSources[id] != source {
                let text: String?
                do {
                    text = try await replica.noteTextPrefix(for: id)
                } catch {
                    if Task.isCancelled { return }
                    continue
                }
                guard !Task.isCancelled,
                      generation == previewLoadGeneration,
                      recentEligibleNoteIDs.contains(id) else { return }
                guard let text else { continue }
                let preview = NotebookRecentPreview.rowText(from: text)
                if previewText[id] != preview { previewText[id] = preview }
                previewSources[id] = source
            }
            previewCacheOrder.removeAll { $0 == id }
            previewCacheOrder.append(id)
            while previewCacheOrder.count > 128 {
                let evicted = previewCacheOrder.removeFirst()
                previewText[evicted] = nil
                previewSources[evicted] = nil
            }
            await Task.yield()
        }
    }

    static let recentMoveFolderLimit = 3

    /// The folders items last moved to, newest first, that still exist
    /// outside Trash. Every window of the notebook on this device shares them.
    var recentMoveFolderIDs: [UUID] {
        let folders = availableFolderIDs
        return storedMoveFolderIDs.filter(folders.contains)
    }

    /// Remembers a folder items were moved to. Top Level is always at hand,
    /// so it isn't kept.
    func recordMoveDestination(_ folderID: UUID?) {
        guard let folderID, let moveFoldersKey,
              availableFolderIDs.contains(folderID) else { return }
        let ids = [folderID] + recentMoveFolderIDs.filter { $0 != folderID }
        store.set(ids.prefix(Self.recentMoveFolderLimit).map(\.uuidString),
                  forKey: moveFoldersKey)
    }

    private var storedMoveFolderIDs: [UUID] {
        guard let moveFoldersKey else { return [] }
        return (store.array(forKey: moveFoldersKey) as? [String] ?? [])
            .compactMap(UUID.init(uuidString:))
    }

    func position(for id: UUID) -> Data? {
        positions[id]
    }

    func setPosition(_ position: Data?, for id: UUID) {
        guard selectableNoteIDs.contains(id) else { return }
        positions[id] = position
        savePreferences()
    }

    /// Shows a note picked in Recents in Files. Folders the previous pick
    /// opened close first, so browsing Recents doesn't leave Files unfolded.
    func revealFromRecents(ancestors: [UUID]) {
        let folders = availableFolderIDs
        expandedFolderIDs.subtract(recentRevealFolderIDs)
        let opened = Set(ancestors).intersection(folders).subtracting(expandedFolderIDs)
        expandedFolderIDs.formUnion(opened)
        recentRevealFolderIDs = opened
    }

    /// Someone used Files directly, so what Recents opened stays open.
    func keepRevealedFolders() {
        recentRevealFolderIDs = []
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

    private var moveFoldersKey: String? {
        notebookID.map { storagePrefix + $0.uuidString + ".moveFolders" }
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
        previewText = previewText.filter { recentEligibleNotes.contains($0.key) }
        previewSources = previewSources.filter { recentEligibleNotes.contains($0.key) }
        previewCacheOrder.removeAll { !recentEligibleNotes.contains($0) }
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
        previewText = [:]
        previewCacheOrder = []
        previewSources = [:]
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

struct NotebookRecentSessionsRequest: Hashable {
    let notebookID: UUID?
    let ids: [UUID]
}

/// An open note changes with its editor; a stored one only with note bodies.
private enum PreviewSource: Equatable {
    case editor(Data)
    case stored(UInt64)

    init(_ id: UUID, in revision: NotebookSearchRevision) {
        self = revision.openNotes.first { $0.id == id }
            .map { .editor($0.revision) } ?? .stored(revision.bodyGeneration)
    }
}
