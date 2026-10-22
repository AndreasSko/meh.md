import Foundation

/// Why a transport stopped accepting work. Only a known local write
/// failure can be retried by constructing a new transport from durable state.
public enum SyncHaltReason: Equatable, Sendable {
    case localStorageFailure
    case accountChanged
    case corruptState
    case invalidRemoteRecord
    case updateRequired
    case unexpectedDeletion
    case other
    case retired
}

public struct SyncHaltStatus: Sendable {
    public let reason: SyncHaltReason
    public let underlyingError: any Error
    public let isRecoverable: Bool

    public init(
        reason: SyncHaltReason,
        underlyingError: any Error,
        isRecoverable: Bool
    ) {
        self.reason = reason
        self.underlyingError = underlyingError
        self.isRecoverable = isRecoverable
    }
}

/// The workspace may replace a halted transport after the old instance has
/// fenced its durable state. Test transports implement this same contract.
public protocol HaltableSyncTransport: SyncTransport {
    func haltStatus() async -> SyncHaltStatus?
    func retire() async
}
