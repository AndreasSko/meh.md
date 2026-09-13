import Foundation
import Observation

@MainActor
@Observable
public final class NoteSession {
    public enum Status: Equatable, Sendable {
        case loading
        case saved
        case saving
        case saveFailed(message: String)
        case recoveryRequired(NoteRecovery)
        case blocked(NoteLoadFailure)
        case loadFailed(message: String)
    }

    public private(set) var isPermanentlyDeleted = false
    public private(set) var text = ""
    public private(set) var status: Status = .loading
    public private(set) var recoveryErrorMessage: String?
    public private(set) var persistedSnapshot: NoteSnapshot?

    public var currentSnapshot: NoteSnapshot? { document?.snapshot() }

    public var isEditingEnabled: Bool {
        if isPermanentlyDeleted { return false }
        return switch status {
        case .saved, .saving, .saveFailed:
            true
        case .loading, .recoveryRequired, .blocked, .loadFailed:
            false
        }
    }

    @ObservationIgnored private let storage: any NoteStorage
    @ObservationIgnored private var document: NoteDocument?
    @ObservationIgnored private var persistedHeads: Set<String>?
    @ObservationIgnored private var pendingSnapshot: NoteSnapshot?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var loadStarted = false
    @ObservationIgnored private var loadInFlight = false

    public init(storage: any NoteStorage) {
        self.storage = storage
    }

    public func load() async {
        guard !loadInFlight, document == nil, saveTask == nil else { return }
        switch status {
        case .loading where !loadStarted, .blocked, .loadFailed:
            break
        case .loading, .saved, .saving, .saveFailed, .recoveryRequired:
            return
        }

        loadStarted = true
        loadInFlight = true
        defer { loadInFlight = false }
        status = .loading
        document = nil
        persistedHeads = nil
        persistedSnapshot = nil
        pendingSnapshot = nil
        recoveryErrorMessage = nil

        switch await storage.load() {
        case .firstLaunch:
            do {
                let document = try NoteDocument()
                try install(document, persistedHeads: nil)
                queueCurrentSnapshot()
            } catch {
                status = .loadFailed(message: Self.message(for: error))
            }
        case let .current(snapshot):
            do {
                let document = try NoteDocument(snapshot: snapshot)
                try install(document, persistedHeads: snapshot.heads)
                persistedSnapshot = snapshot
                status = .saved
            } catch {
                status = .loadFailed(message: Self.message(for: error))
            }
        case let .recoveryRequired(recovery):
            status = .recoveryRequired(recovery)
        case let .blocked(failure):
            status = .blocked(failure)
        }
    }

    func markPermanentlyDeleted() {
        isPermanentlyDeleted = true
    }

    public func replaceText(
        in range: NSRange,
        with replacement: String
    ) throws {
        guard isEditingEnabled, let document else { return }
        try document.replaceUTF16(range: range, with: replacement)
        text = try document.text
        queueCurrentSnapshot()
    }

    public func replaceAll(with replacement: String) throws {
        guard isEditingEnabled, let document else { return }
        guard !replacement.utf8.elementsEqual(text.utf8) else { return }
        try document.replaceAll(with: replacement)
        text = try document.text
        queueCurrentSnapshot()
    }

    public func retrySave() {
        guard isEditingEnabled, document != nil else { return }
        queueCurrentSnapshot()
    }

    /// Apply native edits to the revision the editor actually displayed.
    /// This preserves remote changes received while the native view was
    /// composing marked text or waiting for a SwiftUI update.
    @discardableResult
    public func commitEditorText(
        _ replacement: String,
        basedOn serializedRevision: Data
    ) throws -> NoteSnapshot {
        guard isEditingEnabled, let document else {
            throw SyncError.localSaveRequired
        }
        let branch = try NoteDocument(serializedData: serializedRevision)
        try branch.replaceAll(with: replacement)
        try document.merge(branch)
        text = try document.text
        queueCurrentSnapshot()
        return document.snapshot()
    }

    /// Remote state always joins the live document, including unsaved typing.
    /// A caller must await flush() before acknowledging download progress.
    public func mergeRemote(_ snapshot: NoteSnapshot) throws {
        guard isEditingEnabled, let document else {
            throw SyncError.localSaveRequired
        }
        let remote = try NoteDocument(snapshot: snapshot)
        guard remote.noteID == document.noteID else {
            throw SyncError.identityConflict
        }
        let before = document.heads
        try document.merge(remote)
        guard document.heads != before else { return }
        text = try document.text
        queueCurrentSnapshot()
    }

    /// Await this session's serialized save loop without creating another
    /// writer. A failed local save never acknowledges a remote download.
    public func flush() async throws {
        while let task = saveTask { await task.value }
        guard case .saved = status,
              let persistedHeads, document?.heads == persistedHeads else {
            throw SyncError.localSaveRequired
        }
    }

    public func recoverFromPrevious() async {
        guard case let .recoveryRequired(recovery) = status else { return }
        status = .loading
        recoveryErrorMessage = nil
        do {
            let snapshot = try await storage.recover(recovery)
            let document = try NoteDocument(snapshot: snapshot)
            try install(document, persistedHeads: snapshot.heads)
            persistedSnapshot = snapshot
            status = .saved
        } catch {
            recoveryErrorMessage = Self.message(for: error)
            status = .recoveryRequired(recovery)
        }
    }

    private func install(
        _ document: NoteDocument,
        persistedHeads: Set<String>?
    ) throws {
        self.document = document
        self.persistedHeads = persistedHeads
        text = try document.text
    }

    private func queueCurrentSnapshot() {
        guard let document else { return }
        pendingSnapshot = document.snapshot()
        status = .saving
        guard saveTask == nil else { return }
        saveTask = Task { await runSaveLoop() }
    }

    private func runSaveLoop() async {
        while let snapshot = pendingSnapshot {
            pendingSnapshot = nil
            do {
                try await storage.save(snapshot)
                persistedHeads = snapshot.heads
                persistedSnapshot = snapshot
                if document?.heads == persistedHeads {
                    status = .saved
                } else {
                    status = .saving
                }
            } catch {
                status = .saveFailed(message: Self.message(for: error))
                break
            }
        }
        saveTask = nil
    }

    private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}
