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
    private var cachedBytes = 0
    private(set) var decodedSnapshotCount = 0

    init(maximumEntries: Int = 1_024, maximumBytes: Int = 32 * 1_024 * 1_024) {
        self.maximumEntries = max(0, maximumEntries)
        self.maximumBytes = max(0, maximumBytes)
    }

    func containsHistory(
        _ checkpoints: [String: Set<String>],
        records: [SyncRecord],
        deleted: Set<UUID>
    ) throws -> Bool {
        try Task.checkCancellation()
        let indexed = Dictionary(uniqueKeysWithValues: records.map { ($0.documentKey, $0) })
        // Retain only members of this pass's active working set. A missing or
        // changed record must never inherit a previously decoded history.
        for key in Array(entries.keys) {
            guard checkpoints[key] != nil,
                !isDeletedNote(key, deleted: deleted),
                let record = indexed[key], entries[key]?.record == record
            else {
                remove(key)
                continue
            }
        }
        // A stable order keeps the same bounded subset resident when a
        // notebook has more checkpoints than the cache can hold.
        for (key, heads) in checkpoints.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            if isDeletedNote(key, deleted: deleted) { continue }
            // Presence is checked on every pass, even when history is cached:
            // a deleted or lost file must still cause replay.
            guard let record = indexed[key] else { return false }
            if !heads.isSubset(of: try history(for: record)) { return false }
        }
        return true
    }

    private func isDeletedNote(_ key: String, deleted: Set<UUID>) -> Bool {
        key.hasPrefix("note:")
            && UUID(uuidString: String(key.dropFirst(5))).map(deleted.contains) == true
    }

    private func history(for record: SyncRecord) throws -> Set<String> {
        let key = record.documentKey
        // Compare bytes and claimed identity/heads, not just revision labels.
        // Corruption or a rollback must not reuse a previously validated entry.
        if let entry = entries[key], entry.record == record {
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
        if entries.count < maximumEntries,
            cost <= maximumBytes - cachedBytes
        {
            entries[key] = Entry(record: record, history: history, cost: cost)
            cachedBytes += cost
        }
        return history
    }

    private func remove(_ key: String) {
        if let removed = entries.removeValue(forKey: key) { cachedBytes -= removed.cost }
    }
}
