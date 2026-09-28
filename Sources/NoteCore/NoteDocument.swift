import Automerge
import Foundation

enum NoteDocumentError: Error, Equatable {
    case missingNoteID
    case invalidNoteID
    case missingSchemaVersion
    case invalidSchemaVersion
    case unsupportedSchemaVersion
    case missingText
    case invalidText
    case invalidCreatedAt
    case invalidModifiedAt
    case unexpectedTextEncoding
    case noteIdentityMismatch
}

final class NoteDocument {
    static let supportedSchemaVersion: UInt64 = 1

    private static let noteIDKey = "noteID"
    private static let schemaVersionKey = "schemaVersion"
    private static let textKey = "text"
    private static let createdAtKey = "createdAt"
    private static let modifiedAtKey = "modifiedAt"
    private static let restoreChangeMessage = "Restore note text"
    private static let typingRunMaximumGap: TimeInterval = 10

    private let document: Document
    private let textObject: ObjId
    private var historyCache: (
        heads: Set<String>,
        versions: [NoteHistoryVersion],
        frontiers: [String: Set<ChangeHash>]
    )?

    let noteID: UUID

    var text: String {
        get throws {
            try document.text(obj: textObject)
        }
    }

    var metadata: NoteMetadata {
        get throws {
            NoteMetadata(
                createdAt: try date(
                    forKey: Self.createdAtKey,
                    invalid: .invalidCreatedAt,
                    reduce: min
                ),
                modifiedAt: try date(
                    forKey: Self.modifiedAtKey,
                    invalid: .invalidModifiedAt,
                    reduce: max
                )
            )
        }
    }

    var heads: Set<String> {
        Set(document.heads().map(\.debugDescription))
    }

    /// An editor revision contains only the current change heads, not a
    /// serialized document or its full history.
    var editorHeads: Data { document.heads().raw() }

    func applyEditorText(_ replacement: String, basedOn revision: Data) throws {
        guard let heads = revision.heads(), !heads.isEmpty else {
            throw SyncError.invalidRecord
        }
        if heads == document.heads() {
            try replaceAll(with: replacement)
        } else {
            // forkAt establishes ancestry using this document's own history.
            // Only the stale-editor path needs a fork; ordinary typing edits
            // the live document directly without loading or merging a copy.
            let branch = try NoteDocument(validating: document.forkAt(heads: heads))
            try branch.replaceAll(with: replacement)
            try document.merge(other: branch.document)
        }
    }

    var historyHeads: Set<String> {
        Set(document.getHistory().map(\.debugDescription))
    }

    var historyCount: Int {
        document.getHistory().count
    }

    /// Past text states in causal order. The current text is represented by
    /// the live session, so it is omitted even if metadata followed its edit.
    func historyVersions() throws -> [NoteHistoryVersion] {
        if let historyCache, historyCache.heads == heads {
            return historyCache.versions
        }

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
                    isRestore: change.message == Self.restoreChangeMessage
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
            return gap >= 0 && gap <= Self.typingRunMaximumGap
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
        historyCache = (heads, versions, frontiers)
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
            return obj == .ROOT && prop == .Key(Self.textKey)
                && value == .Object(textObject, .Text)
        case let .DeleteSeq(deletion):
            return deletion.obj == textObject
        case let .Conflict(obj, _):
            return obj == textObject
        case .Increment, .DeleteMap, .Marks:
            return false
        }
    }

    func historicalText(for version: NoteHistoryVersion) throws -> String {
        let frontier: Set<ChangeHash>
        if let cached = historyCache?.frontiers[version.id] {
            frontier = cached
        } else {
            // A remote merge can change the displayed sequence while an old
            // selection is open. Its causal frontier remains reconstructable.
            let byID = Dictionary(
                uniqueKeysWithValues: document.getHistory().map {
                    ($0.debugDescription, $0)
                }
            )
            let parts = version.id.split(separator: ",").map(String.init)
            let hashes = parts.compactMap { byID[$0] }
            guard !parts.isEmpty,
                  parts == parts.sorted(),
                  hashes.count == parts.count,
                  Set(hashes).count == parts.count else {
                throw NoteHistoryError.versionUnavailable
            }
            frontier = Set(hashes)
        }
        return try document.textAt(obj: textObject, heads: frontier)
    }

    func restoreHistoryVersion(
        _ version: NoteHistoryVersion,
        at modificationDate: Date = Date()
    ) throws {
        let restoredText = try historicalText(for: version)
        guard !restoredText.utf8.elementsEqual((try text).utf8) else { return }
        // Commit the restore as one marked change so it remains a boundary
        // even when only one character differs.
        try replaceAll(
            with: restoredText,
            at: modificationDate,
            changeMessage: Self.restoreChangeMessage
        )
    }

    private func historicalModifiedAt(
        at frontier: Set<ChangeHash>
    ) throws -> Date? {
        let values = try document.getAllAt(
            obj: .ROOT, key: Self.modifiedAtKey, heads: frontier
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

    init(
        noteID: UUID = UUID(),
        text: String = "",
        metadata: NoteMetadata = .now()
    ) throws {
        let document = Document(textEncoding: .unicodeScalar)
        try document.put(
            obj: .ROOT,
            key: Self.noteIDKey,
            value: .String(noteID.uuidString)
        )
        try document.put(
            obj: .ROOT,
            key: Self.schemaVersionKey,
            value: .Uint(Self.supportedSchemaVersion)
        )
        let textObject = try document.putObject(
            obj: .ROOT,
            key: Self.textKey,
            ty: .Text
        )
        if !text.isEmpty {
            try document.spliceText(
                obj: textObject,
                start: 0,
                delete: 0,
                value: text
            )
        }
        if let createdAt = metadata.createdAt {
            guard let createdAt = createdAt.noteTimestamp else {
                throw NoteDocumentError.invalidCreatedAt
            }
            try document.put(
                obj: .ROOT,
                key: Self.createdAtKey,
                value: .Timestamp(createdAt)
            )
        }
        if let modifiedAt = metadata.modifiedAt {
            guard let modifiedAt = modifiedAt.noteTimestamp else {
                throw NoteDocumentError.invalidModifiedAt
            }
            try document.put(
                obj: .ROOT,
                key: Self.modifiedAtKey,
                value: .Timestamp(modifiedAt)
            )
        }
        document.commitWith(
            timestamp: metadata.createdAt ?? metadata.modifiedAt ?? Date()
        )

        self.document = document
        self.textObject = textObject
        self.noteID = noteID
    }

    convenience init(snapshot: NoteSnapshot) throws {
        try self.init(serializedData: snapshot.data)
        guard noteID == snapshot.noteID, heads == snapshot.heads else {
            throw NoteDocumentError.noteIdentityMismatch
        }
    }

    convenience init(serializedData: Data) throws {
        let document = try Document(serializedData)
        try self.init(validating: document)
    }

    private init(validating document: Document) throws {
        guard case .unicodeScalar = document.textEncoding else {
            throw NoteDocumentError.unexpectedTextEncoding
        }

        guard let schemaValue = try document.get(
            obj: .ROOT,
            key: Self.schemaVersionKey
        ) else {
            throw NoteDocumentError.missingSchemaVersion
        }
        guard case let .Scalar(.Uint(schemaVersion)) = schemaValue else {
            throw NoteDocumentError.invalidSchemaVersion
        }
        guard schemaVersion == Self.supportedSchemaVersion else {
            throw NoteDocumentError.unsupportedSchemaVersion
        }

        guard let noteIDValue = try document.get(
            obj: .ROOT,
            key: Self.noteIDKey
        ) else {
            throw NoteDocumentError.missingNoteID
        }
        guard case let .Scalar(.String(noteIDString)) = noteIDValue,
              let noteID = UUID(uuidString: noteIDString) else {
            throw NoteDocumentError.invalidNoteID
        }

        guard let textValue = try document.get(
            obj: .ROOT,
            key: Self.textKey
        ) else {
            throw NoteDocumentError.missingText
        }
        guard case let .Object(textObject, .Text) = textValue else {
            throw NoteDocumentError.invalidText
        }

        _ = try Self.date(
            in: document,
            forKey: Self.createdAtKey,
            invalid: .invalidCreatedAt,
            reduce: min
        )
        _ = try Self.date(
            in: document,
            forKey: Self.modifiedAtKey,
            invalid: .invalidModifiedAt,
            reduce: max
        )

        self.document = document
        self.textObject = textObject
        self.noteID = noteID
    }

    func replaceUTF16(
        range: NSRange,
        with replacement: String,
        at modificationDate: Date = Date()
    ) throws {
        let current = try text
        let scalarRange = try AutomergeTextIndex.unicodeScalarRange(
            forUTF16Range: range,
            in: current
        )
        let scalars = current.unicodeScalars
        let start = scalars.index(
            scalars.startIndex,
            offsetBy: Int(scalarRange.start)
        )
        let end = scalars.index(start, offsetBy: Int(scalarRange.length))
        let replaced = String(scalars[start ..< end])
        guard !replacement.utf8.elementsEqual(replaced.utf8) else { return }
        let modifiedAt = try nextModifiedAt(modificationDate)
        try document.spliceText(
            obj: textObject,
            start: scalarRange.start,
            delete: Int64(scalarRange.length),
            value: replacement
        )
        try setModifiedAt(modifiedAt)
        document.commitWith(timestamp: modificationDate)
    }

    func replaceAll(
        with text: String,
        at modificationDate: Date = Date(),
        changeMessage: String? = nil
    ) throws {
        guard !text.utf8.elementsEqual((try self.text).utf8) else { return }
        let modifiedAt = try nextModifiedAt(modificationDate)
        try document.updateText(obj: textObject, value: text)
        try setModifiedAt(modifiedAt)
        document.commitWith(message: changeMessage, timestamp: modificationDate)
    }

    func snapshot() -> NoteSnapshot {
        NoteSnapshot(
            data: document.save(),
            heads: heads,
            noteID: noteID
        )
    }

    func fork() throws -> NoteDocument {
        try NoteDocument(validating: document.fork())
    }

    func merge(_ other: NoteDocument) throws {
        guard noteID == other.noteID else {
            throw NoteDocumentError.noteIdentityMismatch
        }
        // ObjId's opaque bytes may contain replica-local lookup hints. Shared
        // change hashes, rather than byte equality of handles from different
        // Document instances, establish a common persisted history.
        guard !historyHeads.isDisjoint(with: other.historyHeads) else {
            throw SyncError.disconnectedHistory
        }
        try document.merge(other: other.document)
    }

    private func nextModifiedAt(_ proposed: Date) throws -> Date {
        guard let proposed = proposed.noteTimestamp else {
            throw NoteDocumentError.invalidModifiedAt
        }
        if let current = try metadata.modifiedAt {
            return max(current, proposed)
        }
        return proposed
    }

    private func setModifiedAt(_ date: Date) throws {
        try document.put(
            obj: .ROOT,
            key: Self.modifiedAtKey,
            value: .Timestamp(date)
        )
    }

    private func date(
        forKey key: String,
        invalid error: NoteDocumentError,
        reduce: (Date, Date) -> Date
    ) throws -> Date? {
        try Self.date(
            in: document,
            forKey: key,
            invalid: error,
            reduce: reduce
        )
    }

    private static func date(
        in document: Document,
        forKey key: String,
        invalid error: NoteDocumentError,
        reduce: (Date, Date) -> Date
    ) throws -> Date? {
        let values = try document.getAll(obj: .ROOT, key: key)
        guard !values.isEmpty else { return nil }
        var dates: [Date] = []
        for value in values {
            guard case let .Scalar(.Timestamp(date)) = value,
                  let normalized = date.noteTimestamp else {
                throw error
            }
            dates.append(normalized)
        }
        return dates.dropFirst().reduce(dates[0], reduce)
    }
}
