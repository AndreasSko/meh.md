import Foundation

public enum NotebookLegacyBridgeError: Error, Equatable, LocalizedError {
    case operationInProgress
    case incompatibleCloudScopes
    case legacyScopeChanged
    case legacyBindingUnavailable
    case corruptReceipt
    case sourceNeedsRecovery
    case sourceUnavailable
    case bridgeNeedsRecovery
    case bridgeUnavailable
    case bridgeIdentityConflict
    case sessionUnavailable
    case exchangeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .operationInProgress:
            "The legacy compatibility import is already running."
        case .incompatibleCloudScopes:
            "The legacy note and notebook use different iCloud accounts."
        case .legacyScopeChanged:
            "The saved legacy sync workspace belongs to another iCloud account."
        case .legacyBindingUnavailable:
            "The saved legacy sync binding is unreadable."
        case .corruptReceipt:
            "The saved legacy compatibility receipt is corrupt."
        case .sourceNeedsRecovery:
            "Recover the legacy note before enabling notebook sync."
        case .sourceUnavailable:
            "The legacy note is unavailable."
        case .bridgeNeedsRecovery:
            "Recover the compatibility copy before synchronizing it."
        case .bridgeUnavailable:
            "The compatibility copy is unavailable."
        case .bridgeIdentityConflict:
            "The compatibility copy no longer matches the legacy note."
        case .sessionUnavailable:
            "The canonical legacy note is not available yet."
        case let .exchangeFailed(message):
            "Legacy compatibility sync failed: \(message)"
        }
    }
}

/// Imports the canonical V1 note into notebook sync without modifying the old
/// local note. The private bridge copy keeps receiving late writes from old
/// app versions and can be merged into the V2 notebook on every exchange.
@MainActor
public final class NotebookLegacyBridge {
    public let directory: URL
    public let legacyDirectory: URL

    private let receiptURL: URL
    private let proposalURL: URL
    private let stateURL: URL
    private var synchronizing = false

    public init(directory: URL, legacyDirectory: URL) {
        self.directory = directory
        self.legacyDirectory = legacyDirectory
        receiptURL = directory.appending(path: "source-receipt.json")
        proposalURL = directory.appending(path: "bootstrap-proposal.json")
        stateURL = directory.appending(path: "sync-state.json")
    }

    /// Restores the previous source note only after an explicit user action.
    /// The damaged current file is retained by `NoteFileStorage`.
    public func recoverSourceFromPrevious() async throws -> NoteSnapshot {
        try await recover(
            NoteFileStorage(directory: legacyDirectory),
            unavailable: .sourceUnavailable
        )
    }

    /// Restores the bridge's private compatibility copy without rereading the
    /// original legacy source.
    public func recoverBridgeFromPrevious() async throws -> NoteSnapshot {
        try await recover(
            NoteFileStorage(directory: directory),
            unavailable: .bridgeUnavailable
        )
    }

    /// Returns the fully exchanged V1 snapshot to pass to
    /// `NotebookSyncCoordinator.synchronize(legacyNote:)`.
    public func synchronize(
        legacyTransport: any SyncTransport,
        notebookScope: String
    ) async throws -> NoteSnapshot {
        guard !synchronizing else {
            throw NotebookLegacyBridgeError.operationInProgress
        }
        synchronizing = true
        defer { synchronizing = false }

        try Self.validateCloudScopes(
            legacy: legacyTransport.scope,
            notebook: notebookScope
        )
        try await validateLegacyBinding(scope: legacyTransport.scope)
        let receipt = try await loadOrCreateReceipt(
            legacyScope: legacyTransport.scope,
            notebookScope: notebookScope
        )
        let bridgeStorage = NoteFileStorage(directory: directory)
        try await prepareBridgeStorage(bridgeStorage, receipt: receipt)

        let bootstrap = SyncBootstrapStorage(
            storage: bridgeStorage,
            transport: legacyTransport,
            proposalURL: proposalURL,
            allowsOfflineFirstLaunch: false
        )
        let session = NoteSession(storage: bootstrap)
        await session.load()
        guard session.isEditingEnabled, session.persistedSnapshot != nil else {
            throw NotebookLegacyBridgeError.sessionUnavailable
        }
        let coordinator = NoteSyncCoordinator(
            session: session,
            transport: legacyTransport,
            stateURL: stateURL
        )
        await coordinator.synchronize()
        if case let .failed(message) = coordinator.status {
            throw NotebookLegacyBridgeError.exchangeFailed(message)
        }
        guard let snapshot = session.persistedSnapshot else {
            throw NotebookLegacyBridgeError.sessionUnavailable
        }
        return snapshot
    }

    static func validateCloudScopes(
        legacy: String,
        notebook: String
    ) throws {
        let legacySuffix = "/meh-md-sync-v1"
        let notebookSuffix = "/meh-md-notebook-v2"
        if legacy.hasSuffix(legacySuffix) {
            guard notebook.hasSuffix(notebookSuffix),
                  legacy.dropLast(legacySuffix.count)
                    == notebook.dropLast(notebookSuffix.count) else {
                throw NotebookLegacyBridgeError.incompatibleCloudScopes
            }
            return
        }
        guard notebook == legacy + "#v2" else {
            throw NotebookLegacyBridgeError.incompatibleCloudScopes
        }
    }

    private struct Receipt: Codable {
        var version = 1
        let legacyScope: String
        let notebookScope: String
        let source: NoteSnapshot?
    }

    private func validateLegacyBinding(scope: String) async throws {
        do {
            _ = try await SyncStateStorage(
                url: legacyDirectory.appending(path: "sync-state.json")
            ).load(scope: scope)
        } catch SyncError.scopeChanged {
            throw NotebookLegacyBridgeError.legacyScopeChanged
        } catch {
            throw NotebookLegacyBridgeError.legacyBindingUnavailable
        }
    }

    private func loadOrCreateReceipt(
        legacyScope: String,
        notebookScope: String
    ) async throws -> Receipt {
        if FileManager.default.fileExists(atPath: receiptURL.path) {
            let receipt: Receipt
            do {
                receipt = try JSONDecoder().decode(
                    Receipt.self,
                    from: Data(contentsOf: receiptURL)
                )
            } catch {
                throw NotebookLegacyBridgeError.corruptReceipt
            }
            guard receipt.version == 1 else {
                throw NotebookLegacyBridgeError.corruptReceipt
            }
            guard receipt.legacyScope == legacyScope,
                  receipt.notebookScope == notebookScope else {
                throw NotebookLegacyBridgeError.legacyScopeChanged
            }
            if let source = receipt.source {
                do { _ = try NoteDocument(snapshot: source) } catch {
                    throw NotebookLegacyBridgeError.corruptReceipt
                }
            }
            return receipt
        }

        let source: NoteSnapshot?
        switch await NoteFileStorage(directory: legacyDirectory).load() {
        case .firstLaunch:
            source = nil
        case let .current(snapshot):
            source = snapshot
        case .recoveryRequired:
            throw NotebookLegacyBridgeError.sourceNeedsRecovery
        case .blocked:
            throw NotebookLegacyBridgeError.sourceUnavailable
        }
        let receipt = Receipt(
            legacyScope: legacyScope,
            notebookScope: notebookScope,
            source: source
        )
        try SyncFileIO.replace(JSONEncoder().encode(receipt), at: receiptURL)
        return receipt
    }

    private func prepareBridgeStorage(
        _ storage: NoteFileStorage,
        receipt: Receipt
    ) async throws {
        switch await storage.load() {
        case .firstLaunch:
            if let source = receipt.source { try await storage.save(source) }
        case let .current(snapshot):
            guard let source = receipt.source else { return }
            do {
                let document = try NoteDocument(snapshot: snapshot)
                guard snapshot.noteID == source.noteID,
                      source.heads.isSubset(of: document.historyHeads) else {
                    throw NotebookLegacyBridgeError.bridgeIdentityConflict
                }
            } catch let error as NotebookLegacyBridgeError {
                throw error
            } catch {
                throw NotebookLegacyBridgeError.bridgeIdentityConflict
            }
        case .recoveryRequired:
            throw NotebookLegacyBridgeError.bridgeNeedsRecovery
        case .blocked:
            throw NotebookLegacyBridgeError.bridgeUnavailable
        }
    }

    private func recover(
        _ storage: NoteFileStorage,
        unavailable: NotebookLegacyBridgeError
    ) async throws -> NoteSnapshot {
        guard !synchronizing else {
            throw NotebookLegacyBridgeError.operationInProgress
        }
        synchronizing = true
        defer { synchronizing = false }
        switch await storage.load() {
        case .current(let snapshot): return snapshot
        case .recoveryRequired(let recovery):
            return try await storage.recover(recovery)
        case .firstLaunch, .blocked: throw unavailable
        }
    }
}
