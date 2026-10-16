import Foundation
import Synchronization

/// A clock that only moves when a test advances it. Sleepers resume once
/// their deadline passes; cancelled sleepers throw like `Task.sleep`.
public final class ManualClock: Sendable {
    private struct Sleeper {
        let id: UInt64
        let deadline: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var elapsed = Duration.zero
        var nextID: UInt64 = 0
        var sleepers: [Sleeper] = []
        var cancelledIDs: Set<UInt64> = []
    }

    private let state = Mutex(State())
    private let start: Date

    public init(start: Date = Date()) {
        self.start = start
    }

    public func elapsed() -> Duration {
        state.withLock { $0.elapsed }
    }

    public func uptime() -> TimeInterval {
        Self.seconds(elapsed())
    }

    public func now() -> Date {
        start.addingTimeInterval(uptime())
    }

    /// Timers currently waiting for a later deadline.
    public var sleeperCount: Int {
        state.withLock { $0.sleepers.count }
    }

    /// Returns once the clock reaches the deadline, immediately if it already
    /// has. Taking an absolute deadline means a test can advance the clock
    /// before a freshly armed timer gets to start sleeping.
    public func sleep(until deadline: Duration) async throws {
        try Task.checkCancellation()
        let id = state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let result: Result<Void, any Error>? = state.withLock { state in
                    if state.cancelledIDs.remove(id) != nil {
                        return .failure(CancellationError())
                    }
                    if deadline <= state.elapsed { return .success(()) }
                    state.sleepers.append(Sleeper(
                        id: id, deadline: deadline, continuation: continuation
                    ))
                    return nil
                }
                if let result { continuation.resume(with: result) }
            }
        } onCancel: {
            let sleeper = state.withLock { state -> Sleeper? in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id })
                else {
                    state.cancelledIDs.insert(id)
                    return nil
                }
                return state.sleepers.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
        // Cancellation can land after advance(by:) already resumed this
        // sleeper. It still counts as cancelled, as with Task.sleep.
        state.withLock { _ = $0.cancelledIDs.remove(id) }
        try Task.checkCancellation()
    }

    /// Moves time forward and resumes every sleeper whose deadline passed,
    /// earliest first. Returns how many sleepers it resumed.
    @discardableResult
    public func advance(by duration: Duration) -> Int {
        let due = state.withLock { state in
            state.elapsed += duration
            let elapsed = state.elapsed
            let due = state.sleepers.filter { $0.deadline <= elapsed }
            state.sleepers.removeAll { $0.deadline <= elapsed }
            return due.sorted { $0.deadline < $1.deadline }
        }
        for sleeper in due { sleeper.continuation.resume() }
        return due.count
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1e18
    }
}
