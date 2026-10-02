import Foundation
import NoteCore
import Observation

struct NotebookLinkCompletion: Equatable {
    let range: NSRange
    let query: String

    static func detect(in text: String, selection: NSRange) -> Self? {
        let source = text as NSString
        guard selection.length == 0, selection.location >= 2,
              selection.location <= source.length else { return nil }
        let line = source.lineRange(for: NSRange(location: selection.location - 1, length: 0))
        let prefix = source.substring(with: NSRange(
            location: line.location, length: selection.location - line.location))
        guard let opening = prefix.range(of: "[[", options: .backwards) else { return nil }
        let query = String(prefix[opening.upperBound...])
        guard !query.contains("]"), !query.contains("|"),
              !query.contains("\n"), query.count < 160 else { return nil }
        let start = line.location + NSRange(opening, in: prefix).location
        // Do not offer authoring inside an existing link or code example.
        let probe = (text as NSString).replacingCharacters(
            in: NSRange(location: selection.location, length: 0), with: query.isEmpty ? "Note]]" : "]]")
        guard NotebookLinkParser.parse(probe).contains(where: {
            $0.kind == .wiki && !$0.isEmbed && $0.range.location == start
        }) else { return nil }
        let suffix = source.substring(from: selection.location)
        let closingLength = suffix.hasPrefix("]]") ? 2 : 0
        return Self(range: NSRange(location: start,
            length: selection.location - start + closingLength), query: query)
    }
}

@MainActor
@Observable
final class NotebookLinkState {
    private struct BacklinkScope: Equatable {
        let replicaID: ObjectIdentifier
        let notebookID: UUID?
        let targetID: UUID
    }

    private(set) var notes: [NotebookLinkNote] = []
    private(set) var backlinks: [NotebookBacklink] = []
    private(set) var unavailableCount = 0
    private(set) var headingNames: [UUID: [String]] = [:]
    private(set) var isLoading = false
    private(set) var error: String?
    private var backlinkScope: BacklinkScope?
    @ObservationIgnored private var revision: NotebookSearchRevision?
    @ObservationIgnored private var corpus: NotebookLinkCorpus?
    @ObservationIgnored private var corpusReplicaID: ObjectIdentifier?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var noteAliases: [UUID: [String]] = [:]

    func refresh(replica: NotebookReplica, targetID: UUID? = nil) async {
        if let targetID { prepareBacklinks(replica: replica, targetID: targetID) }
        generation += 1
        let request = generation
        let expected = replica.searchRevision
        isLoading = true
        error = nil
        // Note names and paths are already in the catalog. Authoring should
        // not wait for every body to be read for aliases, headings, or backlinks.
        notes = replica.linkNotes
        defer { if request == generation { isLoading = false } }
        do {
            let source: NotebookLinkCorpus
            if corpusReplicaID == ObjectIdentifier(replica), expected == revision,
               let corpus { source = corpus }
            else { source = try await replica.linkCorpus() }
            try Task.checkCancellation()
            guard request == generation,
                  canPublish(expected, current: replica.searchRevision, targetID: targetID) else { return }
            let derived = await Task.detached(priority: .userInitiated) {
                let backlinks = targetID.map {
                    NotebookLinkIndex(texts: source.texts, notes: source.notes).backlinks(to: $0)
                } ?? []
                return (backlinks,
                        source.texts.mapValues { NotebookLinkParser.aliases(in: $0) },
                        source.texts.mapValues { NotebookLinkParser.headings(in: $0) })
            }.value
            guard request == generation,
                  canPublish(expected, current: replica.searchRevision, targetID: targetID) else { return }
            corpus = source
            corpusReplicaID = ObjectIdentifier(replica)
            revision = expected == replica.searchRevision ? expected : nil
            notes = source.notes
            noteAliases = derived.1
            headingNames = derived.2
            if targetID != nil {
                backlinks = derived.0
                unavailableCount = source.unavailableIDs.count
            }
            error = nil
        } catch is CancellationError { }
        catch { if request == generation { self.error = error.localizedDescription } }
    }

    /// Clear a previous note's rows synchronously, before sheet presentation
    /// or any corpus-loading suspension. Cached corpus data remains reusable.
    func prepareBacklinks(replica: NotebookReplica, targetID: UUID) {
        let scope = BacklinkScope(replicaID: ObjectIdentifier(replica),
            notebookID: replica.searchRevision.notebookID, targetID: targetID)
        if backlinkScope != scope {
            generation += 1
            backlinks = []
            unavailableCount = 0
            error = nil
            backlinkScope = scope
        }
        isLoading = true
    }

    func hasBacklinkScope(replica: NotebookReplica, targetID: UUID) -> Bool {
        backlinkScope == BacklinkScope(replicaID: ObjectIdentifier(replica),
            notebookID: replica.searchRevision.notebookID, targetID: targetID)
    }

    private func canPublish(_ expected: NotebookSearchRevision,
                            current: NotebookSearchRevision, targetID: UUID?) -> Bool {
        if targetID != nil { return expected == current }
        // Title suggestions can publish during typing. Their paths only depend
        // on catalog heads; a stale body snapshot is never cached as current.
        return expected.notebookID == current.notebookID
            && expected.catalogHeads == current.catalogHeads
    }

    func suggestions(for query: String) -> [NotebookLinkNote] {
        let name = query.components(separatedBy: "#").first ?? query
        return notes.filter {
            name.isEmpty || NotebookNoteName.title(from: $0.name)
                .localizedCaseInsensitiveContains(name)
                || $0.fullPath.localizedCaseInsensitiveContains(name)
                || (noteAliases[$0.id] ?? []).contains {
                    $0.localizedCaseInsensitiveContains(name)
                }
        }.sorted {
            let left = NotebookNoteName.title(from: $0.name)
            let right = NotebookNoteName.title(from: $1.name)
            let order = left.localizedStandardCompare(right)
            if order != .orderedSame { return order == .orderedAscending }
            if $0.path != $1.path { return $0.path < $1.path }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    func alias(for query: String, noteID: UUID) -> String? {
        guard !query.isEmpty, !query.contains("#"),
              let note = notes.first(where: { $0.id == noteID }),
              !NotebookNoteName.title(from: note.name).localizedCaseInsensitiveContains(query)
        else { return nil }
        return noteAliases[noteID]?.first { $0.localizedCaseInsensitiveContains(query) }
    }

    func clear() {
        generation += 1
        notes = []; backlinks = []; corpus = nil; revision = nil; noteAliases = [:]
        backlinkScope = nil; corpusReplicaID = nil
        unavailableCount = 0; headingNames = [:]; isLoading = false; error = nil
    }
}
