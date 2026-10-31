import CryptoKit
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Notebook sync through any S3-compatible bucket, such as AWS S3 or MinIO.
///
/// Everything lives under `<prefix>/meh-notebook/`:
///
/// - `seed.json` is the canonical catalog, created with `If-None-Match: *` so
///   every device agrees on one notebook.
/// - `format.json` holds the minimum app format, for "Update required".
/// - `records/<document>/<record>.json` are immutable snapshots, named by
///   their content hash.
/// - `log/<device>/<sequence>.json` lists the records one device stored in
///   one batch. Each device writes its log strictly in order, so a cursor
///   that remembers the last entry read per device never skips a record.
/// - `purged/<note>` marks a permanently deleted note. Its bodies are
///   removed and never delivered or stored again.
///
/// There is no push: the app checks for changes on its own schedule.
public actor S3SyncTransport: SyncTransport {
    public nonisolated let scope: String

    private let client: S3Client
    private let root: String
    private let stateURL: URL
    private let pageSize: Int
    private var device: DeviceState?
    private var seed: SyncRecord?
    private var purged = Set<UUID>()
    private var publishedIDs = Set<String>()
    /// Records already counted for cleanup status, so replays don't inflate it.
    private var countedIDs = Set<String>()
    private var formatChecked = false
    private var isWriting = false
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []
    private var cleanupProgress: (@Sendable (SyncCleanupProgress) async -> Void)?
    private var diagnostics: (@Sendable (String, [String: Int]) async -> Void)?

    public init(
        configuration: S3SyncConfiguration,
        credentials: S3Credentials,
        stateDirectory: URL,
        session: URLSession = .shared,
        timeout: TimeInterval = 30,
        pageSize: Int = 200
    ) {
        scope = configuration.scope
        client = S3Client(
            configuration: configuration, credentials: credentials,
            session: session, timeout: timeout
        )
        let prefix = configuration.normalizedPrefix
        root = (prefix.isEmpty ? "" : prefix + "/") + "meh-notebook/"
        stateURL = stateDirectory.appending(path: "s3-device.json")
        self.pageSize = max(1, pageSize)
    }

    // MARK: - SyncTransport

    public func beginExchange() async throws {
        formatChecked = false
        try await checkFormat()
    }

    public func endExchange() async {
        formatChecked = false
    }

    public func bootstrap(proposing record: SyncRecord) async throws -> SyncRecord {
        try Self.validate(record)
        guard record.kind == .catalog else { throw SyncError.invalidRecord }
        try await checkFormat()
        if let seed = try await loadSeed() {
            // A device that stored the seed may have failed before the
            // format record; writing it is conditional and safe to repeat.
            try await writeFormatIfMissing()
            return seed
        }
        let body = try JSONEncoder().encode(record)
        for attempt in 0..<3 {
            do {
                if try await client.put(seedKey, body, ifNoneMatch: true)
                    == .conditionUnsupported, try await loadSeed() == nil {
                    // Without conditional writes two devices that set up at
                    // the same moment could both write. The read below
                    // returns whichever seed was stored last.
                    _ = try await client.put(seedKey, body)
                }
                break
            } catch S3SyncTransportError.requestFailed(409, _) where attempt < 2 {
                // A concurrent conditional write is in progress; retry.
                try await Task.sleep(for: .milliseconds(200 * (attempt + 1)))
            }
        }
        try await writeFormatIfMissing()
        guard let seed = try await loadSeed() else {
            throw SyncError.unavailable("The S3 storage did not keep the notebook.")
        }
        return seed
    }

    public func publish(_ record: SyncRecord) async throws {
        let result = try await publishBatch([record])
        if let error = result.error { throw error }
    }

    public func publishBatch(_ records: [SyncRecord]) async throws -> SyncBatchResult {
        for record in records { try Self.validate(record) }
        try await checkFormat()
        let notebookID = try await requireNotebookID()
        guard records.allSatisfy({ $0.notebookID == notebookID }) else {
            throw SyncError.invalidRecord
        }
        await acquireWriteLock()
        defer { releaseWriteLock() }

        var acknowledged = Set<String>()
        var pending: [SyncRecord] = []
        for record in records {
            // Stored earlier in this session, or a body nobody may receive.
            if publishedIDs.contains(record.id)
                || (record.kind == .note && purged.contains(record.snapshot.noteID)) {
                acknowledged.insert(record.id)
            } else if !pending.contains(where: { $0.id == record.id }) {
                pending.append(record)
            }
        }
        guard !pending.isEmpty else {
            return SyncBatchResult(acknowledgedIDs: acknowledged, error: nil)
        }
        let client = client
        let keys = pending.map(recordKey)
        let outcomes = await concurrentMap(Array(zip(pending, keys))) { record, key in
            do {
                let body = try JSONEncoder().encode(record)
                _ = try await client.put(key, body)
                return Result<(SyncRecord, Int), any Error>.success((record, body.count))
            } catch {
                return .failure(error)
            }
        }
        let storedWithSizes = outcomes.compactMap { try? $0.get() }
        let stored = storedWithSizes.map(\.0)
        var failure = outcomes.lazy.compactMap { outcome -> (any Error)? in
            if case .failure(let error) = outcome { return error }
            return nil
        }.first
        if !stored.isEmpty {
            do {
                let manifest = Manifest(records: stored.map {
                    Manifest.Entry(id: $0.id, document: $0.snapshot.noteID, kind: $0.kind)
                })
                try await writeLog(try JSONEncoder().encode(manifest))
                publishedIDs.formUnion(stored.map(\.id))
                acknowledged.formUnion(stored.map(\.id))
                for (record, size) in storedWithSizes { noteSnapshotSeen(record, bytes: size) }
                try saveDevice()
            } catch {
                failure = failure ?? error
            }
        }
        return SyncBatchResult(acknowledgedIDs: acknowledged, error: failure)
    }

    public func fetch(after cursorValue: String?) async throws -> SyncPage {
        try await checkFormat()
        var cursor = try decodeCursor(cursorValue)
        var records: [SyncRecord] = []
        var delivered = Set<String>()
        if cursorValue == nil, let seed = try await loadSeed() {
            records.append(seed)
            delivered.insert(seed.id)
        }
        let notebookID = try await loadSeed()?.notebookID
        try await refreshPurged()
        var hasMore = false
        let client = client
        let root = root
        devices: for device in try await listDevices() {
            let prefix = logPrefix(device)
            while true {
                let listing = try await client.list(
                    prefix: prefix,
                    startAfter: cursor.positions[device].map { prefix + $0 },
                    maxKeys: 20
                )
                let manifests = try await concurrentMap(listing.keys.map(\.key)) { key in
                    try await client.get(key).map {
                        try JSONDecoder().decode(Manifest.self, from: $0)
                    }
                }
                for (key, manifest) in zip(listing.keys.map(\.key), manifests) {
                    if records.count >= pageSize {
                        hasMore = true
                        break devices
                    }
                    // Records this instance stored are already on this device.
                    let entries = (manifest?.records ?? []).filter {
                        !delivered.contains($0.id) && !publishedIDs.contains($0.id)
                            && !($0.kind == .note && purged.contains($0.document))
                    }
                    let fetched = try await concurrentMap(entries) { entry in
                        try await client.get(Self.recordKey(root: root, entry))
                            .map { (entry, $0) }
                    }
                    for case let (entry, data)? in fetched {
                        let record = try Self.decodeRecord(data, expected: entry)
                        guard record.notebookID == notebookID else {
                            throw SyncError.invalidRecord
                        }
                        if delivered.insert(record.id).inserted {
                            records.append(record)
                            noteSnapshotSeen(record, bytes: data.count)
                        }
                    }
                    cursor.positions[device] = String(key.dropFirst(prefix.count))
                }
                if !listing.isTruncated || listing.keys.isEmpty { break }
            }
        }
        try saveDevice()
        return SyncPage(records: records, cursor: try encodeCursor(cursor), hasMore: hasMore)
    }

    public func purgeDeletedNotes(_ noteIDs: Set<UUID>, notebookID: UUID) async throws {
        guard try await requireNotebookID() == notebookID else { throw SyncError.invalidRecord }
        try await refreshPurged()
        // The coordinator passes every deleted note on every pass. Notes
        // already marked are done; bodies stored later go in cleanup.
        let pending = noteIDs.subtracting(purged)
        guard !pending.isEmpty else { return }
        let client = client
        let root = root
        _ = try await concurrentMap(Array(pending)) { id in
            _ = try await client.put(root + "purged/" + id.uuidString.lowercased(), Data())
            for object in try await client.listAll(prefix: Self.documentPrefix(root: root, id)) {
                try await client.delete(object.key)
            }
        }
        purged.formUnion(pending)
        await diagnostics?("s3_purge", ["notes": pending.count])
    }

    public func cleanupRedundantSnapshots(
        notebookID: UUID
    ) async throws -> SyncSnapshotCleanupReport {
        guard try await requireNotebookID() == notebookID else { throw SyncError.invalidRecord }
        try await refreshPurged()
        let client = client
        // A snapshot whose log entry was never written is invisible to
        // other devices, so only logged snapshots may replace older ones.
        let logged = try await loggedRecordIDs()
        let objects = try await client.listAll(prefix: root + "records/")
        let groups = Dictionary(grouping: objects) { object in
            object.key.dropFirst(root.count + "records/".count).split(separator: "/").first
                .flatMap { UUID(uuidString: String($0)) }
        }
        var report = SyncSnapshotCleanupReport()
        var counts: [String: Int] = [:]
        let candidates = groups.filter { $0.value.count > 1 || ($0.key.map(purged.contains) ?? false) }
        var completed = 0
        for (document, objects) in candidates {
            try Task.checkCancellation()
            guard let document else { continue }
            var victims: [(key: String, size: Int)] = []
            if purged.contains(document) {
                // A device that missed the purge stored this body later.
                victims = objects
            } else {
                let loaded = try await concurrentMap(objects) { object in
                    try await client.get(object.key).map { (object, $0) }
                }
                var records: [(object: (key: String, size: Int), record: SyncRecord,
                               history: Set<String>)] = []
                var unreadable = 0
                for case let (object, data)? in loaded {
                    // One damaged or foreign object must not stop cleanup.
                    guard let record = try? JSONDecoder().decode(SyncRecord.self, from: data),
                          let history = try? cleanupHistory(record) else {
                        unreadable += 1
                        continue
                    }
                    records.append((object, record, history))
                }
                if unreadable > 0 {
                    await diagnostics?("s3_cleanup_unreadable", ["objects": unreadable])
                }
                // Same ranking as CloudKit: a strict order keeps plans from
                // two devices acyclic, so a survivor always remains.
                let ranked = records.sorted {
                    $0.history.count == $1.history.count
                        ? $0.record.id > $1.record.id : $0.history.count > $1.history.count
                }
                var removed = Set<String>()
                for victim in ranked where ranked.contains(where: {
                    !removed.contains($0.record.id) && $0.record.id != victim.record.id
                        && logged.contains($0.record.id)
                        && cleanupCovers(
                            victim: victim.record, history: victim.history,
                            survivor: $0.record, survivorHistory: $0.history)
                }) {
                    removed.insert(victim.record.id)
                    victims.append(victim.object)
                }
                counts[document.uuidString] = objects.count - victims.count
            }
            for victim in victims {
                try Task.checkCancellation()
                try await client.delete(victim.key)
                report.deletedSnapshotCount += 1
                report.deletedCompressedPayloadBytes += victim.size
            }
            completed += 1
            await cleanupProgress?(SyncCleanupProgress(
                stage: .deletion, completedCount: completed, totalCount: candidates.count,
                confirmedDeletionCount: report.deletedSnapshotCount
            ))
        }
        var state = try loadDevice()
        state.lastCleanup = Date()
        state.snapshotCounts = counts.filter { $0.value > 1 }
        state.retainedBytes = 0
        state.hasNewSnapshots = false
        device = state
        try saveDevice()
        await diagnostics?("s3_cleanup", [
            "deleted": report.deletedSnapshotCount,
            "bytes": report.deletedCompressedPayloadBytes,
        ])
        return report
    }

    public func snapshotMaintenanceStatus(
        notebookID: UUID
    ) async throws -> SyncSnapshotMaintenanceStatus? {
        let state = try loadDevice()
        let maximum = state.snapshotCounts.values.max() ?? 1
        return SyncSnapshotMaintenanceStatus(
            lastSuccessfulCleanup: state.lastCleanup,
            maximumSnapshotsPerDocument: maximum,
            retainedSnapshotBytes: state.retainedBytes,
            hasPendingCleanup: maximum > 1,
            hasNewSnapshotsSinceLastCleanup: state.hasNewSnapshots
        )
    }

    public func setCleanupProgressHandler(
        _ handler: (@Sendable (SyncCleanupProgress) async -> Void)?
    ) async {
        cleanupProgress = handler
    }

    public func setDiagnosticsHandler(
        _ handler: (@Sendable (String, [String: Int]) async -> Void)?
    ) async {
        diagnostics = handler
    }

    // MARK: - Connection check

    /// Confirms the bucket is reachable with these credentials by writing,
    /// reading, and deleting a small object, and reports whether the service
    /// rejects a second conditional write as notebook setup needs.
    public func checkConnection() async throws -> S3ConnectionReport {
        let key = root + "connection-checks/" + UUID().uuidString.lowercased()
        let body = Data("meh.md connection check".utf8)
        var first = try await client.put(key, body, ifNoneMatch: true)
        if first == .conditionUnsupported {
            _ = try await client.put(key, body)
        } else {
            first = .stored
        }
        defer { Task { [client] in try? await client.delete(key) } }
        guard try await client.get(key) == body else {
            throw S3SyncTransportError.invalidResponse
        }
        let second = first == .conditionUnsupported
            ? first : try await client.put(key, body, ifNoneMatch: true)
        let existing = try await loadSeed()
        return S3ConnectionReport(
            supportsConditionalWrites: second == .alreadyExists,
            existingNotebookID: existing?.notebookID,
            existingNoteCount: try await latestCatalog(seed: existing)
                .map(NotebookSyncCoordinator.activeNoteCount) ?? 0
        )
    }

    // MARK: - Layout

    private var seedKey: String { root + "seed.json" }
    private var formatKey: String { root + "format.json" }

    private func logPrefix(_ device: String) -> String { root + "log/" + device + "/" }

    private func recordKey(_ record: SyncRecord) -> String {
        Self.recordKey(root: root, Manifest.Entry(
            id: record.id, document: record.snapshot.noteID, kind: record.kind
        ))
    }

    private static func documentPrefix(root: String, _ document: UUID) -> String {
        root + "records/" + document.uuidString.lowercased() + "/"
    }

    private static func recordKey(root: String, _ entry: Manifest.Entry) -> String {
        documentPrefix(root: root, entry.document) + entry.id + ".json"
    }

    private func reserveLogKey() throws -> String {
        var state = try loadDevice()
        let sequence = state.nextSequence
        // Saved before the upload: a crash leaves a gap, never a reused key
        // that a reader could already have passed.
        state.nextSequence += 1
        device = state
        try saveDevice()
        return logPrefix(state.deviceID) + String(format: "%020llu", sequence) + ".json"
    }

    /// A restored backup or a copied app container brings the same device
    /// ID to a second installation. A taken log key means that happened,
    /// so this installation continues under a new ID instead of
    /// overwriting the other one's entries.
    private func writeLog(_ body: Data) async throws {
        for _ in 0..<3 {
            let key = try reserveLogKey()
            switch try await client.put(key, body, ifNoneMatch: true) {
            case .stored:
                return
            case .conditionUnsupported:
                _ = try await client.put(key, body)
                return
            case .alreadyExists:
                var state = try loadDevice()
                state.deviceID = UUID().uuidString.lowercased()
                state.nextSequence = 1
                device = state
                try saveDevice()
                await diagnostics?("s3_device_id_renewed", [:])
            }
        }
        throw SyncError.unavailable("The S3 storage did not accept a new sync log entry.")
    }

    /// The stored catalog snapshots merged, for counting what a folder holds.
    private func latestCatalog(seed: SyncRecord?) async throws -> SyncRecord? {
        guard let seed, let notebookID = seed.notebookID, let snapshot = seed.catalogSnapshot
        else { return nil }
        let merged = try NotebookCatalogDocument(snapshot: snapshot, forSync: true)
        let client = client
        let objects = try await client.listAll(prefix: Self.documentPrefix(root: root, notebookID))
        let bodies = try await concurrentMap(objects.map(\.key)) { try await client.get($0) }
        for case let data? in bodies {
            guard let record = try? JSONDecoder().decode(SyncRecord.self, from: data),
                  let catalog = record.catalogSnapshot,
                  let document = try? NotebookCatalogDocument(snapshot: catalog, forSync: true)
            else { continue }
            try? merged.merge(document)
        }
        return SyncRecord(catalog: merged.snapshot())
    }

    private func loggedRecordIDs() async throws -> Set<String> {
        let client = client
        let keys = try await client.listAll(prefix: root + "log/").map(\.key)
        let manifests = try await concurrentMap(keys) { key in
            try await client.get(key).flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }
        }
        return Set(manifests.compactMap { $0 }.flatMap { $0.records.map(\.id) })
    }

    private func listDevices() async throws -> [String] {
        let prefix = root + "log/"
        var devices: [String] = []
        var token: String?
        repeat {
            let page = try await client.list(
                prefix: prefix, delimiter: "/", continuationToken: token
            )
            devices += page.commonPrefixes.map {
                String($0.dropFirst(prefix.count).dropLast())
            }
            token = page.isTruncated ? page.nextContinuationToken : nil
        } while token != nil
        return devices.filter { !$0.isEmpty && !$0.contains("/") }.sorted()
    }

    // MARK: - Remote state

    private func loadSeed() async throws -> SyncRecord? {
        if let seed { return seed }
        guard let data = try await client.get(seedKey) else { return nil }
        let record: SyncRecord
        do {
            record = try JSONDecoder().decode(SyncRecord.self, from: data)
            try Self.validate(record)
        } catch let error as SyncError {
            if case .updateRequired = error { throw error }
            throw SyncError.invalidRecord
        } catch { throw SyncError.invalidRecord }
        guard record.kind == .catalog else { throw SyncError.invalidRecord }
        seed = record
        return record
    }

    private func requireNotebookID() async throws -> UUID {
        guard let notebookID = try await loadSeed()?.notebookID else {
            throw SyncError.invalidRecord
        }
        return notebookID
    }

    private func refreshPurged() async throws {
        let prefix = root + "purged/"
        for object in try await client.listAll(prefix: prefix) {
            if let id = UUID(uuidString: String(object.key.dropFirst(prefix.count))) {
                purged.insert(id)
            }
        }
    }

    private func checkFormat() async throws {
        guard !formatChecked else { return }
        if let data = try await client.get(formatKey) {
            guard let format = try? JSONDecoder().decode(Format.self, from: data) else {
                throw SyncError.invalidRecord
            }
            try NotebookSyncFormat.requireSupported(format.minimumReaderVersion)
            try NotebookSyncFormat.requireSupported(format.minimumWriterVersion)
        }
        formatChecked = true
    }

    private func writeFormatIfMissing() async throws {
        let current = Format(
            minimumReaderVersion: NotebookSyncFormat.supportedVersion,
            minimumWriterVersion: NotebookSyncFormat.supportedVersion
        )
        let body = try JSONEncoder().encode(current)
        if try await client.put(formatKey, body, ifNoneMatch: true) == .conditionUnsupported,
           try await client.get(formatKey) == nil {
            _ = try await client.put(formatKey, body)
        }
    }

    // MARK: - Local state

    private func loadDevice() throws -> DeviceState {
        if let device { return device }
        var state: DeviceState
        do {
            state = try JSONDecoder().decode(DeviceState.self, from: Data(contentsOf: stateURL))
            if state.scope != scope { state = DeviceState(scope: scope) }
        } catch CocoaError.fileReadNoSuchFile {
            state = DeviceState(scope: scope)
        }
        device = state
        try saveDevice()
        return state
    }

    private func saveDevice() throws {
        guard let device else { return }
        try SyncFileIO.replace(JSONEncoder().encode(device), at: stateURL)
    }

    private func noteSnapshotSeen(_ record: SyncRecord, bytes: Int) {
        guard countedIDs.insert(record.id).inserted else { return }
        guard var state = try? loadDevice() else { return }
        let key = record.snapshot.noteID.uuidString
        let count = (state.snapshotCounts[key] ?? 0) + 1
        state.snapshotCounts[key] = count
        if count > 1 {
            state.retainedBytes += bytes
            state.hasNewSnapshots = true
        }
        device = state
    }

    private func acquireWriteLock() async {
        guard isWriting else {
            isWriting = true
            return
        }
        await withCheckedContinuation { writeWaiters.append($0) }
    }

    private func releaseWriteLock() {
        if writeWaiters.isEmpty {
            isWriting = false
        } else {
            writeWaiters.removeFirst().resume()
        }
    }

    // MARK: - Encoding

    private func decodeCursor(_ value: String?) throws -> Cursor {
        guard let value else { return Cursor(scope: scopeDigest, positions: [:]) }
        guard value.hasPrefix("s3v1."),
              let data = Data(base64Encoded: String(value.dropFirst(5))),
              let cursor = try? JSONDecoder().decode(Cursor.self, from: data),
              cursor.scope == scopeDigest else { throw SyncError.invalidCursor }
        return cursor
    }

    private func encodeCursor(_ cursor: Cursor) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return "s3v1." + (try encoder.encode(cursor)).base64EncodedString()
    }

    private var scopeDigest: String {
        String(SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }
            .joined().prefix(16))
    }

    private static func decodeRecord(_ data: Data, expected: Manifest.Entry) throws -> SyncRecord {
        do {
            let record = try JSONDecoder().decode(SyncRecord.self, from: data)
            guard record.id == expected.id, record.kind == expected.kind,
                  record.snapshot.noteID == expected.document else {
                throw SyncError.invalidRecord
            }
            try validate(record)
            return record
        } catch let error as SyncError {
            if case .updateRequired = error { throw error }
            throw SyncError.invalidRecord
        } catch { throw SyncError.invalidRecord }
    }

    private static func validate(_ record: SyncRecord) throws {
        do {
            guard record.protocolVersion == 2, record.notebookID != nil else {
                throw SyncError.invalidRecord
            }
            try record.validate()
        } catch let error as SyncError {
            if case .updateRequired = error { throw error }
            throw SyncError.invalidRecord
        } catch { throw SyncError.invalidRecord }
    }

    // MARK: - Stored formats

    private struct DeviceState: Codable {
        var version = 1
        var scope: String
        var deviceID = UUID().uuidString.lowercased()
        var nextSequence: UInt64 = 1
        var lastCleanup: Date?
        var snapshotCounts: [String: Int] = [:]
        var retainedBytes = 0
        var hasNewSnapshots = false

        init(scope: String) { self.scope = scope }
    }

    private struct Manifest: Codable {
        struct Entry: Codable, Sendable {
            let id: String
            let document: UUID
            let kind: SyncDocumentKind
        }

        var version = 1
        var records: [Entry]
    }

    private struct Format: Codable {
        let minimumReaderVersion: UInt64
        let minimumWriterVersion: UInt64
    }

    private struct Cursor: Codable {
        let scope: String
        var positions: [String: String]
    }
}

/// What a connection check learned about a bucket.
public struct S3ConnectionReport: Equatable, Sendable {
    /// False for services that ignore or reject `If-None-Match`. Two devices
    /// that set up sync at the same moment could then disagree.
    public let supportsConditionalWrites: Bool
    /// The notebook already stored under this prefix, if any.
    public let existingNotebookID: UUID?
    /// Notes outside Trash in that notebook.
    public let existingNoteCount: Int
}

/// Runs `body` for every item with a few requests in flight, keeping order.
private func concurrentMap<Item: Sendable, Output: Sendable>(
    _ items: [Item], limit: Int = 8,
    _ body: @escaping @Sendable (Item) async throws -> Output
) async rethrows -> [Output] {
    guard !items.isEmpty else { return [] }
    return try await withThrowingTaskGroup(of: (Int, Output).self) { group in
        var results = [Output?](repeating: nil, count: items.count)
        var next = 0
        for _ in 0..<min(limit, items.count) {
            let index = next
            group.addTask { (index, try await body(items[index])) }
            next += 1
        }
        while let (index, output) = try await group.next() {
            results[index] = output
            if next < items.count {
                let index = next
                group.addTask { (index, try await body(items[index])) }
                next += 1
            }
        }
        return results.map { $0! }
    }
}
