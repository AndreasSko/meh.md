import Foundation

/// How S3 transport errors appear to shared sync code.
enum S3SyncErrors: SyncBackendErrors {
    typealias Failure = SyncFailurePresentation.Failure

    static func diagnosticCode(
        of error: any Error, nested: (any Error) -> String
    ) -> String? {
        guard let error = error as? S3SyncTransportError else { return nil }
        switch error {
        case .invalidConfiguration: return "S3SyncTransportError.invalidConfiguration"
        case .missingCredentials: return "S3SyncTransportError.missingCredentials"
        case .invalidResponse: return "S3SyncTransportError.invalidResponse"
        case let .requestFailed(status, code):
            return "S3SyncTransportError.requestFailed.\(status).\(code)"
        }
    }

    static func isTransient(_ error: any Error) -> Bool? {
        guard let error = error as? S3SyncTransportError else { return nil }
        switch error {
        case .invalidResponse: return true
        case let .requestFailed(status, code): return isTransient(status: status, code: code)
        case .invalidConfiguration, .missingCredentials: return false
        }
    }

    static func failure(
        of error: any Error, nested: (any Error) -> Failure
    ) -> Failure? {
        guard let error = error as? S3SyncTransportError else { return nil }
        switch error {
        case .invalidConfiguration, .missingCredentials:
            return Failure(
                "S3 storage not set up",
                "The S3 storage settings or access key are missing or incomplete.",
                actionHint: "Open Settings › Sync › S3 Storage to finish setting up S3."
            )
        case .invalidResponse:
            return transientFailure
        case let .requestFailed(status, code):
            if isTransient(status: status, code: code) { return transientFailure }
            switch code {
            case "RequestTimeTooSkewed":
                return Failure(
                    "Check the date and time",
                    "The S3 storage rejected sync because this device's clock is off.",
                    actionHint: "Set the date and time automatically, then try syncing again."
                )
            case "NoSuchBucket", "PermanentRedirect", "AuthorizationHeaderMalformed",
                 "IllegalLocationConstraintException":
                return Failure(
                    "Bucket not found",
                    "The S3 bucket for sync does not exist or is in another region.",
                    actionHint: "Check the bucket and region in Settings › Sync › S3 Storage."
                )
            case "QuotaExceeded", "XMinioStorageFull", "StorageFull":
                return Failure(
                    "S3 storage is full",
                    "The S3 storage does not have enough space for this sync.",
                    actionHint: "Free up space on the storage, then try syncing again."
                )
            default:
                break
            }
            if status == 401 || status == 403 {
                return Failure(
                    "S3 access denied",
                    "The S3 storage rejected the access key, or it may not use this bucket.",
                    actionHint: "Check the access key and bucket permissions in Settings › Sync › S3 Storage."
                )
            }
            return SyncFailurePresentation.unknownFailure
        }
    }

    private static let transientFailure = Failure(
        "Sync temporarily unavailable",
        "A temporary network or S3 storage problem stopped sync.",
        actionHint: "Try syncing again.",
        disposition: .automatic
    )

    private static func isTransient(status: Int, code: String) -> Bool {
        [408, 429, 500, 502, 503, 504].contains(status)
            || ["SlowDown", "RequestTimeout", "InternalError", "ServiceUnavailable"]
                .contains(code)
    }
}
