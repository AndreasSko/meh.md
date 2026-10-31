import Foundation

/// What shared sync code needs to know about one backend's own error types.
/// Each backend answers only for errors it recognizes and returns nil for
/// anything else, so the coordinator, retry policy, event log, and failure
/// presentation never depend on a specific storage service.
protocol SyncBackendErrors {
    /// A stable code for the sync event log. `nested` encodes a wrapped error.
    static func diagnosticCode(
        of error: any Error, nested: (any Error) -> String
    ) -> String?

    /// Whether the app should retry the exchange after this failure.
    static func isTransient(_ error: any Error) -> Bool?

    /// A plain-language explanation. `nested` classifies a wrapped error.
    static func failure(
        of error: any Error,
        nested: (any Error) -> SyncFailurePresentation.Failure
    ) -> SyncFailurePresentation.Failure?

    /// The document whose snapshot exceeds the backend's size limit. Other
    /// documents can still sync, so the upload continues before failing.
    static func oversizedDocumentID(in error: any Error) -> UUID?

    /// The same oversized-snapshot failure, naming the document for the user.
    static func naming(_ error: any Error, displayName: String?) -> any Error
}

extension SyncBackendErrors {
    static func oversizedDocumentID(in error: any Error) -> UUID? { nil }

    static func naming(_ error: any Error, displayName: String?) -> any Error {
        error
    }
}

/// Every backend whose transport can surface its own error types. A new
/// backend adds its `SyncBackendErrors` here.
enum SyncBackends {
    static var errors: [any SyncBackendErrors.Type] {
        [CloudKitSyncErrors.self, S3SyncErrors.self]
    }

    static func diagnosticCode(
        of error: any Error, nested: (any Error) -> String
    ) -> String? {
        for backend in errors {
            if let code = backend.diagnosticCode(of: error, nested: nested) { return code }
        }
        return nil
    }

    static func isTransient(_ error: any Error) -> Bool? {
        for backend in errors {
            if let isTransient = backend.isTransient(error) { return isTransient }
        }
        return nil
    }

    static func failure(
        of error: any Error,
        nested: (any Error) -> SyncFailurePresentation.Failure
    ) -> SyncFailurePresentation.Failure? {
        for backend in errors {
            if let failure = backend.failure(of: error, nested: nested) { return failure }
        }
        return nil
    }

    static func oversizedDocumentID(in error: any Error) -> UUID? {
        for backend in errors {
            if let documentID = backend.oversizedDocumentID(in: error) { return documentID }
        }
        return nil
    }

    static func naming(_ error: any Error, displayName: String?) -> any Error {
        for backend in errors where backend.oversizedDocumentID(in: error) != nil {
            return backend.naming(error, displayName: displayName)
        }
        return error
    }
}
