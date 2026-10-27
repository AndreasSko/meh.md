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
    /// A longer pause between two changes starts a new edit session.
    private static let sessionMaximumGap: TimeInterval = 3 * 60
    /// Inside a session, a longer pause ends a step of its details.
    private static let stepMaximumGap: TimeInterval = 5

    private let document: Document
    private let textObject: ObjId
    private var historyCache: (heads: Set<String>, builder: HistoryBuilder)?

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

    var historyHashes: Set<ChangeHash> {
        Set(document.getHistory())
    }

    var historyCount: Int {
        document.getHistory().count
    }

    /// Edit sessions in causal order; `detailed` also loads the steps
    /// inside them. Readers load details only where History looks.
    func historyVersions(detailed: Bool = false) throws -> [NoteHistoryVersion] {
        let builder: HistoryBuilder
        if let historyCache, historyCache.heads == heads {
            builder = historyCache.builder
        } else {
            builder = try makeHistoryBuilder()
            installHistoryIndex(builder)
        }
        do {
            while !builder.isComplete {
                try builder.advance(batchSize: 128)
            }
            if detailed {
                for session in 0 ..< builder.sessionCount {
                    while try !builder.advanceDetails(ofSession: session, batchSize: 16) {}
                }
            }
        } catch {
            // A failed builder may have skipped part of the history.
            historyCache = nil
            throw error
        }
        return builder.versions
    }

    func makeHistoryBuilder() throws -> HistoryBuilder {
        try HistoryBuilder(source: self)
    }

    func installHistoryIndex(_ builder: HistoryBuilder) {
        historyCache = (heads, builder)
    }

    /// Indexing in two passes keeps long notes fast. Comparing two states
    /// costs about as much as the whole note, so the first pass compares
    /// only once per edit session. It groups changes from their recorded
    /// author, time and message alone. The second pass compares once per
    /// step, the typing between two short pauses, of one session when a
    /// reader asks for its details.
    ///
    /// Only the last session is unresolved: a later session with text
    /// changes proves it historical. Published stops keep their identity
    /// when details load.
    final class HistoryBuilder {
        private struct Session {
            var changes: Range<Int>
            let start: Set<ChangeHash>
            var end: Set<ChangeHash>
            let date: Date?
            let addedCharacters: Int
            let removedCharacters: Int
            var stop: NoteHistoryVersion?
            /// The states before the last one, once loaded.
            var states: [NoteHistoryVersion]?
            /// The last state as the details pass saw it.
            var last: State?
            var detail: DetailProgress?
        }

        private struct State {
            var frontier: Set<ChangeHash>
            let date: Date?
            let addedCharacters: Int
            let removedCharacters: Int
        }

        private struct DetailProgress {
            var changes: [IndexedChange]
            /// Where each step ends, as positions in `changes`.
            var ends: [Int]
            var step = 0
            var position = 0
            var frontier: Set<ChangeHash>
            var previousModifiedAt: Date?
            var pending: State?
            var states: [NoteHistoryVersion] = []
        }

        private struct IndexedChange {
            let index: Int
            let change: Change
        }

        private struct OpenSession {
            var changes: Range<Int>
            let start: Set<ChangeHash>
            var beforeLast: Set<ChangeHash>
            var last: Change
        }

        // The document caches its builder, so the builder must not own it.
        private unowned let source: NoteDocument
        private let history: [ChangeHash]
        private let bodyObject: ObjId
        private var position = 0
        private var frontier = Set<ChangeHash>()
        private var open: OpenSession?
        private var previous: IndexedChange?
        /// Change times that cost a read; see `time(of:)`.
        private var readTimes: [Int: Date?] = [:]
        private var sessions: [Session] = []
        private var sessionOfVersion: [String: Int] = [:]
        private var cachedVersions: [NoteHistoryVersion]?
        private(set) var frontiers: [String: Set<ChangeHash>] = [:]
        /// Counts changes to `versions`, so readers publish only news.
        private(set) var revision = 0
        private(set) var processedChangeCount = 0
        private(set) var detailChangeCount = 0
        var timeReadCount: Int { readTimes.count }

        var isComplete: Bool { position == history.count && open == nil }
        var sessionCount: Int { sessions.count }

        var versions: [NoteHistoryVersion] {
            if let cachedVersions { return cachedVersions }
            var versions: [NoteHistoryVersion] = []
            for session in sessions {
                versions += session.states ?? []
                if let stop = session.stop { versions.append(stop) }
            }
            cachedVersions = versions
            return versions
        }

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

        /// The session a version belongs to; `nil` means the current text,
        /// which ends the last session.
        func session(containing id: String?) -> Int? {
            guard let id else { return sessions.indices.last }
            return sessionOfVersion[id]
        }

        func hasDetails(ofSession index: Int) -> Bool {
            sessions[index].states != nil
        }

        /// Reads the next changes' metadata. Comparing text happens only
        /// when a session ends.
        func advance(batchSize: Int) throws {
            // A batch runs whole, so cancelling never skips changes.
            try Task.checkCancellation()
            let end = position + min(
                max(1, batchSize), history.count - position
            )
            var changes = previous.map { [$0] } ?? []
            while position < end {
                if let change = source.document.change(hash: history[position]) {
                    changes.append(IndexedChange(index: position, change: change))
                }
                position += 1
            }
            let pauses = try pauses(
                in: changes, longerThan: NoteDocument.sessionMaximumGap
            )
            for next in changes.dropFirst(previous == nil ? 0 : 1) {
                processedChangeCount += 1
                if open != nil, let previous, pauses.contains(previous.index) {
                    try closeSession()
                }
                let before = frontier
                frontier.subtract(next.change.deps)
                frontier.insert(next.change.hash)
                if var session = open {
                    session.changes = session.changes.lowerBound ..< next.index + 1
                    session.beforeLast = before
                    session.last = next.change
                    open = session
                } else {
                    open = OpenSession(
                        changes: next.index ..< next.index + 1,
                        start: before, beforeLast: before, last: next.change
                    )
                }
                previous = next
            }
            if position == history.count { try closeSession() }
        }

        /// The changes after which a longer pause follows, or another
        /// device, a restore or an unknown time. Old app versions recorded
        /// no change times, which then cost a read each. The note's
        /// modified date only grows, so a run of them whose ends lie close
        /// enough holds no pause and needs no reads in between.
        private func pauses(
            in changes: [IndexedChange], longerThan maximumGap: TimeInterval
        ) throws -> Set<Int> {
            var pauses = Set<Int>()
            func fits(_ earlier: Date?, _ later: Date?) -> Bool {
                guard let earlier, let later else { return false }
                let gap = later.timeIntervalSince(earlier)
                return gap >= 0 && gap <= maximumGap
            }
            func search(_ low: Int, _ high: Int) throws {
                let earlier = try time(of: changes[low])
                let later = try time(of: changes[high])
                if high == low + 1 {
                    if !fits(earlier, later) { pauses.insert(changes[low].index) }
                } else if !fits(earlier, later) {
                    let middle = (low + high) / 2
                    try search(low, middle)
                    try search(middle, high)
                }
            }
            var low = 0
            while low + 1 < changes.count {
                // Each run between hard breaks needs its times compared.
                var high = low + 1
                while high < changes.count,
                      Self.mayContinue(changes[high - 1].change, with: changes[high].change) {
                    high += 1
                }
                if high - 1 > low {
                    if changes[low ..< high].allSatisfy(\.change.hasTimestamp) {
                        for index in low ..< high - 1
                        where !fits(changes[index].change.timestamp,
                                    changes[index + 1].change.timestamp) {
                            pauses.insert(changes[index].index)
                        }
                    } else {
                        try search(low, high - 1)
                    }
                }
                if high < changes.count { pauses.insert(changes[high - 1].index) }
                low = high
            }
            return pauses
        }

        private static func mayContinue(_ previous: Change, with next: Change) -> Bool {
            previous.actorId == next.actorId
                && previous.message != NoteDocument.restoreChangeMessage
                && next.message != NoteDocument.restoreChangeMessage
        }

        private func time(of change: IndexedChange) throws -> Date? {
            if change.change.hasTimestamp { return change.change.timestamp }
            if let time = readTimes[change.index] { return time }
            let time = try source.historyModifiedAt(at: [change.change.hash])
            readTimes[change.index] = time
            return time
        }

        private func closeSession() throws {
            guard let open else { return }
            let patches = bodyPatches(from: open.start, to: frontier)
            guard !patches.isEmpty else {
                self.open = nil
                // Without text changes, these changes extend the previous
                // text state, like metadata writes do.
                if let last = sessions.indices.last {
                    sessions[last].changes =
                        sessions[last].changes.lowerBound ..< open.changes.upperBound
                    sessions[last].end = frontier
                    sessions[last].states = nil
                    sessions[last].last = nil
                    sessions[last].detail = nil
                    changed()
                }
                return
            }
            let size = NoteDocument.editSize(of: patches)
            let date = try source.historyDate(
                of: open.last,
                modifiedAt: source.historyModifiedAt(at: frontier),
                previousModifiedAt: source.historyModifiedAt(at: open.beforeLast)
            )
            self.open = nil
            if let last = sessions.indices.last { publish(last) }
            sessions.append(Session(
                changes: open.changes, start: open.start, end: frontier,
                date: date, addedCharacters: size.added,
                removedCharacters: size.removed
            ))
            changed()
        }

        /// Compares the next steps of one session, until about
        /// `batchSize` changes. Returns whether its details are complete.
        func advanceDetails(ofSession index: Int, batchSize: Int) throws -> Bool {
            let session = sessions[index]
            guard session.states == nil else { return true }
            var progress: DetailProgress
            if let detail = session.detail {
                progress = detail
            } else {
                var changes: [IndexedChange] = []
                for position in session.changes {
                    try Task.checkCancellation()
                    if let change = source.document.change(hash: history[position]) {
                        changes.append(IndexedChange(index: position, change: change))
                    }
                }
                let pauses = try pauses(
                    in: changes, longerThan: NoteDocument.stepMaximumGap
                )
                progress = try DetailProgress(
                    changes: changes,
                    ends: changes.indices.filter {
                        $0 == changes.count - 1 || pauses.contains(changes[$0].index)
                    },
                    frontier: session.start,
                    previousModifiedAt: source.historyModifiedAt(at: session.start)
                )
            }
            try Task.checkCancellation()
            var compared = 0
            while progress.step < progress.ends.count, compared < max(1, batchSize) {
                let end = progress.ends[progress.step]
                let before = progress.frontier
                let last = progress.changes[end].change
                for next in progress.changes[progress.position ... end] {
                    progress.frontier.subtract(next.change.deps)
                    progress.frontier.insert(next.change.hash)
                }
                compared += end + 1 - progress.position
                detailChangeCount += end + 1 - progress.position
                progress.position = end + 1
                progress.step += 1
                let patches = bodyPatches(from: before, to: progress.frontier)
                let modifiedAt = try source.historyModifiedAt(at: progress.frontier)
                if !patches.isEmpty {
                    let size = NoteDocument.editSize(of: patches)
                    if let pending = progress.pending {
                        let state = version(of: pending, isOverviewStop: false)
                        progress.states.append(state)
                        frontiers[state.id] = pending.frontier
                        sessionOfVersion[state.id] = index
                    }
                    progress.pending = State(
                        frontier: progress.frontier,
                        date: source.historyDate(
                            of: last, modifiedAt: modifiedAt,
                            previousModifiedAt: progress.previousModifiedAt
                        ),
                        addedCharacters: size.added,
                        removedCharacters: size.removed
                    )
                } else {
                    progress.pending?.frontier = progress.frontier
                }
                progress.previousModifiedAt = modifiedAt
            }
            guard progress.step == progress.ends.count else {
                sessions[index].detail = progress
                return false
            }
            sessions[index].detail = nil
            sessions[index].states = progress.states
            sessions[index].last = progress.pending
            if session.stop != nil { publish(index) }
            changed()
            return true
        }

        private func publish(_ index: Int) {
            let session = sessions[index]
            let stop = NoteHistoryVersion(
                id: Self.id(of: session.end),
                date: session.last.map(\.date) ?? session.date,
                isOverviewStop: true,
                addedCharacters: session.last?.addedCharacters
                    ?? session.addedCharacters,
                removedCharacters: session.last?.removedCharacters
                    ?? session.removedCharacters,
                sessionAddedCharacters: session.addedCharacters,
                sessionRemovedCharacters: session.removedCharacters
            )
            sessions[index].stop = stop
            frontiers[stop.id] = session.end
            sessionOfVersion[stop.id] = index
        }

        private func version(
            of state: State, isOverviewStop: Bool
        ) -> NoteHistoryVersion {
            NoteHistoryVersion(
                id: Self.id(of: state.frontier),
                date: state.date,
                isOverviewStop: isOverviewStop,
                addedCharacters: state.addedCharacters,
                removedCharacters: state.removedCharacters
            )
        }

        private func changed() {
            cachedVersions = nil
            revision += 1
        }

        private func bodyPatches(
            from before: Set<ChangeHash>, to after: Set<ChangeHash>
        ) -> [Patch] {
            source.document.difference(from: before, to: after).filter {
                source.patchChangesBody($0, bodyObject: bodyObject)
            }
        }

        private static func id(of frontier: Set<ChangeHash>) -> String {
            frontier.map(\.debugDescription).sorted().joined(separator: ",")
        }
    }

    /// The content date when it advanced with this change, otherwise the
    /// time Automerge recorded for it.
    private func historyDate(
        of change: Change, modifiedAt: Date?, previousModifiedAt: Date?
    ) -> Date? {
        if modifiedAt != previousModifiedAt, let modifiedAt {
            return modifiedAt
        }
        return change.hasTimestamp ? change.timestamp : nil
    }

    /// The body patches already describe each change, so sizing them costs
    /// no further history reads.
    private static func editSize(
        of patches: [Patch]
    ) -> (added: Int, removed: Int) {
        var added = 0
        var removed = 0
        for patch in patches {
            switch patch.action {
            case let .SpliceText(_, _, value, _):
                added += value.unicodeScalars.count
            case let .DeleteSeq(deletion):
                removed += Int(deletion.length)
            default:
                break
            }
        }
        return (added, removed)
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

    func historicalText(for version: NoteHistoryVersion) throws -> String {
        let frontier: Set<ChangeHash>
        if let cached = historyCache?.builder.frontiers[version.id] {
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
        metadata: NoteMetadata = .now(),
        actor: ActorId? = nil
    ) throws {
        let document = Document(textEncoding: .unicodeScalar)
        if let actor { document.actor = actor }
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

private extension Change {
    /// Old app versions committed without a time.
    var hasTimestamp: Bool { timestamp.timeIntervalSince1970 != 0 }
}
