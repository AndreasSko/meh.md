import Foundation

/// A complete prefix of historical versions. The unresolved current text
/// state is excluded until a later body edit proves it historical.
public struct NoteHistoryIndexUpdate: Equatable, Sendable {
    public let versions: [NoteHistoryVersion]
    public let isComplete: Bool
}

/// Owns one frozen document for indexing and historical previews. No live
/// session or stored note is modified.
public actor NoteHistoryReader {
    private var snapshot: NoteSnapshot?
    private var source: NoteDocument?
    private var builder: NoteDocument.HistoryBuilder?
    private var complete = false
    private var producer: Task<Void, Never>?
    private var subscribers: [
        UUID: AsyncThrowingStream<NoteHistoryIndexUpdate, Error>.Continuation
    ] = [:]
    private var latest = NoteHistoryIndexUpdate(
        versions: [], isComplete: false
    )
    private var previewCache: [String: String] = [:]
    private var previewOrder: [String] = []
    private let previewCapacity = 3
    private let previewByteLimit = 4 * 1024 * 1024
    private var previewBytes = 0

    // Deterministic diagnostics distinguish indexing from preview work.
    private(set) var loadCount = 0
    private(set) var historyScanCount = 0
    private(set) var processedChangeCount = 0
    private(set) var previewReadCount = 0
    var cachedPreviewCount: Int { previewCache.count }
    var cachedPreviewBytes: Int { previewBytes }
    var isIndexComplete: Bool { complete }
    var hasActiveIndexBuilder: Bool { builder != nil }

    public init(snapshot: NoteSnapshot) {
        self.snapshot = snapshot
    }

    /// All subscribers share one producer. Dropping the last subscriber
    /// pauses indexing; a new subscriber resumes the retained prefix.
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
        if complete {
            continuation.finish()
            return stream
        }
        subscribers[id] = continuation
        if producer == nil {
            producer = Task { [weak self] in
                await self?.produce(batchSize: max(1, batchSize))
            }
        }
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
        let text = try document.indexedHistoricalText(for: version)
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

    private func produce(batchSize: Int) async {
        do {
            try Task.checkCancellation()
            let document = try frozenDocument()
            if builder == nil {
                builder = try document.makeHistoryBuilder()
                historyScanCount += 1
            }
            while let builder {
                try Task.checkCancellation()
                let before = builder.processedChangeCount
                do {
                    defer {
                        processedChangeCount +=
                            builder.processedChangeCount - before
                    }
                    try builder.advance(batchSize: batchSize)
                }
                document.installHistoryIndex(builder)
                complete = builder.isComplete
                latest = NoteHistoryIndexUpdate(
                    versions: builder.versions, isComplete: complete
                )
                for continuation in subscribers.values {
                    continuation.yield(latest)
                }
                if complete {
                    self.builder = nil
                    for continuation in subscribers.values {
                        continuation.finish()
                    }
                    subscribers.removeAll()
                    producer = nil
                    return
                }
                // Allow selection previews and cancellation to interleave.
                await Task.yield()
            }
        } catch is CancellationError {
            // The partial builder remains valid for a subsequent subscriber.
        } catch {
            for continuation in subscribers.values {
                continuation.finish(throwing: error)
            }
            subscribers.removeAll()
            // An invalid document should fail again rather than publish an
            // index that omitted a partially applied change.
            builder = nil
        }
        producer = nil
        // A subscriber may arrive while the old producer handles cancellation.
        if !subscribers.isEmpty {
            producer = Task { [weak self] in
                await self?.produce(batchSize: batchSize)
            }
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
        if subscribers.isEmpty {
            producer?.cancel()
        }
    }
}
