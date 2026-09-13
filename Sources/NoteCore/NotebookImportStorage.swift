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

    /// Remove confirmed identities and embedded note bodies from both the
    /// active journal and retained recovery journals. Children absent from the
    /// confirmed set are detached instead of being deleted implicitly.
    func scrub(deletedIDs: Set<UUID>, notebookID: UUID) throws {
        guard !deletedIDs.isEmpty else { return }
        if hasPendingImport {
            try scrub(
                journalURL,
                deletedIDs: deletedIDs,
                notebookID: notebookID
            )
        }
        try scrubInterruptedFiles(
            in: directory,
            deletedIDs: deletedIDs,
            notebookID: notebookID
        )
        let recoveryDirectory = directory.appending(path: "import-recovery")
        let recoveryURLs = try contentsIfPresent(of: recoveryDirectory)
        for url in recoveryURLs where url.pathExtension == "json" {
            try scrub(url, deletedIDs: deletedIDs, notebookID: notebookID)
        }
        try scrubInterruptedFiles(
            in: recoveryDirectory,
            deletedIDs: deletedIDs,
            notebookID: notebookID
        )
    }

    private func scrubInterruptedFiles(
        in directory: URL,
        deletedIDs: Set<UUID>,
        notebookID: UUID
    ) throws {
        for url in try contentsIfPresent(of: directory)
        where isOwnedInterruptedFile(url.lastPathComponent) {
            do {
                try scrub(
                    url,
                    deletedIDs: deletedIDs,
                    notebookID: notebookID
                )
            } catch NotebookDeletionStorageError.invalidImportJournal(_) {
                // These files are replaceable write intermediates. A crash can
                // leave one truncated, but it is never a durable recovery
                // record that should block permanent-deletion cleanup.
                try FileManager.default.removeItem(at: url)
                try DurableFileIO.syncDirectory(directory)
            }
        }
    }

    private func contentsIfPresent(of directory: URL) throws -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: []
            )
        } catch CocoaError.fileReadNoSuchFile {
            return []
        }
    }

    private func isOwnedInterruptedFile(_ name: String) -> Bool {
        (name.hasPrefix(".pending-import-")
            || name.hasPrefix(".scrubbed-import-"))
            && name.hasSuffix(".tmp")
    }

    private func scrub(
        _ url: URL,
        deletedIDs: Set<UUID>,
        notebookID: UUID
    ) throws {
        let journal: NotebookImportJournal
        do {
            journal = try JSONDecoder().decode(
                NotebookImportJournal.self,
                from: Data(contentsOf: url)
            )
            guard journal.schemaVersion == 1 else {
                throw NotebookDeletionStorageError.invalidImportJournal(url)
            }
            guard journal.notebookID == notebookID else {
                throw NotebookDeletionStorageError.invalidImportJournal(url)
            }
        } catch is NotebookDeletionStorageError {
            throw NotebookDeletionStorageError.invalidImportJournal(url)
        } catch {
            throw NotebookDeletionStorageError.invalidImportJournal(url)
        }

        guard journal.plan.entries.contains(where: {
            deletedIDs.contains($0.id)
                || $0.parentID.map(deletedIDs.contains) == true
        }) || journal.snapshots.contains(where: { deletedIDs.contains($0.noteID) }) else {
            return
        }
        let retainedEntries: [NotebookImportEntry] = journal.plan.entries.compactMap { entry in
            guard !deletedIDs.contains(entry.id) else { return nil }
            return NotebookImportEntry(
                id: entry.id,
                kind: entry.kind,
                name: entry.name,
                parentID: entry.parentID.flatMap {
                    deletedIDs.contains($0) ? nil : $0
                },
                text: entry.text
            )
        }
        let retainedSnapshots = journal.snapshots.filter {
            !deletedIDs.contains($0.noteID)
        }
        if retainedEntries.isEmpty {
            try FileManager.default.removeItem(at: url)
            try DurableFileIO.syncDirectory(url.deletingLastPathComponent())
            return
        }

        let replacement = NotebookImportJournal(
            notebookID: journal.notebookID,
            plan: NotebookImportPlan(
                id: journal.plan.id,
                entries: retainedEntries,
                skippedPaths: journal.plan.skippedPaths
            ),
            snapshots: retainedSnapshots
        )
        let temporary = url.deletingLastPathComponent().appending(
            path: ".scrubbed-import-\(UUID().uuidString).tmp"
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try DurableFileIO.writeAndSync(try encoder.encode(replacement), to: temporary)
        try DurableFileIO.renameReplacing(temporary, with: url)
        try DurableFileIO.syncDirectory(url.deletingLastPathComponent())
    }
}
