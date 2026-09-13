import Darwin
import Foundation

public enum NotebookImportError: Error, Equatable, LocalizedError {
    case invalidPlan
    case pendingImportExists
    case noPendingImport
    case corruptJournal
    case bodyConflict(UUID)
    case catalogConflict
    case identityConflict(UUID)
    case notebookIdentityMismatch

    public var errorDescription: String? {
        switch self {
        case .invalidPlan:
            "The selected files do not form a valid notebook import."
        case .pendingImportExists:
            "Finish the interrupted import before starting another one."
        case .noPendingImport:
            "There is no interrupted import to resume."
        case .corruptJournal:
            "The saved import is damaged and was left untouched."
        case .bodyConflict:
            "An imported note body conflicts with the saved import. Nothing was overwritten."
        case .catalogConflict:
            "The notebook changed incompatibly. The saved import was left untouched."
        case .identityConflict:
            "An imported item has the same identity as an existing notebook item."
        case .notebookIdentityMismatch:
            "This saved import belongs to a different notebook."
        }
    }
}

enum NotebookImportStage: Equatable {
    case journalSaved
    case beforeBody(UUID)
    case bodySaved(UUID)
    case beforeCatalog
    case catalogSaved
    case journalSetAside(URL)
}

struct NotebookImportJournal: Codable, Equatable {
    let schemaVersion: UInt64
    let notebookID: UUID
    let plan: NotebookImportPlan
    let snapshots: [NoteSnapshot]

    init(
        notebookID: UUID,
        plan: NotebookImportPlan,
        snapshots: [NoteSnapshot]
    ) {
        schemaVersion = 1
        self.notebookID = notebookID
        self.plan = plan
        self.snapshots = snapshots
    }
}

struct NotebookImportStorage {
    let directory: URL

    var journalURL: URL {
        directory.appending(path: "pending-import.json")
    }

    var hasPendingImport: Bool {
        FileManager.default.fileExists(atPath: journalURL.path)
    }

    func create(_ journal: NotebookImportJournal) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let temporary = directory.appending(
            path: ".pending-import-\(UUID().uuidString).tmp"
        )
        defer { try? fileManager.removeItem(at: temporary) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try DurableFileIO.writeAndSync(try encoder.encode(journal), to: temporary)
        let result = temporary.withUnsafeFileSystemRepresentation { source in
            journalURL.withUnsafeFileSystemRepresentation { destination in
                link(source, destination)
            }
        }
        guard result == 0 else {
            if errno == EEXIST { throw NotebookImportError.pendingImportExists }
            throw DurableFileIO.posixError()
        }
        try DurableFileIO.syncDirectory(directory)
    }

    func load() throws -> NotebookImportJournal {
        guard hasPendingImport else { throw NotebookImportError.noPendingImport }
        do {
            let journal = try JSONDecoder().decode(
                NotebookImportJournal.self,
                from: Data(contentsOf: journalURL)
            )
            guard journal.schemaVersion == 1 else {
                throw NotebookImportError.corruptJournal
            }
            return journal
        } catch let error as NotebookImportError {
            throw error
        } catch {
            throw NotebookImportError.corruptJournal
        }
    }

    func remove() throws {
        guard hasPendingImport else { return }
        try FileManager.default.removeItem(at: journalURL)
        try DurableFileIO.syncDirectory(directory)
    }

    func setAside(
        afterMove: (URL) throws -> Void = { _ in }
    ) throws -> URL {
        guard hasPendingImport else { throw NotebookImportError.noPendingImport }
        let fileManager = FileManager.default
        let recoveryDirectory = directory.appending(path: "import-recovery")
        try fileManager.createDirectory(
            at: recoveryDirectory,
            withIntermediateDirectories: true
        )
        try DurableFileIO.syncDirectory(directory)

        let destination = recoveryDirectory.appending(
            path: "pending-import-\(UUID().uuidString).json"
        )
        try DurableFileIO.renameReplacing(journalURL, with: destination)
        try DurableFileIO.syncDirectory(recoveryDirectory)
        try DurableFileIO.syncDirectory(directory)
        try afterMove(destination)
        return destination
    }
}
