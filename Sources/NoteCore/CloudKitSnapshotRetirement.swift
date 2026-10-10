import Foundation

extension CloudKitTransportState {
    /// Buffered snapshots are only candidates: the caller must confirm their
    /// current remote existence before resolving any deletion.
    func retirementCandidates() throws -> [SyncRecord] {
        guard protocolVersion == 2 else { return [] }
        let deleted = inbox.filter {
            unresolvedRemoteDeletionRecordIDs.contains($0.id)
        }
        var histories: [String: Set<String>] = [:]
        for record in deleted {
            histories[record.id] = try snapshotHistoryChangeHashes(record)
        }
        return try inbox.filter { candidate in
            guard !remoteDeletedSnapshotIDs.contains(candidate.id),
                  !unresolvedRemoteDeletionRecordIDs.contains(candidate.id) else {
                return false
            }
            let matching = deleted.filter {
                snapshotHistoryIdentityMatches($0, candidate)
            }
            guard !matching.isEmpty else { return false }
            let history = try snapshotHistoryChangeHashes(candidate)
            return matching.contains {
                histories[$0.id]!.isSubset(of: history)
            }
        }
    }

    /// Reevaluate against current deletion evidence, including deletions that
    /// arrived while the remote existence check was in flight.
    mutating func resolveSnapshotRetirements(
        confirmedRecords: [SyncRecord]
    ) throws {
        guard protocolVersion == 2 else { return }
        let candidates = try retirementCandidates()
        var covered: Set<String> = []
        for confirmed in confirmedRecords {
            try confirmed.validate()
            guard candidates.contains(confirmed) else { continue }
            let history = try snapshotHistoryChangeHashes(confirmed)
            for deleted in inbox where
                unresolvedRemoteDeletionRecordIDs.contains(deleted.id)
                    && snapshotHistoryIdentityMatches(deleted, confirmed)
            {
                if try snapshotHistoryChangeHashes(deleted).isSubset(of: history) {
                    covered.insert(deleted.id)
                }
            }
        }
        unresolvedRemoteDeletionRecordIDs.subtract(covered)
    }
}

func snapshotHistoryIdentityMatches(
    _ lhs: SyncRecord, _ rhs: SyncRecord
) -> Bool {
    lhs.protocolVersion == rhs.protocolVersion
        && lhs.kind == rhs.kind
        && lhs.notebookID == rhs.notebookID
        && lhs.snapshot.noteID == rhs.snapshot.noteID
}

func snapshotHistoryChangeHashes(_ record: SyncRecord) throws -> Set<String> {
    if let catalog = record.catalogSnapshot {
        return try NotebookCatalogDocument(snapshot: catalog).historyHeads
    }
    return try NoteDocument(snapshot: record.snapshot).historyHeads
}
