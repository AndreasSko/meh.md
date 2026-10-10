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
    public private(set) var isEditingSuspended = false
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
        if isPermanentlyDeleted || isEditingSuspended { return false }
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
    @ObservationIgnored private var cachedHistoryReader: (
        heads: Set<String>, reader: NoteHistoryReader
    )?
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
        cachedHistoryReader = nil
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

    func suspendEditingForPendingReset() {
        isEditingSuspended = true
        cancelDelayedSave()
    }

    /// First joining changes catalog ownership, not note identity. Preserve
    /// typing that arrived during the handoff before requiring a restart.
    func suspendEditingForFirstSyncRecovery() {
        queueSave(immediately: true)
        isEditingSuspended = true
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
        cachedHistoryReader = nil
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

    /// Read-only history queries never enter the save loop or record activity.
    public func historyVersions() throws -> [NoteHistoryVersion] {
        guard isEditingEnabled, let document else {
            throw SyncError.localSaveRequired
        }
        return try document.historyVersions()
    }

    /// Reuse one frozen reader while the live note's revision is unchanged.
    /// The reader owns indexing and previews away from the UI actor.
    public func makeHistoryReader() throws -> NoteHistoryReader {
        guard isEditingEnabled, let document else {
            throw SyncError.localSaveRequired
        }
        let heads = document.heads
        if let cachedHistoryReader, cachedHistoryReader.heads == heads {
            return cachedHistoryReader.reader
        }
        let snapshot = currentSnapshot ?? document.snapshot()
        let reader = NoteHistoryReader(snapshot: snapshot)
        cachedHistoryReader = (heads, reader)
        return reader
    }

    /// Compatibility query for callers that need the complete version list.
    public func loadHistoryVersions() async throws -> [NoteHistoryVersion] {
        let reader = try makeHistoryReader()
        for try await update in await reader.updates() {
            try Task.checkCancellation()
            if update.isComplete { return update.versions }
        }
        throw CancellationError()
    }

    public func historicalText(
        for version: NoteHistoryVersion
    ) throws -> String {
        guard isEditingEnabled, let document else {
            throw SyncError.localSaveRequired
        }
        return try document.historicalText(for: version)
    }

    /// Appends selected body text as a new live edit, retaining all history.
    /// The caller must commit editor text and capture current heads before
    /// opening History. A newer local or remote edit rejects the replacement.
    public func restoreHistoryVersion(
        _ version: NoteHistoryVersion,
        expectedHeads: Set<String>
    ) async throws {
        guard isEditingEnabled, let document else {
            throw SyncError.localSaveRequired
        }
        guard document.heads == expectedHeads else {
            throw NoteHistoryError.currentChanged
        }
        let reader = try makeHistoryReader()
        let restoredText: String
        do {
            restoredText = try await reader.historicalText(for: version)
        } catch NoteHistoryError.versionUnavailable {
            // Legacy callers may obtain a version through the synchronous
            // query. Finish that reader's index before requesting its text.
            for try await update in await reader.updates() {
                try Task.checkCancellation()
                if update.isComplete { break }
            }
            restoredText = try await reader.historicalText(for: version)
        }
        try Task.checkCancellation()
        // Reading a frozen preview suspends. A new edit, merge, recovery or
        // reset must be checked against the live document after that await.
        guard isEditingEnabled, let current = self.document,
              current.heads == expectedHeads else {
            throw NoteHistoryError.currentChanged
        }
        try current.restoreHistoricalText(restoredText)
        text = try current.text
        queueSave(immediately: true)
        try await flush()
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
        basedOn revision: Data,
        change: NoteEditorTextChange? = nil
    ) throws -> Data {
        guard isEditingEnabled, let document else {
            throw SyncError.localSaveRequired
        }
        guard !editorIdentity.isEmpty, revision.starts(with: editorIdentity) else {
            throw SyncError.invalidRecord
        }
        let heads = document.editorHeads
        if revision == editorIdentity + heads,
           let change,
           let scalarRange = try? change.validatedScalarRange(
               in: text, resultingIn: replacement
           ) {
            // A validated length-changing replacement cannot be a no-op.
            // Avoid comparing the whole note again for ordinary typing.
            if change.range.length == change.replacement.utf16.count,
               text.utf8.elementsEqual(replacement.utf8) {
                return editorIdentity + heads
            }
            try document.applyValidatedEditorChange(
                change.replacement, scalarRange: scalarRange
            )
            text = replacement
            queueSave()
            return editorIdentity + document.editorHeads
        }
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
        let before = document.heads
        if snapshot.noteID == document.noteID, snapshot.heads == before {
            // These exact bytes were validated on load or produced locally.
            // Claimed heads alone never bypass validation of incoming data.
            if snapshot == persistedSnapshot || snapshot == cachedSnapshot?.snapshot {
                return
            }
        }
        let remote = try NoteDocument(snapshot: snapshot)
        guard remote.noteID == document.noteID else {
            throw SyncError.identityConflict
        }
        // Independently serialized copies can have different bytes while
        // representing the same validated revision. No history scan needed.
        guard remote.heads != before else { return }
        try document.merge(remote)
        guard document.heads != before else { return }
        text = try document.text
        queueSave()
    }

    /// A catalog can arrive before its note body. Install that first body in
    /// the registered session so an open editor observes the durable result.
    /// Other blocked states still require explicit recovery.
    var isWaitingForRemoteBody: Bool {
        guard case let .blocked(failure) = status else { return false }
        return failure.current == .absent && failure.previous == .absent
    }

    func installFirstRemoteBody(_ snapshot: NoteSnapshot) async throws {
        guard isWaitingForRemoteBody, !isPermanentlyDeleted,
              !isEditingSuspended else {
            throw SyncError.localSaveRequired
        }
        let remote = try NoteDocument(snapshot: snapshot)
        let loaded = await storage.load()
        // Catalog installation can make this session terminal while the
        // storage read is suspended. Never revive or write a deleted body.
        guard !isPermanentlyDeleted else { return }
        switch loaded {
        case let .blocked(failure)
        where failure.current == .absent && failure.previous == .absent:
            guard !isEditingSuspended else { throw SyncError.localSaveRequired }
            try await storage.save(snapshot)
            guard !isPermanentlyDeleted else { return }
            guard !isEditingSuspended else { throw SyncError.localSaveRequired }
            try install(remote, persistedHeads: snapshot.heads)
            persistedSnapshot = snapshot
            status = .saved
        case let .current(current):
            guard !isEditingSuspended else { throw SyncError.localSaveRequired }
            // The file may have arrived through another writer since this
            // session observed it missing. Join both validated histories.
            let local = try NoteDocument(snapshot: current)
            try install(local, persistedHeads: current.heads)
            persistedSnapshot = current
            status = .saved
            try mergeRemote(snapshot)
            try await flush()
        default:
            throw SyncError.localSaveRequired
        }
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
        cachedHistoryReader = nil
        editorIdentity = Data(UUID().uuidString.utf8)
        editorRevision = editorIdentity + document.editorHeads
        cachedSnapshot = nil
        self.persistedHeads = persistedHeads
        text = try document.text
    }

    private func queueSave(immediately: Bool = false) {
        guard !isEditingSuspended else { return }
        if let document, !isPermanentlyDeleted {
            editorRevision = editorIdentity + document.editorHeads
            if let cachedHistoryReader,
               cachedHistoryReader.heads != document.heads {
                // An open browser retains its own frozen reader. The session
                // only keeps a reusable reader for its current live revision.
                self.cachedHistoryReader = nil
            }
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
