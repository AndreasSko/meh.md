#if os(iOS)
import BackgroundTasks
import Foundation
import NoteCore

/// Asks iOS to wake the app now and then for a sync pass, so offline edits
/// upload and missed silent pushes are caught without opening the app.
@MainActor
enum NotebookSyncBackgroundScheduler {
    private static var identifier: String {
        (Bundle.main.bundleIdentifier ?? "de.andreas-sk.meh-md") + ".notebook-sync"
    }
    private static var isRegistered = false
    private static let eligibleAtKey = "notebookSyncBackgroundEligibleAt"

    static func register() {
        #if ICLOUD_ENABLED
        guard !isRegistered else { return }
        isRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier, using: .main
        ) { handle($0) }
        #endif
    }

    /// Keeps one request pending. Unsynced edits ask for an earlier wake
    /// than a plain catch-up check, and an earlier pending request is kept,
    /// so frequent app use doesn't push the wake back. iOS decides when it
    /// actually runs.
    static func scheduleNext() {
        guard isRegistered else { return }
        let workspace = NotebookWorkspace.shared
        let scheduler = BGTaskScheduler.shared
        guard workspace.allowsBackgroundSync else {
            scheduler.cancel(taskRequestWithIdentifier: identifier)
            return
        }
        let hasUnsyncedChanges = workspace.sync?.status == .pending
            || workspace.syncFailure != nil
        let delay: TimeInterval = hasUnsyncedChanges ? 15 * 60 : 60 * 60
        let notBefore = workspace.syncRetryNotBefore ?? .distantPast
        let earliest = max(Date().addingTimeInterval(delay), notBefore)
        Task {
            let pending = await scheduler.pendingTaskRequests()
                .first { $0.identifier == identifier }?.earliestBeginDate
            if let pending, pending <= earliest, pending >= notBefore { return }
            let request = BGAppRefreshTaskRequest(identifier: identifier)
            request.earliestBeginDate = earliest
            let counts = ["delay_s": Int(earliest.timeIntervalSinceNow)]
            do {
                try await scheduler.submitTaskRequest(request)
                UserDefaults.standard.set(earliest, forKey: eligibleAtKey)
                workspace.syncEventLog.record("background sync requested", counts: counts)
            } catch {
                workspace.syncEventLog.record(
                    "background sync request failed: " + NotebookSyncEventLog.errorCode(error),
                    counts: counts
                )
            }
        }
    }

    private nonisolated static func handle(_ task: BGTask) {
        let completion = BackgroundTaskCompletion(task: task)
        task.expirationHandler = {
            Task { @MainActor in
                // Log before completing, as iOS may suspend the app right after.
                let log = NotebookWorkspace.shared.syncEventLog
                log.record("background sync expired")
                await log.flush()
                completion.expire()
            }
        }
        let work = Task { @MainActor in
            let workspace = NotebookWorkspace.shared
            let eligibleAt = UserDefaults.standard.object(forKey: eligibleAtKey) as? Date
            workspace.syncEventLog.record("background sync started", counts: eligibleAt.map {
                ["seconds_since_eligible": Int(Date().timeIntervalSince($0))]
            } ?? [:])
            // Ask for the next wake first, in case this one expires. The
            // pass asks again once it knows whether changes are left.
            scheduleNext()
            guard !Task.isCancelled else { return }
            await workspace.syncInBackground()
            guard !Task.isCancelled else { return }
            let failed = workspace.syncFailure != nil
            workspace.syncEventLog.record("background sync finished", counts: [
                "failed": failed ? 1 : 0,
                "pending": workspace.sync?.status == .pending ? 1 : 0,
            ])
            await workspace.syncEventLog.flush()
            completion.finish(success: !failed)
        }
        completion.setWork(work)
    }
}
#endif
