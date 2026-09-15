/// Determines when a pending notebook sync should begin.
///
/// Callers supply monotonic timestamps, which keeps this policy independent of
/// clocks and timer implementations.
public struct NotebookSyncSchedule: Sendable {
    private let idleDelay: Duration
    private let maximumDelay: Duration
    private let coalescingDelay: Duration
    private var lastEdit: Duration?
    private var firstRequest: Duration?
    private var latestRequest: Duration?

    public var hasPending: Bool { firstRequest != nil }

    public init(
        idleDelay: Duration = .seconds(10),
        maximumDelay: Duration = .seconds(60),
        coalescingDelay: Duration = .milliseconds(750)
    ) {
        self.idleDelay = idleDelay
        self.maximumDelay = maximumDelay
        self.coalescingDelay = coalescingDelay
    }

    public mutating func noteEdited(at time: Duration) {
        lastEdit = time
    }

    public mutating func request(at time: Duration) {
        if firstRequest == nil { firstRequest = time }
        latestRequest = time
    }

    @discardableResult
    public mutating func takePending() -> Bool {
        guard hasPending else { return false }
        clearPending()
        return true
    }

    public mutating func clearPending() {
        firstRequest = nil
        latestRequest = nil
    }

    public func delay(at now: Duration) -> Duration? {
        guard let firstRequest, let latestRequest else { return nil }
        let idleDeadline = lastEdit.map { $0 + idleDelay } ?? latestRequest
        let deadline = min(
            max(idleDeadline, latestRequest + coalescingDelay),
            firstRequest + maximumDelay
        )
        return max(.zero, deadline - now)
    }
}
