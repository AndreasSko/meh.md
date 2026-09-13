import CryptoKit
import Foundation
import NoteCore
import Observation

@MainActor
@Observable
final class NotebookWorkspace {
    struct RecoveryAction: Equatable {
        fileprivate enum Kind: Equatable {
            case catalog
        }

        let title: String
        let details: String
        fileprivate let kind: Kind
    }

    enum Mode {
        case local, preview, cloud
        case development(URL, String)
        case invalid
    }

    static var isPreviewEnabled: Bool {
        #if DEBUG && !ICLOUD_DEV
        let environment = ProcessInfo.processInfo.environment
        return environment["MEH_NOTEBOOK_PREVIEW"] == "1"
            && environment["MEH_SYNC_URL"] == nil
            && environment["MEH_SYNC_CLOUDKIT"] != "1"
        #else
        false
        #endif
    }

    private(set) var replica: NotebookReplica?
    private(set) var sync: NotebookSyncCoordinator?
    private(set) var errorMessage: String?
    private(set) var syncSetupError: String?
    private(set) var copyError: String?
    private(set) var copiesURL: URL?
    private(set) var isLoading = false
    private(set) var isRefreshing = false
    private(set) var isSyncing = false
    private(set) var showSyncCheck = false
    private(set) var syncRetryNotBefore: Date?
    private(set) var lastSuccessfulSync: Date?
    @ObservationIgnored lazy var syncEventLog = NotebookSyncEventLog(directory: directory)
    private var syncMonitor: Task<Void, Never>?
    private var slowSyncIndicator: Task<Void, Never>?
    private(set) var recoveryAction: RecoveryAction?
    let automaticSync: Bool
    let mode: Mode
    let directory: URL
    private let documentsDirectory: URL
    private var notebookTransport: (any SyncTransport)?
    private var publisher: NotebookMarkdownPublisher?
    private var scheduledRefresh: Task<Void, Never>?
    private var needsAnotherRefresh = false
    private var isPublishingCopies = false
    private var needsAnotherCopyPublication = false

    var isPreview: Bool { if case .preview = mode { true } else { false } }
    var catalogRecoveryAvailable: Bool {
        recoveryAction?.kind == .catalog
    }
    var usesSync: Bool {
        switch mode {
        case .cloud, .development: true
        default: false
        }
    }
    var label: String {
        switch mode {
        case .cloud: "iCloud Dev"
        case .development(_, let name): "Local sync · \(name)"
        case .preview: "Notebook preview · Local only"
        default: "On this device"
        }
    }

    init(preview: Bool = false) {
        let environment = ProcessInfo.processInfo.environment
        automaticSync = environment["MEH_SYNC_AUTOMATIC"] != "0"
        var mode: Mode = preview ? .preview : .local
        #if ICLOUD_DEV
        mode = .cloud
        #elseif DEBUG
        if !preview, let endpoint = environment["MEH_SYNC_URL"] {
            if let url = URL(string: endpoint),
               let name = environment["MEH_SYNC_WORKSPACE"],
               name.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil {
                mode = .development(url, name)
            } else { mode = .invalid }
        } else if !preview, environment["MEH_SYNC_CLOUDKIT"] == "1" {
            mode = .cloud
        }
        #endif
        self.mode = mode
        let support = URL.applicationSupportDirectory
        if case .development(let endpoint, let name) = mode {
            // Keep the established on-disk workspace key while the transport
            // itself uses only the notebook protocol below.
            let workspaceScope = endpoint.absoluteString.trimmingCharacters(
                in: CharacterSet(charactersIn: "/")
            ) + "#" + name
            let key = SHA256.hash(data: Data(workspaceScope.utf8)).map {
                String(format: "%02x", $0)
            }.joined()
            let root = support.appending(path: "SyncWorkspaces/\(key)")
            directory = root.appending(path: "Notebook")
            documentsDirectory = URL.documentsDirectory.appending(path: "SyncWorkspaces/\(name)")
        } else {
            directory = support.appending(path: preview ? "NotebookPreview" : "Notebook")
            documentsDirectory = URL.documentsDirectory
        }
    }

    func start() async {
        guard !isLoading else { return }
        isLoading = true
        if usesSync { syncEventLog.record("workspace opening") }
        errorMessage = nil
        recoveryAction = nil
        defer { isLoading = false }
        do {
            if case .invalid = mode {
                throw SyncError.unavailable("Set a valid local sync URL and workspace name.")
            }
            if replica == nil {
                let loaded = NotebookReplica(directory: directory)
                try await loaded.load()
                if !usesSync, loaded.catalogSnapshot == nil {
                    try await loaded.createLocalNotebook()
                }
                // Existing catalogs are visible before account discovery or
                // any network request, so offline reopening remains useful.
                replica = loaded
            }
            await refresh(whileLoading: true, trigger: "startup")
        } catch {
            setRecoveryAction(for: error)
            errorMessage = error.localizedDescription
        }
    }

    func recoverCatalog() async {
        await recover(.catalog)
    }

    func recoverPendingIssue() async {
        guard let recoveryAction else { return }
        await recover(recoveryAction.kind)
    }

    private func recover(_ kind: RecoveryAction.Kind) async {
        guard !isLoading, !isRefreshing else { return }
        // Claim activation ownership before the first suspension so Start and
        // recovery cannot concurrently mutate the same durable files.
        isLoading = true
        do {
            switch kind {
            case .catalog:
                let recovering = replica ?? NotebookReplica(directory: directory)
                try await recovering.recoverCatalogFromPrevious()
                replica = recovering
            }
            recoveryAction = nil
            errorMessage = nil
            isLoading = false
            await refresh()
        } catch {
            isLoading = false
            setRecoveryAction(for: error)
            errorMessage = error.localizedDescription
        }
    }

    func contentDidSave(trigger: String = "saved content or catalog update") {
        guard !isPreview else { return }
        scheduledRefresh?.cancel()
        scheduledRefresh = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(750)) }
            catch { return }
            // Once work starts, later edits schedule a follow-up instead of
            // cancelling an exchange or atomic Markdown publication in flight.
            scheduledRefresh = nil
            if usesSync && !automaticSync {
                await publishCopies()
            } else { await refresh(trigger: trigger) }
        }
    }

    func refresh(
        whileLoading: Bool = false, manual: Bool = false, trigger: String = "recovery"
    ) async {
        guard whileLoading || !isLoading else { return }
        guard let replica else { return }
        guard !isRefreshing else {
            if manual { showSyncCheck = true }
            if usesSync { syncEventLog.record("refresh coalesced: " + trigger) }
            needsAnotherRefresh = true
            return
        }
        isRefreshing = true
        defer {
            isRefreshing = false
            if needsAnotherRefresh {
                needsAnotherRefresh = false
                contentDidSave(trigger: "coalesced follow-up")
            }
        }
        if usesSync {
            syncEventLog.record("refresh started: " + (manual ? "manual" : trigger))
            let refreshStarted = Date()
            beginSyncPresentation(manual: manual)
            var hasBinding = false
            do {
                syncEventLog.record("notebook transport preparing")
                try await prepareNotebookTransport()
                syncEventLog.record("notebook transport ready")
                guard let notebookTransport else {
                    throw SyncError.unavailable(
                        "Notebook sync setup has not completed."
                    )
                }
                let coordinator = sync ?? NotebookSyncCoordinator(
                    replica: replica,
                    transport: notebookTransport,
                    diagnosticLog: syncEventLog
                )
                sync = coordinator
                hasBinding = try coordinator.hasDurableBinding()
                syncSetupError = nil
                await coordinator.synchronize()
                if case .exchanged(let date) = coordinator.status {
                    lastSuccessfulSync = date
                }
                hasBinding = (try? coordinator.hasDurableBinding()) == true
                if case .failed(let message) = coordinator.status {
                    if !hasBinding { errorMessage = message }
                } else { errorMessage = nil }
            } catch {
                syncEventLog.record("sync setup failed: " + NotebookSyncEventLog.errorCode(error))
                syncSetupError = error.localizedDescription
                setRecoveryAction(for: error)
                if !hasBinding { errorMessage = error.localizedDescription }
            }
            await updateRetryDeadline()
            endSyncPresentation()
            syncEventLog.record("refresh ended", counts: [
                "duration_ms": Int(Date().timeIntervalSince(refreshStarted) * 1_000)
            ])
        }
        do { try await replica.cleanupDeletedContent() }
        catch {
            if usesSync {
                syncEventLog.record("local deletion cleanup failed: "
                    + NotebookSyncEventLog.errorCode(error))
            }
        }
        await publishCopies()
    }

    private func beginSyncPresentation(manual: Bool) {
        isSyncing = true
        showSyncCheck = manual
        slowSyncIndicator?.cancel()
        slowSyncIndicator = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            if isSyncing { showSyncCheck = true }
        }
        syncMonitor?.cancel()
        syncMonitor = Task { @MainActor in
            while !Task.isCancelled, isSyncing {
                await updateRetryDeadline()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private func endSyncPresentation() {
        slowSyncIndicator?.cancel()
        syncMonitor?.cancel()
        isSyncing = false
        showSyncCheck = false
    }

    private func updateRetryDeadline() async {
        var notebook = await notebookTransport?.retryNotBefore()
        if case .cloud = mode {
            if notebookTransport == nil {
                notebook = try? CloudKitSyncTransport.persistedRetryNotBefore(
                    stateDirectory: directory.appending(path: "CloudKit"))
            }
        }
        let deadline = notebook.flatMap { $0 > Date() ? $0 : nil }
        if deadline != syncRetryNotBefore {
            if let deadline {
                syncEventLog.record("retry cooldown observed", counts: [
                    "remaining_seconds": max(0, Int(ceil(deadline.timeIntervalSinceNow)))
                ])
            } else if syncRetryNotBefore != nil {
                syncEventLog.record("retry cooldown elapsed")
            }
        }
        syncRetryNotBefore = deadline
    }

    private func prepareNotebookTransport() async throws {
        guard notebookTransport == nil else { return }
        let transport: any SyncTransport
        switch mode {
        case .cloud:
            transport = try await CloudKitSyncTransport.makeNotebook(
                containerIdentifier: "iCloud.de.andreas-sk.meh-md",
                stateDirectory: directory.appending(path: "CloudKit")
            )
        case .development(let endpoint, let name):
            transport = LocalSyncTransport(
                baseURL: endpoint,
                workspace: name,
                protocolVersion: 2
            )
        default: return
        }
        notebookTransport = unavailableWhenRequested(transport)
    }

    private func unavailableWhenRequested(
        _ transport: any SyncTransport
    ) -> any SyncTransport {
        #if DEBUG
        if ProcessInfo.processInfo.environment["MEH_SYNC_SIMULATE_OFFLINE"] == "1" {
            return UnavailableDevelopmentTransport(scope: transport.scope)
        }
        #endif
        return transport
    }

    private func setRecoveryAction(for error: Error) {
        guard error as? NotebookReplicaError == .catalogNeedsRecovery else {
            return
        }
        recoveryAction = RecoveryAction(
            title: "Recover Notebook Catalog",
            details: "Restore the previous saved catalog. The damaged "
                + "current catalog will be kept for diagnosis.",
            kind: .catalog
        )
    }

    private func publishCopies() async {
        guard !isPreview, replica != nil else { return }
        guard !isPublishingCopies else {
            needsAnotherCopyPublication = true
            return
        }
        isPublishingCopies = true
        defer { isPublishingCopies = false }
        repeat {
            needsAnotherCopyPublication = false
            await publishCopiesOnce()
        } while needsAnotherCopyPublication
    }

    private func publishCopiesOnce() async {
        guard let replica else { return }
        do {
            let output = documentsDirectory.appending(path: "Notebook Copies")
            let publisher = self.publisher ?? NotebookMarkdownPublisher(directory: output)
            self.publisher = publisher
            let notes = try await replica.persistedNoteSnapshots()
            guard let catalog = replica.catalogSnapshot else { return }
            let placements = replica.placements
            try await publisher.publish(
                catalog: catalog,
                placements: placements,
                notes: notes
            )
            copiesURL = output.appending(path: "Markdown")
            copyError = nil
        } catch { copyError = error.localizedDescription }
    }
}
