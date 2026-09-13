import Foundation

public enum NotebookMigrationError: Error, Equatable {
    case operationInProgress
    case catalogNeedsRecovery
    case catalogUnavailable
    case legacyNoteNeedsRecovery
    case legacyNoteUnavailable
    case destinationNoteNeedsRecovery
    case destinationNoteUnavailable
    case missingMigratedNote
    case identityConflict
}

enum NotebookMigrationStage: CaseIterable {
    case catalogCreated, noteSaved, catalogLinked
}

/// Establishes ID-based notebook storage without altering legacy files.
/// App activation and cloud protocol migration are intentionally separate.
public actor NotebookMigration {
    public nonisolated let directory: URL
    private let catalogStorage: NotebookCatalogStorage
    private var migrating = false

    public init(directory: URL) {
        self.directory = directory
        catalogStorage = NotebookCatalogStorage(directory: directory)
    }

    public nonisolated func noteStorage(for id: UUID) -> NoteFileStorage {
        NoteFileStorage(directory: directory.appending(path: "notes/\(id.uuidString)"))
    }

    /// Restores the previous legacy note after an explicit recovery choice.
    /// `NoteFileStorage` retains the damaged current file in quarantine.
    public func recoverLegacyNoteFromPrevious(
        from legacyDirectory: URL
    ) async throws -> NoteSnapshot {
        guard !migrating else { throw NotebookMigrationError.operationInProgress }
        migrating = true
        defer { migrating = false }
        return try await recover(
            NoteFileStorage(directory: legacyDirectory),
            unavailable: .legacyNoteUnavailable
        )
    }

    /// Restores the previous destination note selected by the durable migration
    /// receipt. The legacy source is never used for this recovery.
    public func recoverMigratedNoteFromPrevious() async throws -> NoteSnapshot {
        guard !migrating else { throw NotebookMigrationError.operationInProgress }
        migrating = true
        defer { migrating = false }

        let catalog: NotebookCatalogDocument
        switch await catalogStorage.load() {
        case .current(let snapshot):
            catalog = try NotebookCatalogDocument(snapshot: snapshot)
        case .recoveryRequired:
            throw NotebookMigrationError.catalogNeedsRecovery
        case .firstLaunch, .blocked:
            throw NotebookMigrationError.catalogUnavailable
        }
        let noteID: UUID
        let initialHeads: Set<String>
        switch try catalog.legacyMigration() {
        case .copying(let id, let heads), .note(let id, let heads):
            noteID = id
            initialHeads = heads
        case .pending, .empty:
            throw NotebookMigrationError.destinationNoteUnavailable
        }
        let storage = noteStorage(for: noteID)
        switch await storage.load() {
        case .current(let snapshot):
            _ = try validatedDocument(
                snapshot,
                noteID: noteID,
                containing: initialHeads
            )
            return snapshot
        case .recoveryRequired(let recovery):
            // Validate the proposed previous bytes before recovery moves or
            // replaces any file.
            _ = try validatedDocument(
                recovery.previous,
                noteID: noteID,
                containing: initialHeads
            )
            return try await storage.recover(recovery)
        case .firstLaunch, .blocked:
            throw NotebookMigrationError.destinationNoteUnavailable
        }
    }

    public func migrateLegacyNote(from legacyDirectory: URL) async throws -> NotebookCatalogSnapshot
    {
        try await migrateLegacyNote(from: legacyDirectory, afterStage: { _ in })
    }

    func migrateLegacyNote(
        from legacyDirectory: URL,
        afterStage: @Sendable (NotebookMigrationStage) throws -> Void
    ) async throws -> NotebookCatalogSnapshot {
        guard !migrating else { throw NotebookMigrationError.operationInProgress }
        migrating = true
        defer { migrating = false }
        let catalog: NotebookCatalogDocument
        switch await catalogStorage.load() {
        case .firstLaunch:
            catalog = try NotebookCatalogDocument()
        case .current(let snapshot):
            catalog = try NotebookCatalogDocument(snapshot: snapshot)
        case .recoveryRequired:
            throw NotebookMigrationError.catalogNeedsRecovery
        case .blocked:
            throw NotebookMigrationError.catalogUnavailable
        }

        switch try catalog.legacyMigration() {
        case .empty:
            return catalog.snapshot()
        case .note(let id, let initialHeads):
            // Never restore old source bytes over a lost/newer destination.
            // A completed migration is independent of the legacy directory.
            switch await noteStorage(for: id).load() {
            case .firstLaunch:
                throw NotebookMigrationError.missingMigratedNote
            case .current(let snapshot):
                _ = try validatedDocument(
                    snapshot,
                    noteID: id,
                    containing: initialHeads
                )
            case .recoveryRequired:
                throw NotebookMigrationError.destinationNoteNeedsRecovery
            case .blocked:
                throw NotebookMigrationError.destinationNoteUnavailable
            }
            return catalog.snapshot()
        case .copying(let id, let initialHeads):
            return try await resumeCopy(
                catalog: catalog,
                legacyDirectory: legacyDirectory,
                noteID: id,
                initialHeads: initialHeads,
                afterStage: afterStage
            )
        case .pending:
            break
        }

        switch await NoteFileStorage(directory: legacyDirectory).load() {
        case .firstLaunch:
            try catalog.completeLegacyMigration(noteID: nil)
            try await catalogStorage.save(catalog.snapshot())
            try afterStage(.catalogLinked)
            return catalog.snapshot()
        case .current(let snapshot):
            try catalog.beginLegacyMigration(
                noteID: snapshot.noteID,
                heads: snapshot.heads
            )
            try await catalogStorage.save(catalog.snapshot())
            try afterStage(.catalogCreated)
            return try await resumeCopy(
                catalog: catalog,
                legacyDirectory: legacyDirectory,
                noteID: snapshot.noteID,
                initialHeads: snapshot.heads,
                afterStage: afterStage
            )
        case .recoveryRequired:
            throw NotebookMigrationError.legacyNoteNeedsRecovery
        case .blocked:
            throw NotebookMigrationError.legacyNoteUnavailable
        }
    }

    private func resumeCopy(
        catalog: NotebookCatalogDocument,
        legacyDirectory: URL,
        noteID: UUID,
        initialHeads: Set<String>,
        afterStage: @Sendable (NotebookMigrationStage) throws -> Void
    ) async throws -> NotebookCatalogSnapshot {
        let legacy: NoteSnapshot?
        switch await NoteFileStorage(directory: legacyDirectory).load() {
        case .firstLaunch:
            legacy = nil
        case .current(let snapshot):
            _ = try validatedDocument(
                snapshot,
                noteID: noteID,
                containing: initialHeads
            )
            legacy = snapshot
        case .recoveryRequired:
            throw NotebookMigrationError.legacyNoteNeedsRecovery
        case .blocked:
            throw NotebookMigrationError.legacyNoteUnavailable
        }

        let destination = noteStorage(for: noteID)
        var destinationSnapshot: NoteSnapshot
        switch await destination.load() {
        case .firstLaunch:
            guard let legacy else {
                throw NotebookMigrationError.missingMigratedNote
            }
            try await destination.save(legacy)
            destinationSnapshot = legacy
        case .current(let existing):
            let existingDocument = try validatedDocument(
                existing,
                noteID: noteID,
                containing: initialHeads
            )
            if let legacy, existing.heads != legacy.heads {
                // A retry may encounter new edits from the old app. Merge
                // shared history rather than replacing either branch.
                try existingDocument.merge(NoteDocument(snapshot: legacy))
                destinationSnapshot = existingDocument.snapshot()
                if destinationSnapshot.heads != existing.heads {
                    try await destination.save(destinationSnapshot)
                }
            } else {
                destinationSnapshot = existing
            }
        case .recoveryRequired:
            throw NotebookMigrationError.destinationNoteNeedsRecovery
        case .blocked:
            throw NotebookMigrationError.destinationNoteUnavailable
        }
        _ = try validatedDocument(
            destinationSnapshot,
            noteID: noteID,
            containing: initialHeads
        )
        try afterStage(.noteSaved)

        if let existing = try catalog.items().first(where: {
            $0.id == noteID
        }) {
            guard existing.kind == .note else {
                throw NotebookMigrationError.identityConflict
            }
        } else {
            try catalog.add(id: noteID, kind: .note, name: "note.md")
        }
        try catalog.completeLegacyMigration(noteID: noteID)
        try await catalogStorage.save(catalog.snapshot())
        try afterStage(.catalogLinked)
        return catalog.snapshot()
    }

    private func validatedDocument(
        _ snapshot: NoteSnapshot,
        noteID: UUID,
        containing initialHeads: Set<String>
    ) throws -> NoteDocument {
        guard snapshot.noteID == noteID else {
            throw NotebookMigrationError.identityConflict
        }
        let document = try NoteDocument(snapshot: snapshot)
        guard initialHeads.isSubset(of: document.historyHeads) else {
            throw NotebookMigrationError.identityConflict
        }
        return document
    }

    private func recover(
        _ storage: NoteFileStorage,
        unavailable: NotebookMigrationError
    ) async throws -> NoteSnapshot {
        switch await storage.load() {
        case .current(let snapshot): return snapshot
        case .recoveryRequired(let recovery):
            return try await storage.recover(recovery)
        case .firstLaunch, .blocked:
            throw unavailable
        }
    }
}
