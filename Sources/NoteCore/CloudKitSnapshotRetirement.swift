import Foundation

extension CloudKitTransportState {
    /// Buffered snapshots are only candidates: the caller must confirm their
    /// current remote existence before resolving any deletion.
    func retirementCandidates(
        historyHashes: (SyncRecord) throws -> Set<String> = snapshotHistoryChangeHashes
    ) throws -> [SyncRecord] {
        guard protocolVersion == 2 else { return [] }
        let deleted = inbox.filter {
            unresolvedRemoteDeletionRecordIDs.contains($0.id)
        }
        var histories: [String: Set<String>] = [:]
        for record in deleted {
            histories[record.id] = try historyHashes(record)
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
            let history = try historyHashes(candidate)
            return matching.contains {
                histories[$0.id]!.isSubset(of: history)
            }
        }
    }

    /// Reevaluate against current deletion evidence, including deletions that
    /// arrived while the remote existence check was in flight.
    mutating func resolveSnapshotRetirements(
        confirmedRecords: [SyncRecord],
        historyHashes: (SyncRecord) throws -> Set<String> = snapshotHistoryChangeHashes
    ) throws {
        guard protocolVersion == 2 else { return }
        var covered: Set<String> = []
        for confirmed in confirmedRecords {
            try confirmed.validate()
            // Confirmation is useful only for an exact buffered record that
            // has not itself been deleted during the remote read. Rebuilding
            // every other candidate's history cannot strengthen this proof.
            guard !remoteDeletedSnapshotIDs.contains(confirmed.id),
                  !unresolvedRemoteDeletionRecordIDs.contains(confirmed.id),
                  inbox.contains(confirmed) else { continue }
            let deletedRecords = inbox.filter {
                unresolvedRemoteDeletionRecordIDs.contains($0.id)
                    && snapshotHistoryIdentityMatches($0, confirmed)
            }
            guard !deletedRecords.isEmpty else { continue }
            let history = try historyHashes(confirmed)
            for deleted in deletedRecords {
                if try historyHashes(deleted).isSubset(of: history) {
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
