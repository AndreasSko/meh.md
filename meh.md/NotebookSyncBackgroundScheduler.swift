#if os(iOS)
import BackgroundTasks
import Foundation
import NoteCore

@MainActor
enum NotebookSyncBackgroundScheduler {
    private static var identifier: String {
        (Bundle.main.bundleIdentifier ?? "de.andreas-sk.meh-md") + ".notebook-sync"
    }
    private static let eligibilityKey = "notebookSyncBackgroundEligibility"
    private static var isRegistered = false
    private static var candidate: (date: Date, hasLocalChanges: Bool)?
    private static var submission: Task<Void, Never>?

    static func register() {
        #if ICLOUD_ENABLED && !NOTEBOOK_CLOUD_UI_LAB
        isRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier, using: .main, launchHandler: handle
        )
        if !isRegistered {
            NotebookWorkspace.shared.syncEventLog.record("background sync registration failed")
        }
        #endif
    }

    @discardableResult
    static func schedule(hasLocalChanges: Bool = false) -> Task<Void, Never>? {
        guard isRegistered else { return nil }
        let workspace = NotebookWorkspace.shared
        let scheduler = BGTaskScheduler.shared
        guard workspace.allowsScheduledBackgroundSync else {
            candidate = nil
            scheduler.cancel(taskRequestWithIdentifier: identifier)
            return nil
        }

        let date = Date().addingTimeInterval(hasLocalChanges ? 15 * 60 : 60 * 60)
        if candidate.map({ date < $0.date }) ?? true {
            candidate = (date, hasLocalChanges)
        }
        if let submission { return submission }
        let work = Task {
            defer { submission = nil }
            while candidate != nil {
                let pending = await scheduler.pendingTaskRequests()
                    .first { $0.identifier == identifier }
                guard let request = candidate, workspace.allowsScheduledBackgroundSync else {
                    return
                }
                candidate = nil
                let earliest = max(request.date, workspace.syncRetryNotBefore ?? request.date)
                if let pending, (pending.earliestBeginDate ?? .distantPast) <= earliest {
                    continue
                }
                let refresh = BGAppRefreshTaskRequest(identifier: identifier)
                refresh.earliestBeginDate = earliest
                let counts = ["eligible_at_unix_seconds": Int(earliest.timeIntervalSince1970),
                              "saved_content": request.hasLocalChanges ? 1 : 0]
                do {
                    try await scheduler.submitTaskRequest(refresh)
                    guard workspace.allowsScheduledBackgroundSync else {
                        scheduler.cancel(taskRequestWithIdentifier: identifier)
                        return
                    }
                    UserDefaults.standard.set(earliest, forKey: eligibilityKey)
                    workspace.syncEventLog.record("background sync requested", counts: counts)
                } catch {
                    workspace.syncEventLog.record(
                        "background sync request failed: " + NotebookSyncEventLog.errorCode(error),
                        counts: counts
                    )
                }
            }
        }
        submission = work
        return work
    }

    private nonisolated static func handle(_ task: BGTask) {
        let completion = NotebookBackgroundTaskCompletion(task: task)
        task.expirationHandler = {
            guard completion.expire() else { return }
            Task { @MainActor in
                let log = NotebookWorkspace.shared.syncEventLog
                log.record("background sync expired")
                await log.flush()
            }
        }
        let work = Task { @MainActor in
            guard !Task.isCancelled else { return }
            let workspace = NotebookWorkspace.shared
            let log = workspace.syncEventLog
            let started = Date()
            let elapsed = ContinuousClock.now
            let eligible = UserDefaults.standard.object(forKey: eligibilityKey) as? Date
            log.record("background sync started", counts: eligible.map {
                ["seconds_since_eligible": Int(started.timeIntervalSince($0))]
            } ?? [:])
            // Schedule a successor even if this pass expires.
            let next = schedule()
            let result = await workspace.runScheduledBackgroundSync()
            guard !Task.isCancelled else { return }
            log.record("background sync finished: " + result.rawValue, counts: [
                "duration_ms": Int(elapsed.duration(to: .now) / .milliseconds(1))
            ])
            if result == .pending {
                await schedule(hasLocalChanges: true)?.value
            } else {
                await next?.value
            }
            await log.flush()
            completion.finish(success: result != .failed && result != .cancelled)
        }
        completion.setWork(work)
    }
}
#endif
