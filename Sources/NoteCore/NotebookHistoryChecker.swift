import Foundation

/// Checks immutable, durable snapshots away from the UI's main actor.
/// No live documents or persistence operations enter this worker.
actor NotebookHistoryChecker {
    private struct Entry {
        let record: SyncRecord
        let history: Set<String>
        let cost: Int
    }

    private let maximumEntries: Int
    private let maximumBytes: Int
    private var entries: [String: Entry] = [:]
    private var recency: [String] = []
    private var cachedBytes = 0
    private(set) var decodedSnapshotCount = 0

    init(maximumEntries: Int = 256, maximumBytes: Int = 32 * 1_024 * 1_024) {
        self.maximumEntries = max(0, maximumEntries)
        self.maximumBytes = max(0, maximumBytes)
    }

    func containsHistory(
        _ checkpoints: [String: Set<String>],
        records: [SyncRecord],
        deleted: Set<UUID>
    ) throws -> Bool {
        let indexed = Dictionary(uniqueKeysWithValues: records.map { ($0.documentKey, $0) })
        for (key, heads) in checkpoints {
            try Task.checkCancellation()
            if key.hasPrefix("note:"), let id = UUID(uuidString: String(key.dropFirst(5))),
                deleted.contains(id)
            {
                continue
            }
            // Presence is checked on every pass, even when history is cached:
            // a deleted or lost file must still cause replay.
            guard let record = indexed[key] else { return false }
            if !heads.isSubset(of: try history(for: record)) { return false }
        }
        return true
    }

    private func history(for record: SyncRecord) throws -> Set<String> {
        let key = record.documentKey
        // Compare bytes and claimed identity/heads, not just revision labels.
        // Corruption or a rollback must not reuse a previously validated entry.
        if let entry = entries[key], entry.record == record {
            touch(key)
            return entry.history
        }
        remove(key)
        let history: Set<String>
        if let catalog = record.catalogSnapshot {
            history = try NotebookCatalogDocument(snapshot: catalog).historyHeads
        } else {
            history = try NoteDocument(snapshot: record.snapshot).historyHeads
        }
        decodedSnapshotCount += 1

        // Bound retained payload plus a conservative allowance per hash.
        // Oversized documents are checked normally but not retained.
        let cost = record.snapshot.data.count + history.count * 128
        if maximumEntries > 0, cost <= maximumBytes {
            while !recency.isEmpty,
                entries.count >= maximumEntries || cachedBytes + cost > maximumBytes
            {
                remove(recency[0])
            }
            entries[key] = Entry(record: record, history: history, cost: cost)
            cachedBytes += cost
            touch(key)
        }
        return history
    }

    private func touch(_ key: String) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    private func remove(_ key: String) {
        if let removed = entries.removeValue(forKey: key) { cachedBytes -= removed.cost }
        recency.removeAll { $0 == key }
    }
}
