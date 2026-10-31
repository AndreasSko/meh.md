import Foundation

/// The full history a snapshot carries. Cleanup on every backend deletes a
/// snapshot only when another one for the same document covers it.
func cleanupHistory(_ record: SyncRecord) throws -> Set<String> {
    if let catalog = record.catalogSnapshot {
        return try NotebookCatalogDocument(snapshot: catalog).historyHeads
    }
    return try NoteDocument(snapshot: record.snapshot).historyHeads
}

func cleanupCovers(
    victim: SyncRecord, history: Set<String>,
    survivor: SyncRecord, survivorHistory: Set<String>
) -> Bool {
    history.isSubset(of: survivorHistory)
        && (history.count < survivorHistory.count
            || (history.count == survivorHistory.count && victim.id < survivor.id))
}
