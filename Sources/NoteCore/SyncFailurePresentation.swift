import Foundation

/// User-facing explanation and next step for a sync failure.
///
/// The original error remains the diagnostic source. This value deliberately
/// contains only plain language suitable for the sync status interface.
public struct SyncFailurePresentation: Equatable, Sendable {
    public enum RetryDisposition: Equatable, Sendable {
        /// The sync system is configured to retry this failure.
        case automatic
        /// The user can try again after addressing the stated condition.
        case manual
        /// Retrying cannot resolve the failure without another intervention.
        case unavailable
    }

    public let title: LocalizedStringResource
    public let message: LocalizedStringResource
    public let actionHint: LocalizedStringResource?
    public let retryDisposition: RetryDisposition
    /// A local durability prerequisite with an app-managed retry, not a
    /// confirmed write failure. Persistent waits still need visible attention.
    public let isWaitingForLocalSave: Bool

    public init(
        error: any Error,
        retryWillOccurAutomatically: Bool
    ) {
        let failure = Self.classify(error)
        title = failure.title
        message = failure.message
        retryDisposition = failure.disposition == .automatic
            && !retryWillOccurAutomatically ? .manual : failure.disposition
        isWaitingForLocalSave = failure.isWaitingForLocalSave
            && retryWillOccurAutomatically
        if failure.disposition == .automatic {
            actionHint = retryWillOccurAutomatically
                ? "Sync will retry automatically."
                : "Try syncing again."
        } else {
            actionHint = failure.actionHint
        }
    }

    struct Failure {
        let title: LocalizedStringResource
        let message: LocalizedStringResource
        let actionHint: LocalizedStringResource?
        let disposition: RetryDisposition
        let isWaitingForLocalSave: Bool
        var isUnknown: Bool { title == SyncFailurePresentation.unknownFailure.title }

        init(
            _ title: LocalizedStringResource,
            _ message: LocalizedStringResource,
            actionHint: LocalizedStringResource? = nil,
            disposition: RetryDisposition = .manual,
            isWaitingForLocalSave: Bool = false
        ) {
            self.title = title
            self.message = message
            self.actionHint = actionHint
            self.disposition = disposition
            self.isWaitingForLocalSave = isWaitingForLocalSave
        }
    }

    private static func classify(_ error: any Error) -> Failure {
        classify(error, depth: 0, visited: [])
    }

    private static func classify(
        _ error: any Error,
        depth: Int,
        visited: Set<ObjectIdentifier>
    ) -> Failure {
        guard depth < 12 else { return unknownFailure }

        if let failure = error as? LocalNoteSaveFailure {
            let cause = classify(
                failure.underlyingError, depth: depth + 1, visited: visited
            )
            guard cause.isUnknown || cause.isWaitingForLocalSave else { return cause }
            return Failure(
                "Changes could not be saved",
                "The app could not save changes on this device. Sync will wait until saving succeeds.",
                actionHint: "Try again. If saving keeps failing, open Settings → Diagnostics for details."
            )
        }

        if error is NotebookOfflineJoinInterrupted {
            return Failure(
                "Restart to finish sync setup",
                "Connecting this notebook was interrupted. Editing is paused until setup finishes.",
                actionHint: "Close and reopen the app to finish connecting. Saved notes stay on this device.",
                disposition: .unavailable
            )
        }

        if error is CancellationError {
            return Failure(
                "Sync stopped",
                "The sync operation was cancelled.",
                actionHint: "Try syncing again."
            )
        }

        if let error = error as? SyncError {
            switch error {
            case .updateRequired:
                return Failure(
                    "Update required",
                    "Update meh.md to resume iCloud sync. You can keep editing your notes on this device.",
                    disposition: .unavailable
                )
            case .scopeChanged:
                return Failure(
                    "Sync paused",
                    "The iCloud sync identity changed. Sync is paused to protect notebook history.",
                    actionHint: "Review the sync status before continuing.",
                    disposition: .unavailable
                )
            case .localSaveRequired:
                return Failure(
                    "Waiting to sync",
                    "Sync will continue when changes are saved on this device.",
                    disposition: .automatic,
                    isWaitingForLocalSave: true
                )
            case .invalidRecord, .disconnectedHistory, .identityConflict,
                 .invalidCursor:
                return Failure(
                    "Sync needs attention",
                    "The received sync data could not be safely applied. Sync is paused to protect notebook history.",
                    actionHint: "Review the sync status before trying again.",
                    disposition: .unavailable
                )
            case .unavailable:
                return transientFailure
            }
        }

        if let failure = SyncBackends.failure(of: error, nested: {
            classify($0, depth: depth + 1, visited: visited)
        }) {
            return failure
        }

        if let error = error as? URLError {
            if isTransient(error.code) { return transientFailure }
            if error.code == .userAuthenticationRequired {
                return Failure(
                    "Sign-in required",
                    "Your network account needs attention before sync can continue.",
                    actionHint: "Check your account, then try syncing again."
                )
            }
        }

        if let error = error as? POSIXError {
            if let failure = classifyPOSIX(error.code) { return failure }
        }

        if let error = error as? CocoaError {
            if let failure = classifyCocoa(error.code) { return failure }
        }

        let nsError = error as NSError
        let identifier = ObjectIdentifier(nsError)
        guard !visited.contains(identifier) else { return unknownFailure }
        var nextVisited = visited
        nextVisited.insert(identifier)

        if nsError.domain == NSURLErrorDomain,
           isTransient(URLError.Code(rawValue: nsError.code)) {
            return transientFailure
        }
        if nsError.domain == NSPOSIXErrorDomain,
           let rawCode = Int32(exactly: nsError.code),
           let code = POSIXErrorCode(rawValue: rawCode),
           let failure = classifyPOSIX(code) {
            return failure
        }
        if nsError.domain == NSCocoaErrorDomain,
           let failure = classifyCocoa(CocoaError.Code(rawValue: nsError.code)) {
            return failure
        }

        if let nested = nsError.userInfo[NSUnderlyingErrorKey] as? any Error {
            let failure = classify(
                nested, depth: depth + 1, visited: nextVisited
            )
            if failure.title != unknownFailure.title { return failure }
        }

        if error as? NotebookReplicaError == .busy {
            return transientFailure
        }
        return unknownFailure
    }

    static let transientFailure = Failure(
        "Sync temporarily unavailable",
        "A temporary network or iCloud service problem stopped sync.",
        actionHint: "Try syncing again.",
        disposition: .automatic
    )

    static let unknownFailure = Failure(
        "Sync failed",
        "Sync could not complete. The cause is not available.",
        actionHint: "Try syncing again."
    )

    private static func isTransient(_ code: URLError.Code) -> Bool {
        [
            .timedOut, .cannotFindHost, .cannotConnectToHost,
            .networkConnectionLost, .dnsLookupFailed,
            .notConnectedToInternet, .resourceUnavailable,
            .internationalRoamingOff, .dataNotAllowed
        ].contains(code)
    }

    private static func classifyPOSIX(_ code: POSIXErrorCode) -> Failure? {
        switch code {
        case .ENOSPC:
            return Failure(
                "Device storage is full",
                "There is not enough space on this device to save sync progress.",
                actionHint: "Free up device storage, then try syncing again."
            )
        case .EACCES, .EPERM, .EROFS:
            return Failure(
                "Sync data could not be saved",
                "The app does not have permission to update its local sync data.",
                actionHint: "Check device storage access, then try again."
            )
        default:
            return nil
        }
    }

    private static func classifyCocoa(_ code: CocoaError.Code) -> Failure? {
        switch code {
        case .fileWriteOutOfSpace:
            return Failure(
                "Device storage is full",
                "There is not enough space on this device to save sync progress.",
                actionHint: "Free up device storage, then try syncing again."
            )
        case .fileWriteNoPermission, .fileReadNoPermission:
            return Failure(
                "Sync data could not be saved",
                "The app does not have permission to access its local sync data.",
                actionHint: "Check device storage access, then try again."
            )
        case .fileReadCorruptFile:
            return Failure(
                "Sync state needs recovery",
                "The saved local sync data could not be read safely.",
                actionHint: "Sync recovery is needed before syncing can continue.",
                disposition: .unavailable
            )
        default:
            return nil
        }
    }
}
