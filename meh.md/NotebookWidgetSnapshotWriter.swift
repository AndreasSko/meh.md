import Foundation
import MehWidgetData
import NoteCore
import WidgetKit
#if os(iOS)
import UIKit
#endif

/// Keeps the widgets' copy of Recents current. It writes after the catalog
/// changes, shortly after typing pauses, and when the app leaves the
/// foreground, and reloads widgets only when the copy changed.
@MainActor
final class NotebookWidgetSnapshotWriter {
    static let shared = NotebookWidgetSnapshotWriter()

    /// Pins plus this many other notes cover the largest widget.
    static let recentLimit = 10
    static let contentCharacterLimit = 1_200

    private let store = MehWidgetStore()
    private var cache: [UUID: MehWidgetSnapshot.Content] = [:]
    private var staleIDs: Set<UUID> = []
    private var pending: Task<Void, Never>?
    private weak var replica: NotebookReplica?

    /// - Parameter editedID: a note whose text changed; only it is read
    ///   again. Without it, every shown note is read again.
    func schedule(
        _ replica: NotebookReplica, editedID: UUID? = nil,
        delay: Duration = .seconds(2)
    ) {
        guard store != nil else { return }
        if self.replica !== replica {
            self.replica = replica
            cache = [:]
        }
        if let editedID {
            staleIDs.insert(editedID)
        } else {
            staleIDs.formUnion(cache.keys)
        }
        pending?.cancel()
        pending = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.write(replica)
        }
    }

    /// Writes now, when the app leaves the foreground. On iOS the app asks
    /// for a little background time so suspension doesn't cut the write.
    func flush(_ replica: NotebookReplica) {
        schedule(replica, delay: .zero)
        #if os(iOS)
        guard let pending else { return }
        let application = UIApplication.shared
        var task = UIBackgroundTaskIdentifier.invalid
        let end = {
            guard task != .invalid else { return }
            application.endBackgroundTask(task)
            task = .invalid
        }
        task = application.beginBackgroundTask(withName: "Widget notes") {
            pending.cancel()
            end()
        }
        Task {
            await pending.value
            end()
        }
        #endif
    }

    private func write(_ replica: NotebookReplica) async {
        guard let store, replica.catalogSnapshot != nil else { return }
        let active = replica.placements.filter {
            !$0.isInTrash && !$0.item.isPermanentlyDeleted
        }
        let byID = Dictionary(active.map { ($0.item.id, $0) }) { first, _ in first }
        let notes = active.filter { $0.item.kind == .note }.map { placement in
            MehWidgetSnapshot.Note(
                id: placement.item.id,
                title: NotebookNoteName.title(from: placement.displayName),
                folders: folders(of: placement, in: byID)
            )
        }
        let noteIDs = Set(notes.map(\.id))

        let pins = replica.allRecentNotes.filter(\.isPinned)
        let others = replica.allRecentNotes.filter { !$0.isPinned }
            .prefix(Self.recentLimit)
        let recents = (pins + others).map {
            MehWidgetSnapshot.Recent(id: $0.id, isPinned: $0.isPinned)
        }
        let requested = store.requestedNoteIDs().intersection(noteIDs)
        try? store.keepRequests(noteIDs)
        let wanted = Set(recents.map(\.id)).union(requested)

        cache = cache.filter { wanted.contains($0.key) }
        for id in wanted where cache[id] == nil || staleIDs.contains(id) {
            guard !Task.isCancelled else { return }
            let preview = try? await replica.notePreview(
                for: id, characterLimit: Self.contentCharacterLimit
            )
            // A superseded write must not touch the cache the newer one uses.
            guard !Task.isCancelled else { return }
            guard let preview else {
                cache[id] = nil
                continue
            }
            cache[id] = MehWidgetSnapshot.Content(
                id: id, text: preview.text,
                excerpt: NotebookRecentPreview.text(from: preview.text),
                modifiedAt: preview.modifiedAt
            )
        }
        guard !Task.isCancelled, self.replica === replica else { return }
        staleIDs = []

        let preferences = NotebookEditorPreferences.store
        let snapshot = MehWidgetSnapshot(
            notes: notes,
            recents: recents,
            contents: wanted.sorted { $0.uuidString < $1.uuidString }
                .compactMap { cache[$0] },
            ink: preferences.string(forKey: MehPalette.inkKey)
                ?? MehPalette.Ink.black.rawValue,
            highlighter: preferences.string(forKey: MehPalette.highlighterKey)
                ?? MehPalette.Highlighter.yellow.rawValue
        )
        if (try? store.save(snapshot)) == true {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    private func folders(
        of placement: NotebookPlacement, in byID: [UUID: NotebookPlacement]
    ) -> [String] {
        var names: [String] = []
        var parentID = placement.parentID
        var seen: Set<UUID> = []
        while let id = parentID, seen.insert(id).inserted, let parent = byID[id] {
            names.append(parent.displayName)
            parentID = parent.parentID
        }
        return names.reversed()
    }
}
