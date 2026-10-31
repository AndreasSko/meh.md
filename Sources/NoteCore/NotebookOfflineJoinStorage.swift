import Foundation

enum NotebookOfflineJoinError: Error, LocalizedError {
    case invalidReceipt, catalogChanged, needsRestart

    var errorDescription: String? {
        switch self {
        case .invalidReceipt:
            "The saved sync connection record is damaged. Your local notes were left untouched."
        case .catalogChanged:
            "The notebook changed while connecting to sync. Your local notes were left untouched."
        case .needsRestart:
            "Restart meh.md to finish connecting this notebook to sync. Saved notes stay on this device."
        }
    }
}

/// Keep the storage failure available for diagnostics while exposing the
/// recovery step required after an interrupted catalog identity change.
struct NotebookOfflineJoinInterrupted: Error, LocalizedError {
    let underlyingError: any Error

    var errorDescription: String? {
        NotebookOfflineJoinError.needsRestart.errorDescription
    }
}

enum NotebookOfflineJoinStage: CaseIterable, Sendable {
    case journalSaved, importsRebound, deletionsRebound
    case previousReplaced, currentReplaced, catalogInstalled, bindingSaved
}

/// Only notebooks minted for offline-first startup can join an unrelated
/// cloud catalog. A durable transition authorizes replacing both catalog
/// copies, while ordinary saves keep their identity/history checks.
struct NotebookOfflineJoinReceipt: Codable {
    struct Transition: Codable {
        let scope: String
        let source: SyncRecord
        let destination: SyncRecord
        let deletedIDs: Set<UUID>
    }

    /// What the user chose for a notebook that already synced elsewhere.
    /// Without one, the receipt belongs to a fresh offline-first notebook.
    struct Choice: Codable, Equatable {
        enum Kind: String, Codable { case combine, replace }
        let kind: Kind
        /// Only this storage may receive the other notebook.
        let scope: String
        /// Combining puts this device's top-level items in this folder.
        let folderName: String
        /// The stored notebook the user saw; nil applies to any.
        var notebookID: UUID?
    }

    var version = 1
    let initial: SyncRecord
    var transition: Transition?
    var choice: Choice?

    func validate() throws {
        guard version == 1, initial.kind == .catalog,
              initial.protocolVersion == 2 else {
            throw NotebookOfflineJoinError.invalidReceipt
        }
        try initial.validate()
        guard let initialSnapshot = initial.catalogSnapshot else {
            throw NotebookOfflineJoinError.invalidReceipt
        }
        let initialCatalog = try NotebookCatalogDocument(snapshot: initialSnapshot)
        if let choice {
            guard !choice.scope.isEmpty else { throw NotebookOfflineJoinError.invalidReceipt }
            if choice.kind == .combine { try NotebookName.validate(choice.folderName) }
        } else {
            guard try initialCatalog.items().isEmpty else {
                throw NotebookOfflineJoinError.invalidReceipt
            }
        }
        if let transition, let choice, transition.scope != choice.scope {
            throw NotebookOfflineJoinError.invalidReceipt
        }
        if let transition {
            try transition.source.validate()
            try transition.destination.validate()
            guard !transition.scope.isEmpty,
                  let source = transition.source.catalogSnapshot,
                  let destination = transition.destination.catalogSnapshot,
                  source.notebookID == initialSnapshot.notebookID,
                  source.notebookID != destination.notebookID,
                  initialSnapshot.heads.isSubset(of:
                    try NotebookCatalogDocument(snapshot: source).historyHeads)
            else { throw NotebookOfflineJoinError.invalidReceipt }
        }
    }
}

struct NotebookOfflineJoinStorage {
    struct Binding: Codable {
        var version = 1
        let scope: String
        let localNotebookID: UUID
        let notebookID: UUID
        let catalogHeads: Set<String>
    }

    let directory: URL
    var url: URL { directory.appending(path: "offline-notebook.json") }
    var bindingURL: URL { directory.appending(path: "first-sync-binding.json") }

    func saveBinding(_ transition: NotebookOfflineJoinReceipt.Transition) throws {
        guard let sourceID = transition.source.notebookID,
              let destinationID = transition.destination.notebookID else {
            throw NotebookOfflineJoinError.invalidReceipt
        }
        let binding = Binding(scope: transition.scope, localNotebookID: sourceID,
                              notebookID: destinationID, catalogHeads: transition.destination.snapshot.heads)
        try SyncFileIO.replace(JSONEncoder().encode(binding), at: bindingURL)
    }

    func localNotebookID(
        before snapshot: NotebookCatalogSnapshot,
        historyHeads: () -> Set<String>
    ) throws -> UUID? {
        let data: Data
        do { data = try Data(contentsOf: bindingURL) }
        catch CocoaError.fileReadNoSuchFile { return nil }
        let binding = try JSONDecoder().decode(Binding.self, from: data)
        let stateData: Data
        do {
            stateData = try Data(contentsOf: directory.appending(
                path: NotebookSyncState.fileName(forScope: binding.scope)))
        } catch CocoaError.fileReadNoSuchFile { return nil }
        let state = try JSONDecoder().decode(NotebookSyncState.self, from: stateData)
        // A later switch or combine can replace that storage's binding. The
        // old local identity then no longer describes this catalog.
        guard state.notebookID == binding.notebookID,
              snapshot.notebookID == binding.notebookID else { return nil }
        guard binding.version == 1, !binding.catalogHeads.isEmpty,
              binding.localNotebookID != binding.notebookID,
              state.version == 2, state.scope == binding.scope,
              binding.catalogHeads.isSubset(of: historyHeads()) else {
            throw NotebookOfflineJoinError.invalidReceipt
        }
        return binding.localNotebookID
    }

    func load() throws -> NotebookOfflineJoinReceipt? {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch CocoaError.fileReadNoSuchFile { return nil }
        do {
            let receipt = try JSONDecoder().decode(NotebookOfflineJoinReceipt.self, from: data)
            try receipt.validate()
            return receipt
        } catch { throw NotebookOfflineJoinError.invalidReceipt }
    }

    func save(_ receipt: NotebookOfflineJoinReceipt) throws {
        try receipt.validate()
        try SyncFileIO.replace(JSONEncoder().encode(receipt), at: url)
    }

    func remove() throws {
        try FileManager.default.removeItem(at: url)
        try DurableFileIO.syncDirectory(directory)
    }

    /// A crashed join must never reopen a catalog against another account.
    func validateBinding(for transition: NotebookOfflineJoinReceipt.Transition) throws {
        let data: Data
        do {
            data = try Data(contentsOf: directory.appending(
                path: NotebookSyncState.fileName(forScope: transition.scope)))
        }
        catch CocoaError.fileReadNoSuchFile { return }
        let state = try JSONDecoder().decode(NotebookSyncState.self, from: data)
        guard state.version == 2 else { throw SyncError.invalidRecord }
        guard state.scope == transition.scope else { throw SyncError.scopeChanged }
        guard state.notebookID == nil || state.notebookID == transition.destination.notebookID
        else { throw SyncError.identityConflict }
    }
}
