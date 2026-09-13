import Foundation

enum NotebookDeletionStorageError: Error, LocalizedError {
    case invalidLedger
    case notebookIdentityMismatch
    case invalidImportJournal(URL)

    var errorDescription: String? {
        switch self {
        case .invalidLedger:
            "The permanent deletion record is damaged."
        case .notebookIdentityMismatch:
            "The permanent deletion record belongs to another notebook."
        case .invalidImportJournal:
            "A retained import record could not be cleaned safely."
        }
    }
}

enum NotebookDeletionStage: Equatable {
    case ledgerSaved
    case catalogSaved
    case beforeNoteRemoval(UUID)
    case noteRemoved(UUID)
    case importJournalsScrubbed
}

/// An independent, append-only record prevents catalog recovery from reviving
/// identities whose permanent marker was already observed on this replica.
struct NotebookDeletionStorage {
    private struct Ledger: Codable {
        let schemaVersion: UInt64
        let notebookID: UUID
        let ids: Set<UUID>
    }

    let directory: URL

    var ledgerURL: URL {
        directory.appending(path: "permanent-deletions.json")
    }

    var hasLedger: Bool {
        FileManager.default.fileExists(atPath: ledgerURL.path)
    }

    func load(notebookID: UUID) throws -> Set<UUID> {
        guard hasLedger else { return [] }
        let ledger: Ledger
        do {
            ledger = try JSONDecoder().decode(
                Ledger.self,
                from: Data(contentsOf: ledgerURL)
            )
        } catch {
            throw NotebookDeletionStorageError.invalidLedger
        }
        guard ledger.schemaVersion == 1 else {
            throw NotebookDeletionStorageError.invalidLedger
        }
        guard ledger.notebookID == notebookID else {
            throw NotebookDeletionStorageError.notebookIdentityMismatch
        }
        return ledger.ids
    }

    @discardableResult
    func record(_ ids: Set<UUID>, notebookID: UUID) throws -> Set<UUID> {
        let existing = try load(notebookID: notebookID)
        let combined = existing.union(ids)
        guard combined != existing else { return combined }

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let temporary = directory.appending(
            path: ".permanent-deletions-\(UUID().uuidString).tmp"
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let ledger = Ledger(
            schemaVersion: 1,
            notebookID: notebookID,
            ids: combined
        )
        try DurableFileIO.writeAndSync(try encoder.encode(ledger), to: temporary)
        try DurableFileIO.renameReplacing(temporary, with: ledgerURL)
        try DurableFileIO.syncDirectory(directory)
        return combined
    }

    func cleanupNoteDirectories(
        _ ids: Set<UUID>,
        afterStage: (NotebookDeletionStage) throws -> Void = { _ in }
    ) throws {
        let notes = directory.appending(path: "notes")
        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
            let noteDirectory = notes.appending(path: id.uuidString)
            guard FileManager.default.fileExists(atPath: noteDirectory.path) else {
                continue
            }
            try afterStage(.beforeNoteRemoval(id))
            try FileManager.default.removeItem(at: noteDirectory)
            try DurableFileIO.syncDirectory(notes)
            try afterStage(.noteRemoved(id))
        }
    }
}
