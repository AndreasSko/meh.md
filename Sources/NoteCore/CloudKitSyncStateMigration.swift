import Foundation

/// Each named recovery owns its eligibility and proof. String identifiers
/// preserve unknown migration completions across future updates and rollback.
enum CloudKitSyncStateMigration {
    static let legacySnapshotDeletionHalt = "legacy-snapshot-deletion-halt-v1"
}

/// New fatal deletions retain their cause and cannot enter legacy recovery.
enum CloudKitRemoteDeletionHaltReason: String, Codable, Sendable {
    case canonicalBootstrapDeleted
    case zoneDeleted
}

extension CloudKitTransportState {
    var needsLegacySnapshotDeletionRecovery: Bool {
        protocolVersion == 2 && hasUnexpectedDeletion
            && remoteDeletionHaltReason == nil
            && !completedSyncStateMigrations.contains(
                CloudKitSyncStateMigration.legacySnapshotDeletionHalt
            )
    }

    func legacyRecoveryNotebookID() throws -> UUID {
        guard needsLegacySnapshotDeletionRecovery,
              let notebookID = inbox.first(where: { $0.kind == .catalog })?.notebookID,
              inbox.allSatisfy({ $0.notebookID == notebookID }),
              outbox.values.allSatisfy({ $0.notebookID == notebookID }),
              unresolvedRemoteDeletionRecordIDs.isSubset(of:
                Set(inbox.map(\.id)).union(purgedRecordIDs)) else {
            throw CloudKitSyncTransportError.unexpectedDeletion
        }
        return notebookID
    }
}

/// Only directly confirmed cloud records supply coverage. Pending uploads
/// never supply proof, and permanent deletion requires a remote catalog.
struct CloudKitSnapshotRecoveryProof {
    private(set) var uncovered: [SyncRecord]
    private var histories: [String: Set<String>] = [:]

    init(requiredRecords: [SyncRecord]) { uncovered = requiredRecords }

    var isComplete: Bool { uncovered.isEmpty }

    mutating func candidates(in records: [SyncRecord]) throws -> [SyncRecord] {
        var ranked: [(SyncRecord, Int)] = []
        for record in records where try needs(record) {
            ranked.append((record, try history(record).count))
        }
        return ranked.sorted {
            $0.1 == $1.1 ? $0.0.id > $1.0.id : $0.1 > $1.1
        }.map(\.0)
    }

    mutating func needs(_ record: SyncRecord) throws -> Bool {
        // Catalogs may excuse a permanently deleted body even when they
        // don't cover a previously received catalog's concurrent branch.
        if record.kind == .catalog { return !isComplete }
        let candidateHistory = try history(record)
        for required in uncovered where snapshotHistoryIdentityMatches(required, record) {
            if try history(required).isSubset(of: candidateHistory) { return true }
        }
        return false
    }

    mutating func confirm(_ record: SyncRecord) throws {
        let candidateHistory = try history(record)
        let deletedIDs: Set<UUID>
        if let snapshot = record.catalogSnapshot {
            deletedIDs = Set(try NotebookCatalogDocument(snapshot: snapshot)
                .items().filter(\.isPermanentlyDeleted).map(\.id))
        } else {
            deletedIDs = []
        }
        var remaining: [SyncRecord] = []
        for required in uncovered {
            if required.kind == .note, required.notebookID == record.notebookID,
               deletedIDs.contains(required.snapshot.noteID) { continue }
            if snapshotHistoryIdentityMatches(required, record),
               try history(required).isSubset(of: candidateHistory) { continue }
            remaining.append(required)
        }
        uncovered = remaining
    }

    private mutating func history(_ record: SyncRecord) throws -> Set<String> {
        if let cached = histories[record.id] { return cached }
        let value = try snapshotHistoryChangeHashes(record)
        histories[record.id] = value
        return value
    }
}
