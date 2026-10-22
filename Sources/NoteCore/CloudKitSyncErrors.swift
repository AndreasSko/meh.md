import CloudKit
import Foundation

/// How CloudKit and CloudKit transport errors appear to shared sync code.
enum CloudKitSyncErrors: SyncBackendErrors {
    typealias Failure = SyncFailurePresentation.Failure

    static func diagnosticCode(
        of error: any Error, nested: (any Error) -> String
    ) -> String? {
        if let error = error as? CloudKitStateWriteFailure {
            return "CloudKitStateWriteFailure." + nested(error.underlyingError)
        }
        if let error = error as? CKError {
            return "CKError.\(error.code.rawValue)"
        }
        guard let error = error as? CloudKitSyncTransportError else { return nil }
        switch error {
        case .accountUnavailable: return "CloudKitSyncTransportError.accountUnavailable"
        case .corruptState: return "CloudKitSyncTransportError.corruptState"
        case .unrecoverableRetryDelay:
            return "CloudKitSyncTransportError.unrecoverableRetryDelay"
        case .invalidRemoteRecord:
            return "CloudKitSyncTransportError.invalidRemoteRecord"
        case .unexpectedDeletion:
            return "CloudKitSyncTransportError.unexpectedDeletion"
        case .uploadFailed(let code):
            return "CloudKitSyncTransportError.uploadFailed.\(code)"
        case .uploadNotAcknowledged:
            return "CloudKitSyncTransportError.uploadNotAcknowledged"
        case let .snapshotTooLarge(documentID, _, _):
            return "CloudKitSyncTransportError.snapshotTooLarge."
                + documentID.uuidString
        }
    }

    static func isTransient(_ error: any Error) -> Bool? {
        if let error = error as? CloudKitSyncTransportError {
            switch error {
            case .uploadNotAcknowledged: return true
            case .uploadFailed(let code): return isTransientCloudCode(code)
            default: return false
            }
        }
        if let error = error as? CKError { return isTransientCloudCode(error.code.rawValue) }
        return nil
    }

    static func failure(
        of error: any Error, nested: (any Error) -> Failure
    ) -> Failure? {
        if let failure = error as? CloudKitStateWriteFailure {
            return nested(failure.underlyingError)
        }
        if let error = error as? CloudKitSyncTransportError {
            return failure(of: error)
        }
        if let error = error as? CKError {
            if error.code == .partialFailure,
               let partialErrors = error.userInfo[CKPartialErrorsByItemIDKey]
                    as? [AnyHashable: any Error] {
                let candidates = partialErrors.sorted {
                    String(describing: $0.key) < String(describing: $1.key)
                }.map { nested($0.value) }
                return candidates.first(where: { $0.disposition == .unavailable })
                    ?? candidates.first(where: { !$0.isUnknown })
                    ?? SyncFailurePresentation.unknownFailure
            }
            return failure(cloudCode: error.code.rawValue)
        }
        let nsError = error as NSError
        if nsError.domain == CKErrorDomain {
            return failure(cloudCode: nsError.code)
        }
        return nil
    }

    static func oversizedDocumentID(in error: any Error) -> UUID? {
        guard case let .snapshotTooLarge(documentID, _, _)
                = error as? CloudKitSyncTransportError else { return nil }
        return documentID
    }

    static func naming(_ error: any Error, displayName: String?) -> any Error {
        guard case let .snapshotTooLarge(documentID, kind, _)
                = error as? CloudKitSyncTransportError else { return error }
        return CloudKitSyncTransportError.snapshotTooLarge(
            documentID: documentID, kind: kind, displayName: displayName
        )
    }

    private static func isTransientCloudCode(_ code: Int) -> Bool {
        [CKError.networkUnavailable, .networkFailure, .serviceUnavailable,
         .requestRateLimited, .zoneBusy, .serverResponseLost]
            .contains { $0.rawValue == code }
    }

    private static func failure(of error: CloudKitSyncTransportError) -> Failure {
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
        case .unrecoverableRetryDelay:
            return Failure(
                "Sync paused for retry safety",
                "The saved iCloud server retry delay could not be verified.",
                actionHint: "Keep local notes and share sync diagnostics for recovery.",
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
            return SyncFailurePresentation.transientFailure
        case let .snapshotTooLarge(documentID, kind, displayName):
            if kind == .catalog {
                return Failure(
                    "Notebook too large to sync",
                    "The notebook's saved organization history exceeds the 64 MiB iCloud sync limit. Notebook sync is paused. Local notes remain available.",
                    actionHint: "Keep your local data and export a backup before seeking help to recover sync.",
                    disposition: .unavailable
                )
            }
            let identity = displayName ?? documentID.uuidString
            return Failure(
                "Snapshot too large to sync",
                "The saved history for \(identity) exceeds the 64 MiB iCloud sync limit. Its local copy remains available.",
                actionHint: "Other notes can still sync. Export a backup before seeking help to reduce this note's history.",
                disposition: .manual
            )
        case let .uploadFailed(code):
            return failure(cloudCode: code)
        }
    }

    private static func failure(cloudCode rawValue: Int) -> Failure {
        guard let code = CKError.Code(rawValue: rawValue) else {
            return SyncFailurePresentation.unknownFailure
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
            return SyncFailurePresentation.transientFailure
        case .serverRecordChanged, .changeTokenExpired, .unknownItem,
             .invalidArguments, .constraintViolation:
            return Failure(
                "Sync needs attention",
                "iCloud sync data could not be safely reconciled.",
                actionHint: "Review the sync status before trying again.",
                disposition: .unavailable
            )
        default:
            return SyncFailurePresentation.unknownFailure
        }
    }
}
