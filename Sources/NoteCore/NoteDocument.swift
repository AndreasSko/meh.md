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
        isComplete: Bool,
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

    /// Past text states in causal order. The chunkable builder publishes
    /// finalized versions without blocking callers on the complete index.
    func historyVersions() throws -> [NoteHistoryVersion] {
        if let historyCache, historyCache.heads == heads,
           historyCache.isComplete {
            return historyCache.versions
        }
        let builder = try makeHistoryBuilder()
        while !builder.isComplete {
            try builder.advance(batchSize: 128)
        }
        installHistoryIndex(builder)
        return builder.versions
    }

    func makeHistoryBuilder() throws -> HistoryBuilder {
        try HistoryBuilder(source: self)
    }

    func installHistoryIndex(_ builder: HistoryBuilder) {
        historyCache = (
            heads, builder.versions, builder.isComplete, builder.frontiers
        )
    }

    /// Only the unresolved last text state is mutable. A subsequent body
    /// change proves the previous state historical and fixes its typing-run
    /// boundary, so published prefix versions never change identity.
    final class HistoryBuilder {
        private struct Candidate {
            var frontier: Set<ChangeHash>
            var date: Date?
            let actor: ActorId
            let isTypingEdit: Bool
            let startsNewRun: Bool
            let isRestore: Bool
        }

        private let source: NoteDocument
        private let history: [ChangeHash]
        private let bodyObject: ObjId
        private var position = 0
        private var frontier = Set<ChangeHash>()
        private var pending: Candidate?
        private var candidateCount = 0
        private var previousModifiedAt: Date?
        private(set) var versions: [NoteHistoryVersion] = []
        private(set) var frontiers: [String: Set<ChangeHash>] = [:]

        var isComplete: Bool { position == history.count }
        var processedChangeCount: Int { position }

        init(source: NoteDocument) throws {
            self.source = source
            history = source.document.getHistory()
            // ObjId bytes include a document-local actor-index hint. A merge
            // can change that hint, so resolve the body in this document
            // rather than compare patches to a pre-merge identifier.
            guard case let .Object(object, .Text)? = try source.document.get(
                obj: .ROOT, key: NoteDocument.textKey
            ) else { throw NoteDocumentError.invalidText }
            bodyObject = object
        }

        func advance(batchSize: Int) throws {
            let end = position + min(
                max(1, batchSize), history.count - position
            )
            while position < end {
                try Task.checkCancellation()
                let hash = history[position]
                position += 1
                guard let change = source.document.change(hash: hash) else {
                    continue
                }
                let previousFrontier = frontier
                frontier.subtract(change.deps)
                frontier.insert(hash)
                let bodyPatches = source.document.difference(
                    from: previousFrontier, to: frontier
                ).filter {
                    source.patchChangesBody(
                        $0, bodyObject: bodyObject
                    )
                }
                let textChanged = !bodyPatches.isEmpty
                let modifiedAt = try source.historyModifiedAt(at: frontier)

                if textChanged {
                    let date: Date?
                    if modifiedAt != previousModifiedAt, let modifiedAt {
                        date = modifiedAt
                    } else if change.timestamp.timeIntervalSince1970 != 0 {
                        date = change.timestamp
                    } else {
                        date = nil
                    }
                    let next = Candidate(
                        frontier: frontier,
                        date: date,
                        actor: change.actorId,
                        isTypingEdit: bodyPatches.count <= 2
                            && bodyPatches.allSatisfy(
                                source.isSingleCharacterEdit
                            ),
                        startsNewRun: bodyPatches.contains { patch in
                            if case let .SpliceText(_, _, value, _) =
                                patch.action {
                                return value == "\n"
                            }
                            return false
                        },
                        isRestore: change.message ==
                            NoteDocument.restoreChangeMessage
                    )
                    if let previous = pending {
                        publish(previous, followedBy: next)
                    }
                    pending = next
                    candidateCount += 1
                } else if pending != nil {
                    pending?.frontier = frontier
                }
                previousModifiedAt = modifiedAt
            }
        }

        private func publish(
            _ previous: Candidate, followedBy next: Candidate
        ) {
            let sameRun: Bool
            if candidateCount > 1,
               previous.isTypingEdit, next.isTypingEdit,
               !next.startsNewRun,
               !previous.isRestore, !next.isRestore,
               previous.actor == next.actor,
               let earlier = previous.date, let later = next.date {
                let gap = later.timeIntervalSince(earlier)
                sameRun = gap >= 0 && gap <=
                    NoteDocument.typingRunMaximumGap
            } else {
                sameRun = false
            }
            let id = previous.frontier.map(\.debugDescription)
                .sorted().joined(separator: ",")
            versions.append(NoteHistoryVersion(
                id: id,
                ordinal: versions.count + 1,
                date: previous.date,
                isOverviewStop: !sameRun
            ))
            frontiers[id] = previous.frontier
        }
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

    private func patchChangesBody(
        _ patch: Patch, bodyObject: ObjId?
    ) -> Bool {
        guard let textObject = bodyObject else { return false }
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

    /// Frozen readers only preview published frontiers, never rescan history.
    func indexedHistoricalText(
        for version: NoteHistoryVersion
    ) throws -> String {
        guard let frontier = historyCache?.frontiers[version.id] else {
            throw NoteHistoryError.versionUnavailable
        }
        return try document.textAt(obj: textObject, heads: frontier)
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
        try restoreHistoricalText(
            historicalText(for: version), at: modificationDate
        )
    }

    func restoreHistoricalText(
        _ restoredText: String,
        at modificationDate: Date = Date()
    ) throws {
        guard !restoredText.utf8.elementsEqual((try text).utf8) else { return }
        // Commit the restore as one marked change so it remains a boundary
        // even when only one character differs.
        try replaceAll(
            with: restoredText,
            at: modificationDate,
            changeMessage: Self.restoreChangeMessage
        )
    }

    private func historyModifiedAt(
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

    /// Only the session's matching-revision path calls this, after validating
    /// the scalar range and complete resulting text against its cached source.
    func applyValidatedEditorChange(
        _ replacement: String,
        scalarRange: (start: UInt64, length: UInt64),
        at modificationDate: Date = Date()
    ) throws {
        let modifiedAt = try nextModifiedAt(modificationDate)
        try document.spliceText(
            obj: textObject, start: scalarRange.start,
            delete: Int64(scalarRange.length), value: replacement
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
