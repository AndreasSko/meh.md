import CloudKit
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

    public init(
        error: any Error,
        retryWillOccurAutomatically: Bool
    ) {
        let failure = Self.classify(error)
        title = failure.title
        message = failure.message
        retryDisposition = failure.disposition == .automatic
            && !retryWillOccurAutomatically ? .manual : failure.disposition
        if failure.disposition == .automatic {
            actionHint = retryWillOccurAutomatically
                ? "Sync will retry automatically."
                : "Try syncing again."
        } else {
            actionHint = failure.actionHint
        }
    }

    private struct Failure {
        let title: LocalizedStringResource
        let message: LocalizedStringResource
        let actionHint: LocalizedStringResource?
        let disposition: RetryDisposition
        var isUnknown: Bool { title == SyncFailurePresentation.unknownFailure.title }

        init(
            _ title: LocalizedStringResource,
            _ message: LocalizedStringResource,
            actionHint: LocalizedStringResource? = nil,
            disposition: RetryDisposition = .manual
        ) {
            self.title = title
            self.message = message
            self.actionHint = actionHint
            self.disposition = disposition
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

        if let failure = error as? CloudKitStateWriteFailure {
            return classify(
                failure.underlyingError,
                depth: depth + 1,
                visited: visited
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
            case .scopeChanged:
                return Failure(
                    "Sync paused",
                    "The iCloud sync identity changed. Sync is paused to protect notebook history.",
                    actionHint: "Review the sync status before continuing.",
                    disposition: .unavailable
                )
            case .localSaveRequired:
                return Failure(
                    "Save before syncing",
                    "This note needs to be saved on this device before it can sync.",
                    actionHint: "Save the note, then try syncing again."
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

        if let error = error as? CloudKitSyncTransportError {
            switch error {
            case .accountUnavailable:
                return Failure(
                    "iCloud account unavailable",
                    "An available iCloud account is needed to sync.",
                    actionHint: "Check iCloud sign-in, then try syncing again."
                )
            case .corruptState:
                return Failure(
                    "Sync state needs recovery",
                    "The saved iCloud sync state could not be read safely.",
                    actionHint: "Sync recovery is needed before syncing can continue.",
                    disposition: .unavailable
                )
            case .invalidRemoteRecord:
                return Failure(
                    "Sync needs attention",
                    "iCloud returned sync data that could not be safely applied.",
                    actionHint: "Review the sync status before trying again.",
                    disposition: .unavailable
                )
            case .unexpectedDeletion:
                return Failure(
                    "Sync paused",
                    "A remote note snapshot was deleted unexpectedly. Sync paused to preserve history.",
                    actionHint: "Review the sync status before trying again.",
                    disposition: .unavailable
                )
            case .uploadNotAcknowledged:
                return transientFailure
            case let .uploadFailed(code):
                return classifyCloudCode(code)
            }
        }

        if let error = error as? CKError {
            if error.code == .partialFailure,
               let partialErrors = error.userInfo[CKPartialErrorsByItemIDKey]
                    as? [AnyHashable: any Error] {
                return classifyPartialErrors(
                    partialErrors, depth: depth, visited: visited
                )
            }
            return classifyCloudCode(error.code.rawValue)
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

        if nsError.domain == CKErrorDomain {
            return classifyCloudCode(nsError.code)
        }
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

    private static func classifyPartialErrors(
        _ errors: [AnyHashable: any Error],
        depth: Int,
        visited: Set<ObjectIdentifier>
    ) -> Failure {
        let candidates = errors.sorted {
            String(describing: $0.key) < String(describing: $1.key)
        }.map {
            classify($0.value, depth: depth + 1, visited: visited)
        }
        return candidates.first(where: { $0.disposition == .unavailable })
            ?? candidates.first(where: { !$0.isUnknown })
            ?? unknownFailure
    }

    private static let transientFailure = Failure(
        "Sync temporarily unavailable",
        "A temporary network or iCloud service problem stopped sync.",
        actionHint: "Try syncing again.",
        disposition: .automatic
    )

    private static let unknownFailure = Failure(
        "Sync failed",
        "Sync could not complete. The cause is not available.",
        actionHint: "Try syncing again."
    )

    private static func classifyCloudCode(_ rawValue: Int) -> Failure {
        guard let code = CKError.Code(rawValue: rawValue) else {
            return unknownFailure
        }
        switch code {
        case .notAuthenticated, .accountTemporarilyUnavailable:
            return Failure(
                "iCloud account unavailable",
                "The iCloud account is signed out or temporarily unavailable.",
                actionHint: "Check iCloud sign-in, then try syncing again."
            )
        case .quotaExceeded:
            return Failure(
                "iCloud storage is full",
                "iCloud does not have enough available storage for this sync.",
                actionHint: "Free up iCloud storage, then try syncing again."
            )
        case .permissionFailure, .missingEntitlement:
            return Failure(
                "iCloud access unavailable",
                "This app does not currently have permission to sync with iCloud.",
                actionHint: "Check iCloud access for this app."
            )
        case .networkUnavailable, .networkFailure, .serviceUnavailable,
             .requestRateLimited, .zoneBusy, .serverResponseLost:
            return transientFailure
        case .serverRecordChanged, .changeTokenExpired, .unknownItem,
             .invalidArguments, .constraintViolation:
            return Failure(
                "Sync needs attention",
                "iCloud sync data could not be safely reconciled.",
                actionHint: "Review the sync status before trying again.",
                disposition: .unavailable
            )
        default:
            return unknownFailure
        }
    }

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
