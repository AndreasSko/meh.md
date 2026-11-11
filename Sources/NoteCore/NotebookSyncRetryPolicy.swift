import Foundation

/// App-level retries cover setup and coordinator failures outside the engine.
/// The engine independently reschedules its durable transport work.
public struct NotebookSyncRetryPolicy: Sendable {
    public private(set) var failureCount = 0
    private static let maximumFailureCount = 7

    /// False once retries have reached the longest delay without a success.
    /// A failure that is retried whatever its error is then not temporary.
    public var mayRetryUnknownFailure: Bool { failureCount < Self.maximumFailureCount }

    public init() {}

    public mutating func reset() { failureCount = 0 }

    /// `always` retries whatever the error is, for a failure whose cause
    /// lies in the connection that failed and not in the data.
    public mutating func retryDate(
        for error: any Error, now: Date, serverNotBefore: Date? = nil,
        always: Bool = false
    ) -> Date? {
        guard Self.isTransient(error) || (always && mayRetryUnknownFailure) else {
            return nil
        }
        failureCount = min(failureCount + 1, Self.maximumFailureCount)
        let delay = min(300, 5 * pow(2, Double(failureCount - 1)))
        return max(now.addingTimeInterval(delay), serverNotBefore ?? now)
    }

    public static func isTransient(_ error: any Error) -> Bool {
        if error is CancellationError { return false }
        // Local storage may recover before the next synchronization attempt.
        if error is LocalNoteSaveFailure { return true }
        if let error = error as? SyncError {
            switch error {
            case .unavailable, .localSaveRequired: return true
            default: return false
            }
        }
        if let isTransient = SyncBackends.isTransient(error) { return isTransient }
        if let error = error as? URLError {
            return [.timedOut, .cannotFindHost, .cannotConnectToHost,
                    .networkConnectionLost, .dnsLookupFailed, .notConnectedToInternet,
                    .resourceUnavailable, .internationalRoamingOff, .dataNotAllowed]
                .contains(error.code)
        }
        return error as? NotebookReplicaError == .busy
    }
}
