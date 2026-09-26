import Foundation

/// Why a CloudKit transport stopped accepting work. Only a known local write
/// failure can be retried by constructing a new transport from durable state.
public enum CloudKitSyncHaltReason: Equatable, Sendable {
    case localStorageFailure
    case accountChanged
    case corruptState
    case invalidRemoteRecord
    case unexpectedDeletion
    case other
    case retired
}

public struct CloudKitSyncHaltStatus: Sendable {
    public let reason: CloudKitSyncHaltReason
    public let underlyingError: any Error
    public let isRecoverable: Bool

    public init(
        reason: CloudKitSyncHaltReason,
        underlyingError: any Error,
        isRecoverable: Bool
    ) {
        self.reason = reason
        self.underlyingError = underlyingError
        self.isRecoverable = isRecoverable
    }

    init(error: any Error) {
        if let failure = error as? CloudKitStateWriteFailure {
            underlyingError = failure.underlyingError
            reason = .localStorageFailure
            isRecoverable = failure.isRecoverable
        } else if error as? SyncError == .scopeChanged {
            underlyingError = error
            reason = .accountChanged
            isRecoverable = false
        } else if let error = error as? CloudKitSyncTransportError {
            underlyingError = error
            switch error {
            case .corruptState: reason = .corruptState
            case .invalidRemoteRecord: reason = .invalidRemoteRecord
            case .unexpectedDeletion: reason = .unexpectedDeletion
            default: reason = .other
            }
            isRecoverable = false
        } else {
            underlyingError = error
            reason = .other
            isRecoverable = false
        }
    }
}

/// The workspace may replace a halted transport after the old instance has
/// fenced its durable state. Test transports implement this same contract.
public protocol HaltableSyncTransport: SyncTransport {
    func haltStatus() async -> CloudKitSyncHaltStatus?
    func retire() async
}

/// Indicates that encoding and validation succeeded but persisting the next
/// transport state failed. A fresh instance must reload the prior disk state.
struct CloudKitStateWriteFailure: Error, LocalizedError {
    let underlyingError: any Error

    var errorDescription: String? {
        "Could not save iCloud sync progress: \(underlyingError.localizedDescription)"
    }

    var isRecoverable: Bool {
        Self.isRecoverable(underlyingError as NSError)
    }

    private static func isRecoverable(_ error: NSError) -> Bool {
        if error.domain == NSPOSIXErrorDomain {
            return [ENOSPC, EROFS, EACCES, EPERM]
                .map(Int.init).contains(error.code)
        }
        if error.domain == NSCocoaErrorDomain {
            if [
                CocoaError.fileWriteOutOfSpace.rawValue,
                CocoaError.fileWriteVolumeReadOnly.rawValue,
                CocoaError.fileWriteNoPermission.rawValue,
            ].contains(error.code) {
                return true
            }
        }
        if let cause = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isRecoverable(cause)
        }
        return false
    }
}

struct CloudKitRetiredTransportError: Error, LocalizedError {
    var errorDescription: String? {
        "This iCloud sync connection has been replaced."
    }
}

/// A synchronous signal from the storage actor to the transport's final batch
/// guard. The lock protects only this value; no disk I/O runs under the lock.
final class CloudKitWriteHealth: @unchecked Sendable {
    private let lock = NSLock()
    private var storedFailure: CloudKitStateWriteFailure?

    var failure: CloudKitStateWriteFailure? {
        lock.withLock { storedFailure }
    }

    func latch(_ failure: CloudKitStateWriteFailure) {
        lock.withLock {
            if storedFailure == nil { storedFailure = failure }
        }
    }
}
