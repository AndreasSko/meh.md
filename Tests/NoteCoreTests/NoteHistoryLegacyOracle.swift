import Automerge
import Foundation

@testable import NoteCore

/// Previous historical-difference implementation used as a semantic oracle.
/// This intentionally retains the old algorithm, independently of production.
final class NoteHistoryLegacyOracle {
    private let document: Document
    private let textObject: ObjId
    init(snapshot: NoteSnapshot) throws {
        document = try Document(snapshot.data)
        guard case let .Object(object, .Text) =
            try document.get(obj: .ROOT, key: "text") else {
            throw NoteHistoryError.versionUnavailable
        }
        textObject = object
    }
    func historyVersions() throws -> [NoteHistoryVersion] {

        struct Candidate {
            var frontier: Set<ChangeHash>
            var date: Date?
            let actor: ActorId
            let isTypingEdit: Bool
            let startsNewRun: Bool
            let isRestore: Bool
        }

        var frontier = Set<ChangeHash>()
        var candidates: [Candidate] = []
        var previousModifiedAt: Date?

        // getHistory is causal, not chronological. Each prefix has its own
        // frontier; a concurrent change removes only its actual dependencies.
        for hash in document.getHistory() {
            try Task.checkCancellation()
            guard let change = document.change(hash: hash) else { continue }
            let previousFrontier = frontier
            frontier.subtract(change.deps)
            frontier.insert(hash)

            // Difference reports visible text patches without returning the
            // historical body to the caller. The browser loads selected text
            // only when that version is opened.
            let bodyPatches = document.difference(
                from: previousFrontier, to: frontier
            ).filter { patchChangesBody($0) }
            let textChanged = !bodyPatches.isEmpty
            let modifiedAt = try historicalModifiedAt(at: frontier)

            if textChanged {
                candidates.append(Candidate(
                    frontier: frontier,
                    date: nil,
                    actor: change.actorId,
                    isTypingEdit: bodyPatches.count <= 2
                        && bodyPatches.allSatisfy(isSingleCharacterEdit),
                    startsNewRun: bodyPatches.contains { patch in
                        if case let .SpliceText(_, _, value, _) =
                            patch.action {
                            return value == "\n"
                        }
                        return false
                    },
                    isRestore: change.message == "Restore note text"
                ))
            } else if !candidates.isEmpty {
                // Metadata writes belong to the same visible text state.
                candidates[candidates.count - 1].frontier = frontier
            }

            if textChanged,
               modifiedAt != previousModifiedAt,
               let modifiedAt,
               !candidates.isEmpty,
               candidates[candidates.count - 1].date == nil {
                // Prefer the note's content date when it identifies this
                // edit, including imported creation dates.
                candidates[candidates.count - 1].date = modifiedAt
            } else if textChanged,
                      !candidates.isEmpty,
                      candidates[candidates.count - 1].date == nil,
                      change.timestamp.timeIntervalSince1970 != 0 {
                // The content date is monotonic and can stay unchanged for
                // rapid edits or a clock correction. Automerge still records
                // when it committed each text change.
                candidates[candidates.count - 1].date = change.timestamp
            }
            previousModifiedAt = modifiedAt
        }

        var versions: [NoteHistoryVersion] = []
        var frontiers: [String: Set<ChangeHash>] = [:]
        func isSameTypingRun(
            _ previous: Candidate,
            _ next: Candidate,
            nextIndex: Int
        ) -> Bool {
            guard nextIndex > 1,
                  previous.isTypingEdit, next.isTypingEdit,
                  !next.startsNewRun,
                  !previous.isRestore, !next.isRestore,
                  previous.actor == next.actor,
                  let earlier = previous.date,
                  let later = next.date else { return false }
            let gap = later.timeIntervalSince(earlier)
            return gap >= 0 && gap <= 10
        }
        // Candidate after the final historical version is live Current.
        // A run of single-character edits has one overview stop at its final
        // state. All underlying causal states stay in the detail list.
        for index in candidates.indices.dropLast() {
            let candidate = candidates[index]
            let id = candidate.frontier.map(\.debugDescription)
                .sorted().joined(separator: ",")
            versions.append(NoteHistoryVersion(
                id: id,
                ordinal: versions.count + 1,
                date: candidate.date,
                isOverviewStop: !isSameTypingRun(
                    candidates[index], candidates[index + 1],
                    nextIndex: index + 1
                )
            ))
            frontiers[id] = candidate.frontier
        }
        return versions
    }

    private func isSingleCharacterEdit(_ patch: Patch) -> Bool {
        switch patch.action {
        case let .SpliceText(_, _, value, _):
            return value.count == 1
        case let .DeleteSeq(deletion):
            return deletion.length == 1
        default:
            return false
        }
    }

    private func patchChangesBody(_ patch: Patch) -> Bool {
        switch patch.action {
        case let .SpliceText(obj, _, _, _),
             let .Insert(obj, _, _):
            return obj == textObject
        case let .Put(obj, prop, value):
            if obj == textObject { return true }
            return obj == .ROOT && prop == .Key("text")
                && value == .Object(textObject, .Text)
        case let .DeleteSeq(deletion):
            return deletion.obj == textObject
        case let .Conflict(obj, _):
            return obj == textObject
        case .Increment, .DeleteMap, .Marks:
            return false
        }
    }

    private func historicalModifiedAt(
        at frontier: Set<ChangeHash>
    ) throws -> Date? {
        let values = try document.getAllAt(
            obj: .ROOT, key: "modifiedAt", heads: frontier
        )
        var dates: [Date] = []
        for value in values {
            guard case let .Scalar(.Timestamp(date)) = value,
                  let normalized = date.noteTimestamp else {
                throw NoteDocumentError.invalidModifiedAt
            }
            dates.append(normalized)
        }
        return dates.max()
    }

}
