import Foundation

/// The index so far. Edit sessions arrive as a complete prefix; `isComplete`
/// means every session is known. Loaded details add states inside sessions,
/// so a later update can insert versions before published ones. `revision`
/// orders updates from different streams.
public struct NoteHistoryIndexUpdate: Equatable, Sendable {
    public let versions: [NoteHistoryVersion]
    public let isComplete: Bool
    public let revision: Int
}

/// Owns one frozen document for indexing and historical previews. No live
/// session or stored note is modified.
public actor NoteHistoryReader {
    /// Sessions on each side of the focus whose details load with it.
    static let detailRadius = 4

    private var snapshot: NoteSnapshot?
    private var source: NoteDocument?
    private var builder: NoteDocument.HistoryBuilder?
    /// Keeps revisions increasing when a failed builder is replaced.
    private var revisionBase = 0
    private var producer: Task<Void, Never>?
    private var subscribers: [
        UUID: AsyncThrowingStream<NoteHistoryIndexUpdate, Error>.Continuation
    ] = [:]
    private var focus: (
        id: UUID, version: String?,
        continuation: AsyncThrowingStream<NoteHistoryIndexUpdate, Error>.Continuation
    )?
    private var latest = NoteHistoryIndexUpdate(
        versions: [], isComplete: false, revision: 0
    )
    private var previewCache: [String: String] = [:]
    private var previewOrder: [String] = []
    private let previewCapacity = 3
    private let previewByteLimit = 4 * 1024 * 1024
    private var previewBytes = 0
    private var lastChanges: (key: String, changes: NoteHistoryChanges)?

    // Deterministic diagnostics distinguish indexing from preview work.
    private(set) var loadCount = 0
    private(set) var historyScanCount = 0
    private(set) var previewReadCount = 0
    var processedChangeCount: Int { builder?.processedChangeCount ?? 0 }
    var detailChangeCount: Int { builder?.detailChangeCount ?? 0 }
    var cachedPreviewCount: Int { previewCache.count }
    var cachedPreviewBytes: Int { previewBytes }
    var isIndexComplete: Bool { latest.isComplete }
    var isIndexing: Bool { producer != nil }

    public init(snapshot: NoteSnapshot) {
        self.snapshot = snapshot
    }

    /// Edit sessions as they are indexed; the stream ends once all are
    /// known. All streams share one producer. Dropping the last one pauses
    /// indexing; a new one resumes the retained progress.
    public func updates(
        batchSize: Int = 32
    ) -> AsyncThrowingStream<NoteHistoryIndexUpdate, Error> {
        let id = UUID()
        let (stream, continuation) = AsyncThrowingStream<
            NoteHistoryIndexUpdate, Error
        >.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        continuation.yield(latest)
        if latest.isComplete {
            continuation.finish()
            return stream
        }
        subscribers[id] = continuation
        startProducer(batchSize: batchSize)
        return stream
    }

    /// Loads the single states of the session holding `version`, then of
    /// the sessions around it; `nil` means the current text. The stream
    /// ends when they are loaded. A newer call moves the focus and ends the
    /// previous stream.
    public func details(
        near version: NoteHistoryVersion?, batchSize: Int = 32
    ) -> AsyncThrowingStream<NoteHistoryIndexUpdate, Error> {
        let id = UUID()
        let (stream, continuation) = AsyncThrowingStream<
            NoteHistoryIndexUpdate, Error
        >.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeFocus(id) }
        }
        focus?.continuation.finish()
        focus = (id, version?.id, continuation)
        continuation.yield(latest)
        startProducer(batchSize: batchSize)
        return stream
    }

    /// Historical text is decoded only on selection and retained within a
    /// small count and byte bound. An oversized selection is returned directly.
    public func historicalText(
        for version: NoteHistoryVersion
    ) throws -> String {
        try Task.checkCancellation()
        if let cached = previewCache[version.id] {
            touchPreview(version.id)
            return cached
        }
        let document = try frozenDocument()
        let text = try document.historicalText(for: version)
        try Task.checkCancellation()
        previewReadCount += 1
        let bytes = text.utf8.count
        if bytes <= previewByteLimit {
            while previewCache.count >= previewCapacity
                || previewBytes + bytes > previewByteLimit {
                guard let oldest = previewOrder.first else { break }
                previewOrder.removeFirst()
                if let removed = previewCache.removeValue(forKey: oldest) {
                    previewBytes -= removed.utf8.count
                }
            }
            previewCache[version.id] = text
            previewBytes += bytes
            touchPreview(version.id)
        }
        return text
    }

    /// Compares a version with an earlier one, or with an empty note when
    /// there is none. The preview cache already holds the selected text, so
    /// this usually decodes only the earlier version.
    public func changes(
        for version: NoteHistoryVersion,
        since base: NoteHistoryVersion?
    ) throws -> NoteHistoryChanges {
        let key = (base?.id ?? "") + "|" + version.id
        if let lastChanges, lastChanges.key == key { return lastChanges.changes }
        let text = try historicalText(for: version)
        let baseText = try base.map { try historicalText(for: $0) } ?? ""
        try Task.checkCancellation()
        let changes = NoteHistoryChanges(from: baseText, to: text)
        lastChanges = (key, changes)
        return changes
    }

    private func touchPreview(_ id: String) {
        previewOrder.removeAll { $0 == id }
        previewOrder.append(id)
    }

    private func frozenDocument() throws -> NoteDocument {
        if let source { return source }
        guard let snapshot else { throw NoteHistoryError.versionUnavailable }
        let document = try NoteDocument(snapshot: snapshot)
        source = document
        self.snapshot = nil
        loadCount += 1
        return document
    }

    private func startProducer(batchSize: Int) {
        guard producer == nil else { return }
        producer = Task { [weak self] in
            await self?.produce(batchSize: max(1, batchSize))
        }
    }

    private enum Work {
        case details(Int)
        case sessions
    }

    /// The focused session comes first, so a selection's details do not
    /// wait for the rest of the index. Its neighbors follow the sessions.
    private func nextWork(_ builder: NoteDocument.HistoryBuilder) -> Work? {
        // The overview first: it is cheap and lets History scroll freely.
        if !builder.isComplete {
            return !subscribers.isEmpty || focus != nil ? .sessions : nil
        }
        guard let focus, let center = builder.session(containing: focus.version)
        else { return nil }
        if !builder.hasDetails(ofSession: center) {
            return .details(center)
        }
        for distance in 1 ... Self.detailRadius {
            for index in [center - distance, center + distance]
            where index >= 0 && index < builder.sessionCount
                && !builder.hasDetails(ofSession: index) {
                return .details(index)
            }
        }
        return nil
    }

    private func produce(batchSize: Int) async {
        do {
            try Task.checkCancellation()
            let document = try frozenDocument()
            if builder == nil {
                let builder = try document.makeHistoryBuilder()
                document.installHistoryIndex(builder)
                self.builder = builder
                revisionBase = latest.revision
                historyScanCount += 1
            }
            while let builder, let work = nextWork(builder) {
                try Task.checkCancellation()
                switch work {
                case let .details(index):
                    _ = try builder.advanceDetails(
                        ofSession: index, batchSize: batchSize
                    )
                case .sessions:
                    try builder.advance(batchSize: batchSize)
                }
                let revision = revisionBase + builder.revision
                if revision != latest.revision
                    || builder.isComplete != latest.isComplete {
                    latest = NoteHistoryIndexUpdate(
                        versions: builder.versions,
                        isComplete: builder.isComplete,
                        revision: revision
                    )
                    for continuation in subscribers.values {
                        continuation.yield(latest)
                    }
                    focus?.continuation.yield(latest)
                }
                if latest.isComplete, !subscribers.isEmpty {
                    for continuation in subscribers.values {
                        continuation.finish()
                    }
                    subscribers.removeAll()
                }
                // Allow selection previews and cancellation to interleave.
                await Task.yield()
            }
            focus?.continuation.finish()
            focus = nil
        } catch is CancellationError {
            // The partial builder remains valid for a subsequent subscriber.
        } catch {
            for continuation in subscribers.values {
                continuation.finish(throwing: error)
            }
            subscribers.removeAll()
            focus?.continuation.finish(throwing: error)
            focus = nil
            // An invalid document should fail again rather than publish an
            // index that omitted a partially applied change.
            builder = nil
        }
        producer = nil
        // A subscriber may arrive while the old producer handles cancellation.
        if !subscribers.isEmpty || focus != nil {
            startProducer(batchSize: batchSize)
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
        pauseIfUnobserved()
    }

    private func removeFocus(_ id: UUID) {
        guard focus?.id == id else { return }
        focus = nil
        pauseIfUnobserved()
    }

    private func pauseIfUnobserved() {
        if subscribers.isEmpty, focus == nil {
            producer?.cancel()
        }
    }
}
