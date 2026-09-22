import Foundation
import NoteCore
import Observation

/// Search is scene-local and derived. No query, snippet, or index is synced.
@MainActor
@Observable
final class NotebookSearchState {
    private struct CorpusKey: Equatable {
        let replicaID: ObjectIdentifier
        let revision: NotebookSearchRevision
    }

    var query = ""
    var isPresented = false
    var quickQuery = ""
    var showingQuickOpen = false
    var selectedResultID: UUID?
    var quickSelectionID: UUID?
    var canFind = false
    var quickOpenRequest = 0
    var findRequest = 0
    private(set) var results: [NotebookSearchResult] = []
    private(set) var isPreparing = false
    private(set) var unavailableCount = 0
    private(set) var error: String?
    @ObservationIgnored private var corpus: NotebookSearchCorpus?
    @ObservationIgnored private var corpusRevision: NotebookSearchRevision?
    @ObservationIgnored private var corpusReplicaID: ObjectIdentifier?
    @ObservationIgnored private var preparationTask: Task<NotebookSearchCorpus, Error>?
    @ObservationIgnored private var preparationKey: CorpusKey?
    @ObservationIgnored private var resultsQuery: String?
    @ObservationIgnored private var generation = 0

    var activeQuery: String { showingQuickOpen ? quickQuery : query }
    var resultQuery: String { resultsQuery ?? activeQuery }
    var hasPreparedCorpus: Bool { corpus != nil }

    func refresh(replica: NotebookReplica, recentIDs: [UUID]) async {
        generation += 1
        let request = generation
        let revision = replica.searchRevision
        let replicaID = ObjectIdentifier(replica)
        let key = CorpusKey(replicaID: replicaID, revision: revision)
        let query = activeQuery
        let queryChanged = resultsQuery != query
        defer {
            if request == generation { isPreparing = false }
        }
        let knownReplicaID = corpusReplicaID ?? preparationKey?.replicaID
        let knownNotebookID = corpusRevision?.notebookID
            ?? preparationKey?.revision.notebookID
        let scopeChanged = (knownReplicaID != nil && knownReplicaID != replicaID)
            || (knownNotebookID != nil && knownNotebookID != revision.notebookID)
        isPreparing = true
        error = nil
        if scopeChanged {
            results = []
            unavailableCount = 0
            selectedResultID = nil
            quickSelectionID = nil
        } else {
            // A deleted or trashed note must disappear before corpus rebuilding
            // finishes. Other same-notebook rows can remain while work runs.
            let activeIDs = Set(replica.placements.lazy.filter {
                $0.item.kind == .note && !$0.isInTrash
                    && !$0.item.isPermanentlyDeleted
            }.map(\.item.id))
            results.removeAll { !activeIDs.contains($0.id) }
            if selectedResultID.map({ !activeIDs.contains($0) }) == true {
                selectedResultID = nil
            }
            if quickSelectionID.map({ !activeIDs.contains($0) }) == true {
                quickSelectionID = nil
            }
        }
        do {
            let source: NotebookSearchCorpus
            if let corpus, corpusReplicaID == replicaID, corpusRevision == revision {
                source = corpus
            } else {
                let task: Task<NotebookSearchCorpus, Error>
                if let preparationTask, preparationKey == key {
                    task = preparationTask
                } else {
                    preparationTask?.cancel()
                    task = Task { try await replica.searchCorpus() }
                    preparationTask = task
                    preparationKey = key
                }
                source = try await task.value
                if preparationKey == key {
                    preparationTask = nil
                    preparationKey = nil
                    if replica.searchRevision == revision {
                        // Cache before honoring query-task cancellation so the
                        // next keystroke can reuse this completed preparation.
                        corpus = source
                        corpusReplicaID = replicaID
                        corpusRevision = revision
                        unavailableCount = source.unavailableCount
                    }
                }
            }
            try Task.checkCancellation()
            guard replica.searchRevision == revision else { return }
            let work = Task.detached(priority: .userInitiated) {
                if query.isEmpty {
                    let byID = Dictionary(uniqueKeysWithValues: source.entries.map { ($0.id, $0) })
                    var seen: Set<UUID> = []
                    return recentIDs.compactMap { id -> NotebookSearchResult? in
                        guard seen.insert(id).inserted, let entry = byID[id] else { return nil }
                        return NotebookSearchResult(
                            id: entry.id, title: entry.title, path: entry.path,
                            excerpt: String(entry.text.prefix(180)),
                            titleMatchRange: nil, excerptMatchRange: nil,
                            bodyMatchRange: nil, matchesTitle: false
                        )
                    }
                }
                return source.search(query)
            }
            let matches = await withTaskCancellationHandler {
                await work.value
            } onCancel: { work.cancel() }
            try Task.checkCancellation()
            guard request == generation, replica.searchRevision == revision,
                  activeQuery == query else { return }
            corpus = source
            corpusReplicaID = replicaID
            corpusRevision = revision
            resultsQuery = query
            unavailableCount = source.unavailableCount
            results = matches
            if showingQuickOpen {
                let selectionIsPresent = matches.contains {
                    $0.id == quickSelectionID
                }
                if !selectionIsPresent {
                    quickSelectionID = queryChanged ? matches.first?.id : nil
                }
            }
        } catch is CancellationError {
            // The replacement request owns presentation state.
        } catch {
            if preparationKey == key {
                preparationTask = nil
                preparationKey = nil
            }
            guard request == generation else { return }
            self.error = "Search couldn’t read this notebook. Try again."
        }
    }

    func beginQuickOpen() {
        quickQuery = ""
        quickSelectionID = nil
        showingQuickOpen = true
    }

    func clear() {
        generation += 1
        preparationTask?.cancel()
        preparationTask = nil
        preparationKey = nil
        corpus = nil
        corpusReplicaID = nil
        corpusRevision = nil
        resultsQuery = nil
        results = []
        query = ""
        quickQuery = ""
        selectedResultID = nil
        quickSelectionID = nil
        isPresented = false
        showingQuickOpen = false
        unavailableCount = 0
        isPreparing = false
        error = nil
    }
}
