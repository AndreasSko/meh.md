import CryptoKit
import Foundation
import Network
import NoteCore
import Observation
#if os(iOS)
import UIKit
#endif

@MainActor
@Observable
final class NotebookWorkspace {
    static let shared = NotebookWorkspace(preview: NotebookWorkspace.isPreviewEnabled)

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
        #if DEBUG && !ICLOUD_ENABLED
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
    @ObservationIgnored private var scheduledRefresh: Task<Void, Never>?
    @ObservationIgnored private var syncSchedule = NotebookSyncSchedule()
    @ObservationIgnored private let syncClock = ContinuousClock()
    @ObservationIgnored private let syncClockOrigin = ContinuousClock.now
    @ObservationIgnored private var pendingSyncTrigger = "automatic refresh"

    @ObservationIgnored private var cloudActivityTask: Task<Void, Never>?
    @ObservationIgnored private var connectivityMonitor: NWPathMonitor?
    @ObservationIgnored private var previousConnectivity: NWPath.Status?
    @ObservationIgnored private var retryPolicy = NotebookSyncRetryPolicy()
    private var plannedRetryDate: Date?
    private var isForeground = true
    private(set) var notificationRegistrationError: String?
    #if os(iOS)
    private var backgroundExecution: UIBackgroundTaskIdentifier = .invalid
    #endif
    private var needsAnotherRefresh = false
    private var needsImmediateRefresh = false
    private var needsManualRefresh = false
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
        case .cloud:
            #if ICLOUD_DEV
            "iCloud Dev"
            #else
            "iCloud"
            #endif
        case .development(_, let name): "Local sync · \(name)"
        case .preview: "Notebook preview · Local only"
        default: "On this device"
        }
    }

    init(preview: Bool = false) {
        let environment = ProcessInfo.processInfo.environment
        automaticSync = environment["MEH_SYNC_AUTOMATIC"] != "0"
        var mode: Mode = preview ? .preview : .local
        #if ICLOUD_ENABLED
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
            #if DEBUG
            let previewRun = preview ? environment["MEH_NOTEBOOK_PREVIEW_RUN"] : nil
            let validPreviewRun = previewRun.flatMap { value in
                value.range(
                    of: "^[A-Za-z0-9_-]{1,64}$",
                    options: .regularExpression
                ) == nil ? nil : value
            }
            #else
            let validPreviewRun: String? = nil
            #endif
            if let validPreviewRun {
                directory = support.appending(
                    path: "NotebookPreviewTests/\(validPreviewRun)"
                )
                documentsDirectory = URL.documentsDirectory.appending(
                    path: "NotebookPreviewTests/\(validPreviewRun)"
                )
            } else {
                directory = support.appending(
                    path: preview ? "NotebookPreview" : "Notebook"
                )
                documentsDirectory = URL.documentsDirectory
            }
        }
    }

    /// Deterministic app-model tests use the same scheduler with an isolated
    /// replica and transport, without a signed app or CloudKit account.
    init(directory: URL, documentsDirectory: URL, transport: any SyncTransport,
         automaticSync: Bool, mode: Mode? = nil) {
        self.directory = directory
        self.documentsDirectory = documentsDirectory
        self.automaticSync = automaticSync
        self.mode = mode ?? .development(URL(string: "http://127.0.0.1")!, "model-test")
        notebookTransport = transport
    }

    func start() async {
        guard !isLoading else { return }
        isLoading = true

        errorMessage = nil
        recoveryAction = nil
        defer { isLoading = false }
        do {
            // Run before opening documents or starting any sync/save tasks.
            if replica == nil, UserDefaults.standard.bool(forKey: "meh.md.resetLocalStorage") {
                let manager = FileManager.default
                let paths = [directory,
                             documentsDirectory.appending(path: "Notebook Copies"),
                             URL.applicationSupportDirectory.appending(path: "Notes")]
                for path in paths where manager.fileExists(atPath: path.path) {
                    try manager.removeItem(at: path)
                }
                // Keep the request until every removal succeeds, so failures
                // block startup and can be retried without opening partial data.
                if let identifier = Bundle.main.bundleIdentifier {
                    UserDefaults.standard.removePersistentDomain(forName: identifier)
                }
                UserDefaults.standard.removeObject(forKey: "meh.md.resetLocalStorage")
                UserDefaults.standard.synchronize()
            }
            if usesSync { syncEventLog.record("workspace opening") }
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
            startConnectivityMonitoring()
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

    private var syncTime: Duration { syncClockOrigin.duration(to: syncClock.now) }

    func noteDidEdit() {
        guard automaticSync, usesSync else { return }
        syncSchedule.noteEdited(at: syncTime)
        armScheduledRefresh()
    }

    func requestAutomaticRefresh(trigger: String) {
        guard automaticSync else { return }
        scheduleRefresh(trigger: trigger)
    }

    func contentDidSave(trigger: String = "saved content or catalog update") {
        guard !isPreview else { return }
        scheduleRefresh(trigger: trigger)
    }

    private func scheduleRefresh(trigger: String, notBefore: Date? = nil) {
        pendingSyncTrigger = trigger
        syncSchedule.request(at: syncTime)
        armScheduledRefresh(notBefore: notBefore)
    }

    private func armScheduledRefresh(notBefore: Date? = nil) {
        guard let policyDelay = syncSchedule.delay(at: syncTime) else { return }
        scheduledRefresh?.cancel()
        guard isForeground || !usesSync || !automaticSync else { return }
        let retryDelay = Duration.seconds(max(
            0, (notBefore ?? syncRetryNotBefore ?? Date()).timeIntervalSinceNow
        ))
        let delay = max(policyDelay, retryDelay)
        scheduledRefresh = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: delay) }
            catch { return }
            guard let self, !Task.isCancelled else { return }
            scheduledRefresh = nil
            if usesSync && !automaticSync {
                syncSchedule.clearPending()
                await publishCopies()
            } else { await refresh(trigger: pendingSyncTrigger) }
        }
    }

    func sceneActivityChanged(isActive: Bool) {
        let changed = isForeground != isActive
        isForeground = isActive
        guard automaticSync, changed else { return }
        if isActive {
            requestAutomaticRefresh(trigger: "foreground activation")
        } else {
            // The engine owns background scheduling. App retry timers resume
            // at the next activation; their durable pending work stays saved.
            scheduledRefresh?.cancel()
            scheduledRefresh = nil
            if usesSync {
                Task {
                    do { try await replica?.flushOpenNotes() }
                    catch { errorMessage = error.localizedDescription; return }
                    await refresh(trigger: "background transition")
                }
            }
        }
    }

    func remoteNotificationRegistrationDidSucceed() {
        notificationRegistrationError = nil
        syncEventLog.record("remote notification registration succeeded")
    }

    func remoteNotificationRegistrationDidFail(_ error: any Error) {
        notificationRegistrationError = "Automatic change notifications are unavailable. "
            + "Opening the app or using Sync Now still checks for changes."
        syncEventLog.record("remote notification registration failed: "
            + NotebookSyncEventLog.errorCode(error))
    }

    private func startConnectivityMonitoring() {
        guard usesSync, automaticSync, connectivityMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let status = path.status
            Task { @MainActor in
                guard let self else { return }
                let previous = self.previousConnectivity
                self.previousConnectivity = status
                guard status == .satisfied, previous != nil, previous != .satisfied else { return }
                self.syncEventLog.record("network connection restored")
                if self.isForeground { self.scheduleRefresh(trigger: "network restored") }
            }
        }
        monitor.start(queue: DispatchQueue(label: "meh.notebook.connectivity"))
        connectivityMonitor = monitor
    }

    func refresh(
        whileLoading: Bool = false, manual: Bool = false, trigger: String = "recovery"
    ) async {
        guard whileLoading || !isLoading else { return }
        guard let replica else { return }
        if !manual, let deadline = syncRetryNotBefore, deadline > Date() {
            if isForeground { scheduleRefresh(trigger: trigger, notBefore: deadline) }
            return
        }
        guard !isRefreshing else {
            if manual { showSyncCheck = true }
            if usesSync { syncEventLog.record("refresh coalesced: " + trigger) }
            needsAnotherRefresh = true
            needsImmediateRefresh = needsImmediateRefresh || manual || !isForeground
            needsManualRefresh = needsManualRefresh || manual
            return
        }
        scheduledRefresh?.cancel()
        scheduledRefresh = nil
        syncSchedule.clearPending()
        plannedRetryDate = nil
        isRefreshing = true
        // The app may enter the background after this exchange starts, so
        // acquire the lease for every refresh that owns the exchange.
        beginBackgroundExecutionIfNeeded()
        var failure: (any Error)?
        defer {
            endBackgroundExecution()
            isRefreshing = false
            if needsAnotherRefresh {
                needsAnotherRefresh = false
                if needsImmediateRefresh {
                    let manual = needsManualRefresh
                    needsImmediateRefresh = false
                    needsManualRefresh = false
                    Task {
                        await refresh(manual: manual, trigger: "coalesced follow-up")
                    }
                } else {
                    contentDidSave(trigger: "coalesced follow-up")
                }
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
                failure = coordinator.lastError
                if case .exchanged(let date) = coordinator.status {
                    lastSuccessfulSync = date
                }
                hasBinding = (try? coordinator.hasDurableBinding()) == true
                if case .failed(let message) = coordinator.status {
                    if !hasBinding { errorMessage = message }
                } else { errorMessage = nil }
            } catch {
                failure = error
                syncEventLog.record("sync setup failed: " + NotebookSyncEventLog.errorCode(error))
                syncSetupError = error.localizedDescription
                setRecoveryAction(for: error)
                if !hasBinding { errorMessage = error.localizedDescription }
            }
            await updateRetryDeadline()
            if let failure {
                plannedRetryDate = retryPolicy.retryDate(
                    for: failure, now: Date(), serverNotBefore: syncRetryNotBefore)
                if let deadline = plannedRetryDate {
                    syncRetryNotBefore = deadline
                    if automaticSync, isForeground {
                        scheduleRefresh(trigger: "scheduled retry", notBefore: deadline)
                    }
                }
            } else {
                retryPolicy.reset()
                if automaticSync, sync?.status == .pending { needsAnotherRefresh = true }
            }
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

    private func beginBackgroundExecutionIfNeeded() {
        #if os(iOS)
        guard backgroundExecution == .invalid else { return }
        backgroundExecution = UIApplication.shared.beginBackgroundTask(
            withName: "Save notebook sync progress"
        ) { [weak self] in
            Task { @MainActor in self?.endBackgroundExecution() }
        }
        #endif
    }

    private func endBackgroundExecution() {
        #if os(iOS)
        guard backgroundExecution != .invalid else { return }
        let identifier = backgroundExecution
        backgroundExecution = .invalid
        UIApplication.shared.endBackgroundTask(identifier)
        #endif
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
        let deadline = [notebook, plannedRetryDate].compactMap { $0 }
            .filter { $0 > Date() }.max()
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
                stateDirectory: directory.appending(path: "CloudKit"),
                automaticallySync: automaticSync
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
        if automaticSync, let cloud = notebookTransport as? CloudKitSyncTransport {
            cloudActivityTask = Task { @MainActor [weak self] in
                for await activity in cloud.activity {
                    guard !Task.isCancelled, let self else { return }
                    await self.receiveCloudActivity(activity)
                }
            }
        }
    }

    private(set) var searchScopeGeneration = 0

    func receiveCloudActivity(_ activity: CloudKitSyncActivity) async {
        switch activity {
        case .remoteChanges(let records, let deletions, let reason):
            syncEventLog.record("cloud \(reason.rawValue) changes delivered", counts: [
                "records": records, "deletions": deletions])
        case .uploadsAcknowledged(let count):
            syncEventLog.record("cloud background uploads acknowledged",
                                counts: ["records": count])
        case .accountChanged:
            searchScopeGeneration += 1
            syncEventLog.record("cloud account changed")
        case .failed(let message):
            syncEventLog.record("cloud automatic operation failed")
            syncSetupError = message
            await updateRetryDeadline()
            // The engine owns retrying its scheduled failures. Echoing a
            // failed fetch into another exchange can loop permanently.
            return
        }
        // AsyncStream delivery never awaits the CK delegate. This serialized
        // exchange applies the durable inbox to editors.
        guard automaticSync else { return }
        if isForeground {
            requestAutomaticRefresh(trigger: "cloud activity")
        } else {
            await refresh(trigger: "cloud activity")
        }
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
            guard let catalog = replica.catalogSnapshot else { return }
            let placements = replica.placements
            let notes = try await replica.persistedNoteSnapshots()
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
