import CloudKit
import Foundation

/// App-level retries cover setup and coordinator failures outside the engine.
/// The engine independently reschedules its durable transport work.
public struct NotebookSyncRetryPolicy: Sendable {
    public private(set) var failureCount = 0

    public init() {}

    public mutating func reset() { failureCount = 0 }

    public mutating func retryDate(
        for error: any Error, now: Date, serverNotBefore: Date? = nil
    ) -> Date? {
        guard Self.isTransient(error) else { return nil }
        failureCount = min(failureCount + 1, 7)
        let delay = min(300, 5 * pow(2, Double(failureCount - 1)))
        return max(now.addingTimeInterval(delay), serverNotBefore ?? now)
    }

    public static func isTransient(_ error: any Error) -> Bool {
        if error is CancellationError { return false }
        if let error = error as? SyncError {
            switch error {
            case .unavailable, .localSaveRequired: return true
            default: return false
            }
        }
        if let error = error as? CloudKitSyncTransportError {
            switch error {
            case .uploadNotAcknowledged: return true
            case .uploadFailed(let code): return transientCloudCode(code)
            default: return false
            }
        }
        if let error = error as? CKError { return transientCloudCode(error.code.rawValue) }
        if let error = error as? URLError {
            return [.timedOut, .cannotFindHost, .cannotConnectToHost,
                    .networkConnectionLost, .dnsLookupFailed, .notConnectedToInternet,
                    .resourceUnavailable, .internationalRoamingOff, .dataNotAllowed]
                .contains(error.code)
        }
        return error as? NotebookReplicaError == .busy
    }

    private static func transientCloudCode(_ code: Int) -> Bool {
        [CKError.networkUnavailable, .networkFailure, .serviceUnavailable,
         .requestRateLimited, .zoneBusy, .serverResponseLost]
            .contains { $0.rawValue == code }
    }
}
