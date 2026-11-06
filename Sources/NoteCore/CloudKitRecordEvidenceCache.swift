import Foundation

/// Derived evidence belongs to an exact immutable record, never just its ID.
/// This cache is process-local; failures are not cached and restarts revalidate.
struct CloudKitRecordEvidenceCache<Value> {
    private var entries: [String: (record: SyncRecord, value: Value)] = [:]
    private var insertionOrder: [String] = []
    private var payloadBytes = 0
    let maximumEntries: Int
    let maximumPayloadBytes: Int

    init(maximumEntries: Int = .max, maximumPayloadBytes: Int = .max) {
        self.maximumEntries = maximumEntries
        self.maximumPayloadBytes = maximumPayloadBytes
    }

    mutating func value(
        for record: SyncRecord, compute: (SyncRecord) throws -> Value
    ) throws -> Value {
        if let value = cachedValue(for: record) { return value }
        try Task.checkCancellation()
        let value = try compute(record)
        store(value, for: record)
        return value
    }

    func cachedValue(for record: SyncRecord) -> Value? {
        guard let entry = entries[record.id], entry.record == record else { return nil }
        return entry.value
    }

    mutating func store(_ value: Value, for record: SyncRecord) {
        if let old = entries.removeValue(forKey: record.id) {
            payloadBytes -= old.record.snapshot.data.count
            insertionOrder.removeAll { $0 == record.id }
        }
        let bytes = record.snapshot.data.count
        guard maximumEntries > 0, bytes <= maximumPayloadBytes else { return }
        while !insertionOrder.isEmpty && (entries.count >= maximumEntries
            || payloadBytes > maximumPayloadBytes - bytes) {
            let id = insertionOrder.removeFirst()
            if let old = entries.removeValue(forKey: id) {
                payloadBytes -= old.record.snapshot.data.count
            }
        }
        entries[record.id] = (record, value)
        insertionOrder.append(record.id)
        payloadBytes += bytes
    }

    mutating func retain(recordIDs: Set<String>) {
        for id in insertionOrder where !recordIDs.contains(id) {
            if let old = entries.removeValue(forKey: id) {
                payloadBytes -= old.record.snapshot.data.count
            }
        }
        insertionOrder.removeAll { !recordIDs.contains($0) }
    }

    mutating func removeAll() {
        entries.removeAll()
        insertionOrder.removeAll()
        payloadBytes = 0
    }
}

func catalogPermanentMarkers(_ record: SyncRecord) throws -> Set<UUID> {
    guard let snapshot = record.catalogSnapshot else { throw SyncError.invalidRecord }
    return Set(try NotebookCatalogDocument(snapshot: snapshot).items().lazy.filter {
        $0.isPermanentlyDeleted
    }.map(\.id))
}
