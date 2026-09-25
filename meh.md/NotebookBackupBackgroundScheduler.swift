#if os(iOS)
import BackgroundTasks
import Foundation

@MainActor
enum NotebookBackupBackgroundScheduler {
    private static var identifier: String {
        (Bundle.main.bundleIdentifier ?? "de.andreas-sk.meh-md")
            + ".markdown-backup"
    }
    private static var isRegistered = false

    static func register() {
        guard !isRegistered else { return }
        isRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: .main
        ) { task in
            guard let task = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(task)
        }
    }

    static func scheduleNext() {
        let scheduler = BGTaskScheduler.shared
        scheduler.cancel(taskRequestWithIdentifier: identifier)
        guard isRegistered,
              let nextDate = NotebookWorkspace.shared.nextBackupDate else { return }

        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresExternalPower = false
        request.requiresNetworkConnectivity = false
        request.earliestBeginDate = max(
            nextDate,
            Date().addingTimeInterval(15 * 60)
        )
        do {
            try scheduler.submit(request)
        } catch {
            // Opening the app still catches up on any missed backup.
            NSLog("Could not schedule Markdown backup: %@", String(describing: error))
        }
    }

    private nonisolated static func handle(_ task: BGProcessingTask) {
        let completion = BackgroundBackupCompletion(task: task)
        task.expirationHandler = { completion.expire() }
        let work = Task { @MainActor in
            if !Task.isCancelled {
                await NotebookWorkspace.shared.runDueBackup()
            }
            scheduleNext()
            completion.finish(success: !Task.isCancelled)
        }
        completion.setWork(work)
    }
}

private final class BackgroundBackupCompletion {
    private let lock = NSLock()
    private let task: BGProcessingTask
    private var work: Task<Void, Never>?
    private var isComplete = false

    init(task: BGProcessingTask) {
        self.task = task
    }

    func setWork(_ work: Task<Void, Never>) {
        lock.lock()
        self.work = work
        let shouldCancel = isComplete
        lock.unlock()
        if shouldCancel { work.cancel() }
    }

    func expire() {
        lock.lock()
        guard !isComplete else {
            lock.unlock()
            return
        }
        isComplete = true
        let work = work
        lock.unlock()
        work?.cancel()
        task.setTaskCompleted(success: false)
    }

    func finish(success: Bool) {
        lock.lock()
        guard !isComplete else {
            lock.unlock()
            return
        }
        isComplete = true
        lock.unlock()
        task.setTaskCompleted(success: success)
    }
}
#endif
