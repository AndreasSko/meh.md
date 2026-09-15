import Foundation
import Observation

struct NoteSaveSchedulingPolicy: Sendable {
    let idleDelay: Duration
    let maximumDelay: Duration
    let now: @MainActor @Sendable () -> UInt64
    let sleep: @Sendable (Duration) async -> Void

    static let live = NoteSaveSchedulingPolicy(
        idleDelay: .seconds(1),
        maximumDelay: .seconds(5),
        now: { DispatchTime.now().uptimeNanoseconds },
        sleep: { delay in
            try? await Task.sleep(for: delay)
        }
    )

    static let immediate = NoteSaveSchedulingPolicy(
        idleDelay: .zero,
        maximumDelay: .zero,
        now: { 0 },
        sleep: { _ in }
    )
}

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
    /// Opaque, session-scoped editor token. Never persist it as note content.
    public private(set) var editorRevision: Data?

    public var currentSnapshot: NoteSnapshot? {
        guard let document, let editorRevision else { return nil }
        if cachedSnapshot?.revision == editorRevision {
            return cachedSnapshot?.snapshot
        }
        let snapshot = document.snapshot()
        cachedSnapshot = (editorRevision, snapshot)
        return snapshot
    }

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
    @ObservationIgnored private let saveScheduling: NoteSaveSchedulingPolicy
    @ObservationIgnored private var document: NoteDocument?
    @ObservationIgnored private var editorIdentity = Data()
    @ObservationIgnored private var cachedSnapshot: (
        revision: Data, snapshot: NoteSnapshot
    )?
    @ObservationIgnored private var persistedHeads: Set<String>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var delayedSaveTask: Task<Void, Never>?
    @ObservationIgnored private var scheduledSaveID = 0
    @ObservationIgnored private var pendingSince: UInt64?
    @ObservationIgnored private var loadStarted = false
    @ObservationIgnored private var loadInFlight = false
    @ObservationIgnored private var recoveryInFlight = false
    @ObservationIgnored private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    public init(storage: any NoteStorage) {
        self.storage = storage
        saveScheduling = .live
    }

    init(
        storage: any NoteStorage,
        saveScheduling: NoteSaveSchedulingPolicy = .live
    ) {
        self.storage = storage
        self.saveScheduling = saveScheduling
    }

    public func load() async {
        guard !loadInFlight,
            document == nil,
            saveTask == nil,
            delayedSaveTask == nil
        else { return }
        switch status {
        case .loading where !loadStarted, .blocked, .loadFailed:
            break
        case .loading, .saved, .saving, .saveFailed, .recoveryRequired:
            return
        }

        loadStarted = true
        loadInFlight = true
        defer {
            loadInFlight = false
            resumeOperationWaiters()
        }
        status = .loading
        document = nil
        editorRevision = nil
        cachedSnapshot = nil
        persistedHeads = nil
        persistedSnapshot = nil
        cancelDelayedSave()
        recoveryErrorMessage = nil

        switch await storage.load() {
        case .firstLaunch:
            do {
                let document = try NoteDocument()
                try install(document, persistedHeads: nil)
                queueSave(immediately: true)
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
        cancelDelayedSave()
    }

    /// Permanent deletion disables new edits first, then waits for the one
    /// serialized writer that may already have captured a snapshot.
    func waitForPendingSave() async {
        while loadInFlight || recoveryInFlight || saveTask != nil {
            if let task = saveTask {
                await task.value
            } else {
                await withCheckedContinuation { operationWaiters.append($0) }
            }
        }
    }

    func discardPermanentlyDeletedContent() {
        guard isPermanentlyDeleted, !loadInFlight, !recoveryInFlight,
            saveTask == nil, delayedSaveTask == nil
        else { return }
        document = nil
        editorRevision = nil
        cachedSnapshot = nil
        persistedHeads = nil
        persistedSnapshot = nil
        text = ""
    }

    public func replaceText(
        in range: NSRange,
        with replacement: String
    ) throws {
        guard isEditingEnabled, let document else { return }
        let heads = document.heads
        try document.replaceUTF16(range: range, with: replacement)
        guard document.heads != heads else { return }
        text = try document.text
        queueSave()
    }

    public func replaceAll(with replacement: String) throws {
        guard isEditingEnabled, let document else { return }
        guard !replacement.utf8.elementsEqual(text.utf8) else { return }
        try document.replaceAll(with: replacement)
        text = try document.text
        queueSave()
    }

    public func retrySave() {
        guard isEditingEnabled, document != nil else { return }
        queueSave(immediately: true)
    }

    /// Apply native edits to the revision the editor actually displayed.
    /// This preserves remote changes received while the native view was
    /// composing marked text or waiting for a SwiftUI update.
    @discardableResult
    public func commitEditorText(
        _ replacement: String,
        basedOn revision: Data
    ) throws -> Data {
        guard isEditingEnabled, let document else {
            throw SyncError.localSaveRequired
        }
        guard !editorIdentity.isEmpty, revision.starts(with: editorIdentity) else {
            throw SyncError.invalidRecord
        }
        let heads = document.editorHeads
        try document.applyEditorText(
            replacement, basedOn: Data(revision.dropFirst(editorIdentity.count))
        )
        guard document.editorHeads != heads else {
            return editorIdentity + heads
        }
        text = try document.text
        queueSave()
        return editorIdentity + document.editorHeads
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
        queueSave()
    }

    /// Await this session's serialized save loop without creating another
    /// writer. A failed local save never acknowledges a remote download.
    public func flush() async throws {
        queueSave(immediately: true)
        while let task = saveTask { await task.value }
        guard case .saved = status,
              let persistedHeads, document?.heads == persistedHeads else {
            throw SyncError.localSaveRequired
        }
    }

    public func recoverFromPrevious() async {
        guard !isPermanentlyDeleted,
            !recoveryInFlight,
            case let .recoveryRequired(recovery) = status
        else { return }
        recoveryInFlight = true
        defer {
            recoveryInFlight = false
            resumeOperationWaiters()
        }
        status = .loading
        recoveryErrorMessage = nil
        do {
            let snapshot = try await storage.recover(recovery)
            guard !isPermanentlyDeleted else { return }
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
        editorIdentity = Data(UUID().uuidString.utf8)
        editorRevision = editorIdentity + document.editorHeads
        cachedSnapshot = nil
        self.persistedHeads = persistedHeads
        text = try document.text
    }

    private func queueSave(immediately: Bool = false) {
        if let document, !isPermanentlyDeleted {
            editorRevision = editorIdentity + document.editorHeads
        }
        guard !isPermanentlyDeleted,
            let document,
            document.heads != persistedHeads
        else { return }
        status = .saving
        guard saveTask == nil else { return }
        if immediately {
            cancelDelayedSave()
            startSaveLoop()
            return
        }
        let now = saveScheduling.now()
        if pendingSince == nil { pendingSince = now }
        let started = pendingSince!
        let elapsedNanoseconds = now >= started ? now - started : 0
        let elapsed = Duration.nanoseconds(
            Int64(min(elapsedNanoseconds, UInt64(Int64.max)))
        )
        let delay = min(
            saveScheduling.idleDelay,
            max(.zero, saveScheduling.maximumDelay - elapsed)
        )
        scheduleSave(after: delay)
    }

    private func scheduleSave(after delay: Duration) {
        cancelDelayedTask()
        let id = scheduledSaveID
        delayedSaveTask = Task { [saveScheduling] in
            await saveScheduling.sleep(delay)
            guard !Task.isCancelled else { return }
            self.startScheduledSave(id: id)
        }
    }

    private func startScheduledSave(id: Int) {
        guard id == scheduledSaveID, !isPermanentlyDeleted else { return }
        delayedSaveTask = nil
        startSaveLoop()
    }

    private func startSaveLoop() {
        guard !isPermanentlyDeleted, saveTask == nil else { return }
        pendingSince = nil
        saveTask = Task { await runSaveLoop() }
    }

    private func runSaveLoop() async {
        while !isPermanentlyDeleted,
            let document,
            document.heads != persistedHeads
        {
            guard let snapshot = currentSnapshot else { break }
            do {
                try await storage.save(snapshot)
                persistedHeads = snapshot.heads
                persistedSnapshot = snapshot
                if document.heads == persistedHeads {
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
        resumeOperationWaiters()
    }

    private func cancelDelayedSave() {
        cancelDelayedTask()
        pendingSince = nil
    }

    private func cancelDelayedTask() {
        scheduledSaveID += 1
        delayedSaveTask?.cancel()
        delayedSaveTask = nil
    }

    private func resumeOperationWaiters() {
        let waiters = operationWaiters
        operationWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}
