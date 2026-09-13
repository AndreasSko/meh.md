import Foundation

/// The request path that caused CloudKit to fetch changes.
public enum CloudKitSyncReason: String, Equatable, Sendable {
    /// CloudKit scheduled the fetch, normally after receiving a push hint.
    case scheduled

    /// The app explicitly requested the fetch.
    case manual
}

/// Durable CloudKit work that may require a workspace sync pass or status
/// update. The transport only publishes an activity after its delegate has
/// committed the corresponding CloudKit event to local transport state.
public enum CloudKitSyncActivity: Equatable, Sendable {
    case remoteChanges(
        recordCount: Int,
        deletionCount: Int,
        reason: CloudKitSyncReason
    )
    case uploadsAcknowledged(recordCount: Int)
    case accountChanged
    case failed(String)
}

/// A single-consumer channel for sync hints. Counts may summarize several
/// completed operations while the consumer is busy; they are not an event log.
final class CloudKitSyncActivityChannel: Sendable {
    let stream: AsyncStream<CloudKitSyncActivity>
    private let buffer: CloudKitSyncActivityBuffer

    init() {
        let buffer = CloudKitSyncActivityBuffer()
        self.buffer = buffer
        stream = AsyncStream(
            unfolding: { await buffer.next() },
            onCancel: { buffer.finish() }
        )
    }

    func yield(_ activities: [CloudKitSyncActivity]) {
        buffer.yield(activities)
    }

    deinit { buffer.finish() }
}

private final class CloudKitSyncActivityBuffer: @unchecked Sendable {
    private enum Key: Hashable {
        case scheduledFetch
        case manualFetch
        case upload
        case account
        case failure
    }

    private let lock = NSLock()
    // `lock` protects all mutable state. The collections contain at most one
    // entry for each of the five activity keys.
    private var order: [Key] = []
    private var pending: [Key: CloudKitSyncActivity] = [:]
    private var waiter: CheckedContinuation<CloudKitSyncActivity?, Never>?
    private var isFinished = false

    func yield(_ activities: [CloudKitSyncActivity]) {
        var delivery: (
            CheckedContinuation<CloudKitSyncActivity?, Never>,
            CloudKitSyncActivity
        )?
        lock.lock()
        if !isFinished {
            for activity in activities { coalesce(activity) }
            if let waiter, let activity = removeFirst() {
                self.waiter = nil
                delivery = (waiter, activity)
            }
        }
        lock.unlock()
        if let delivery {
            delivery.0.resume(returning: delivery.1)
        }
    }

    func next() async -> CloudKitSyncActivity? {
        await withCheckedContinuation { continuation in
            var immediate: CloudKitSyncActivity?
            var shouldResume = false
            lock.lock()
            if let activity = removeFirst() {
                immediate = activity
                shouldResume = true
            } else if isFinished || waiter != nil {
                shouldResume = true
            } else {
                waiter = continuation
            }
            lock.unlock()
            if shouldResume { continuation.resume(returning: immediate) }
        }
    }

    func finish() {
        let suspended: CheckedContinuation<CloudKitSyncActivity?, Never>?
        lock.lock()
        isFinished = true
        order.removeAll(keepingCapacity: false)
        pending.removeAll(keepingCapacity: false)
        suspended = waiter
        waiter = nil
        lock.unlock()
        suspended?.resume(returning: nil)
    }

    private func coalesce(_ activity: CloudKitSyncActivity) {
        let key = key(for: activity)
        guard let current = pending[key] else {
            pending[key] = activity
            order.append(key)
            return
        }
        switch (current, activity) {
        case let (
            .remoteChanges(oldRecords, oldDeletions, reason),
            .remoteChanges(newRecords, newDeletions, _)
        ):
            pending[key] = .remoteChanges(
                recordCount: Self.saturatingSum(oldRecords, newRecords),
                deletionCount: Self.saturatingSum(
                    oldDeletions, newDeletions
                ),
                reason: reason
            )
        case let (
            .uploadsAcknowledged(oldCount),
            .uploadsAcknowledged(newCount)
        ):
            pending[key] = .uploadsAcknowledged(
                recordCount: Self.saturatingSum(oldCount, newCount)
            )
        case (.accountChanged, .accountChanged):
            break
        case (_, .failed(let message)):
            pending[key] = .failed(message)
        default:
            preconditionFailure("Activity key does not match its value")
        }
    }

    private func removeFirst() -> CloudKitSyncActivity? {
        guard !order.isEmpty else { return nil }
        let key = order.removeFirst()
        return pending.removeValue(forKey: key)
    }

    private func key(for activity: CloudKitSyncActivity) -> Key {
        switch activity {
        case .remoteChanges(_, _, .scheduled): .scheduledFetch
        case .remoteChanges(_, _, .manual): .manualFetch
        case .uploadsAcknowledged: .upload
        case .accountChanged: .account
        case .failed: .failure
        }
    }

    private static func saturatingSum(_ first: Int, _ second: Int) -> Int {
        let first = max(0, first)
        let second = max(0, second)
        let (sum, overflow) = first.addingReportingOverflow(second)
        return overflow ? Int.max : sum
    }
}

struct CloudKitSyncActivityTracker {
    private var fetchedRecordCount = 0
    private var fetchedDeletionCount = 0
    private var acknowledgedRecordCount = 0

    mutating func recordFetch(recordCount: Int, deletionCount: Int) {
        fetchedRecordCount += max(0, recordCount)
        fetchedDeletionCount += max(0, deletionCount)
    }

    mutating func finishFetch(
        reason: CloudKitSyncReason
    ) -> CloudKitSyncActivity? {
        defer {
            fetchedRecordCount = 0
            fetchedDeletionCount = 0
        }
        guard fetchedRecordCount > 0 || fetchedDeletionCount > 0 else {
            return nil
        }
        return .remoteChanges(
            recordCount: fetchedRecordCount,
            deletionCount: fetchedDeletionCount,
            reason: reason
        )
    }

    mutating func recordAcknowledgements(_ count: Int) {
        acknowledgedRecordCount += max(0, count)
    }

    mutating func finishSend(
        wasScheduled: Bool
    ) -> CloudKitSyncActivity? {
        defer { acknowledgedRecordCount = 0 }
        guard wasScheduled, acknowledgedRecordCount > 0 else { return nil }
        return .uploadsAcknowledged(recordCount: acknowledgedRecordCount)
    }
}

struct CloudKitFetchedCommit: Equatable, Sendable {
    var recordCount = 0
    var deletionCount = 0
}
