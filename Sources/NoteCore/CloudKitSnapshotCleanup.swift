import Foundation

/// A durable intention, never a substitute for current remote existence checks.
struct CloudKitSnapshotCleanupPlan: Codable, Equatable, Sendable {
    var victimID: String
    var survivorID: String
}

extension CloudKitTransportState {
    /// Grouping avoids comparisons across unrelated documents. Histories are
    /// parsed once per eligible record; remote-deleted records are never parsed.
    /// The executor bounds remote deletion work, while discovery considers all
    /// active records so neither large documents nor later groups can starve.
    func proposedSnapshotCleanupPlans() throws -> [CloudKitSnapshotCleanupPlan] {
        guard protocolVersion == 2 else { return [] }
        let pendingVictims = Set(pendingSnapshotCleanup.keys)
        let selected = inbox.filter {
            cleanupEligible($0) && !pendingVictims.contains($0.id)
        }
        let groups = Dictionary(grouping: selected, by: CleanupIdentity.init)
        var result: [CloudKitSnapshotCleanupPlan] = []
        for records in groups.values where records.count > 1 {
            var histories: [String: Set<String>] = [:]
            for record in records {
                histories[record.id] = try cleanupHistory(record)
            }
            // Descending rank ensures the first covering record is maximal.
            // Coverage strictly increases (history count, immutable ID), making
            // independently selected concurrent plans acyclic as well.
            let ranked = records.sorted {
                let lhs = histories[$0.id]!.count
                let rhs = histories[$1.id]!.count
                return lhs == rhs ? $0.id > $1.id : lhs > rhs
            }
            var victims: Set<String> = []
            for victim in ranked {
                let victimHistory = histories[victim.id]!
                if let survivor = ranked.first(where: {
                    !victims.contains($0.id)
                        && cleanupCovers(
                            victim: victim, history: victimHistory,
                            survivor: $0, survivorHistory: histories[$0.id]!)
                }) {
                    victims.insert(victim.id)
                    result.append(.init(victimID: victim.id, survivorID: survivor.id))
                }
            }
        }
        return result.sorted { $0.victimID < $1.victimID }
    }

    mutating func persistSnapshotCleanupPlans(
        _ plans: [CloudKitSnapshotCleanupPlan]
    ) throws {
        let victims = Set(plans.map(\.victimID))
        let proofs = try snapshotCleanupRecords(for: plans)
        for plan in plans {
            guard !victims.contains(plan.survivorID),
                  pendingSnapshotCleanup[plan.survivorID] == nil,
                  proofs[plan.victimID]?.survivor.id == plan.survivorID
            else { continue }
            pendingSnapshotCleanup[plan.victimID] = plan
        }
    }

    /// Recompute full history proofs after a restart. The transport additionally
    /// confirms the remote survivor's exact payload before deletion.
    func snapshotCleanupRecords(
        for plans: [CloudKitSnapshotCleanupPlan]
    ) throws -> [String: (victim: SyncRecord, survivor: SyncRecord)] {
        guard protocolVersion == 2 else { return [:] }
        let records = Dictionary(inbox.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var histories: [String: Set<String>] = [:]
        var result: [String: (victim: SyncRecord, survivor: SyncRecord)] = [:]
        for plan in plans {
            guard let victim = records[plan.victimID],
                  let survivor = records[plan.survivorID],
                  cleanupPairEligible(victim: victim, survivor: survivor) else { continue }
            if histories[victim.id] == nil {
                histories[victim.id] = try cleanupHistory(victim)
            }
            if histories[survivor.id] == nil {
                histories[survivor.id] = try cleanupHistory(survivor)
            }
            if cleanupCovers(victim: victim, history: histories[victim.id]!,
                             survivor: survivor, survivorHistory: histories[survivor.id]!) {
                result[plan.victimID] = (victim, survivor)
            }
        }
        return result
    }

    func snapshotCleanupRecords(
        for plan: CloudKitSnapshotCleanupPlan
    ) throws -> (victim: SyncRecord, survivor: SyncRecord)? {
        try snapshotCleanupRecords(for: [plan])[plan.victimID]
    }

    /// Reuse only a proof computed in this execution pass. Exact immutable
    /// record equality permits cheap checks after each asynchronous remote read;
    /// outbox and deletion evidence must still be checked against current state.
    func snapshotCleanupRecords(
        for plan: CloudKitSnapshotCleanupPlan,
        reusing proof: (victim: SyncRecord, survivor: SyncRecord)
    ) -> (victim: SyncRecord, survivor: SyncRecord)? {
        guard proof.victim.id == plan.victimID, proof.survivor.id == plan.survivorID,
              inbox.contains(proof.victim), inbox.contains(proof.survivor),
              cleanupPairEligible(victim: proof.victim, survivor: proof.survivor)
        else { return nil }
        return proof
    }

    private func cleanupPairEligible(victim: SyncRecord, survivor: SyncRecord) -> Bool {
        protocolVersion == 2 && cleanupEligible(victim) && cleanupEligible(survivor)
            && pendingSnapshotCleanup[survivor.id] == nil
            && CleanupIdentity(victim) == CleanupIdentity(survivor)
    }

    /// Call only after confirmed remote deletion. Retaining local snapshots
    /// preserves replay and every already-issued pagination cursor.
    mutating func completeSnapshotCleanup(_ plan: CloudKitSnapshotCleanupPlan) {
        guard pendingSnapshotCleanup[plan.victimID] == plan else { return }
        pendingSnapshotCleanup.removeValue(forKey: plan.victimID)
        remoteDeletedSnapshotIDs.insert(plan.victimID)
    }

    mutating func dropSnapshotCleanup(_ plan: CloudKitSnapshotCleanupPlan) {
        guard pendingSnapshotCleanup[plan.victimID] == plan else { return }
        pendingSnapshotCleanup.removeValue(forKey: plan.victimID)
    }

    /// Cheap persisted-state validation: stale plans remain recoverable after
    /// remote deletions or purges. Full document parsing belongs to execution.
    func validateSnapshotCleanupPlans() throws {
        let records = Dictionary(inbox.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (key, plan) in pendingSnapshotCleanup {
            try CloudKitRemoteRecordValidator.validateSnapshotID(plan.victimID)
            try CloudKitRemoteRecordValidator.validateSnapshotID(plan.survivorID)
            guard key == plan.victimID, plan.victimID != plan.survivorID,
                  protocolVersion == 2 else { throw SyncError.invalidRecord }
            if let victim = records[plan.victimID], let survivor = records[plan.survivorID] {
                guard victim.protocolVersion == 2, survivor.protocolVersion == 2,
                      CleanupIdentity(victim) == CleanupIdentity(survivor)
                else { throw SyncError.invalidRecord }
            }
        }
    }

    private func cleanupEligible(_ record: SyncRecord) -> Bool {
        record.protocolVersion == 2 && cleanupHashID(record.id)
            && record.id != canonicalSnapshotID
            && !remoteDeletedSnapshotIDs.contains(record.id)
            && !unresolvedRemoteDeletionRecordIDs.contains(record.id)
            && !purgedRecordIDs.contains(record.id)
            && outbox[record.id] == nil
    }
}

private struct CleanupIdentity: Hashable {
    let protocolVersion: Int
    let kind: String
    let notebookID: UUID?
    let documentID: UUID

    init(_ record: SyncRecord) {
        protocolVersion = record.protocolVersion
        kind = record.kind.rawValue
        notebookID = record.notebookID
        documentID = record.snapshot.noteID
    }
}

private func cleanupHashID(_ id: String) -> Bool {
    id.utf8.count == 64 && id.utf8.allSatisfy {
        (48...57).contains($0) || (97...102).contains($0)
    }
}

private func cleanupHistory(_ record: SyncRecord) throws -> Set<String> {
    if let catalog = record.catalogSnapshot {
        return try NotebookCatalogDocument(snapshot: catalog).historyHeads
    }
    return try NoteDocument(snapshot: record.snapshot).historyHeads
}

private func cleanupCovers(
    victim: SyncRecord, history: Set<String>,
    survivor: SyncRecord, survivorHistory: Set<String>
) -> Bool {
    history.isSubset(of: survivorHistory)
        && (history.count < survivorHistory.count
            || (history.count == survivorHistory.count && victim.id < survivor.id))
}
