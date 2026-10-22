import Foundation

/// Work a transport finished on its own that may require a workspace sync
/// pass or status update. A transport publishes an activity only after it
/// has committed the corresponding event to its local state.
public enum SyncActivity: Equatable, Sendable {
    /// The request path that caused the transport to fetch changes.
    public enum Reason: String, Equatable, Sendable {
        /// The backend scheduled the fetch, normally after a push hint.
        case scheduled

        /// The app explicitly requested the fetch.
        case manual
    }

    case remoteChanges(
        recordCount: Int,
        deletionCount: Int,
        reason: Reason
    )
    case uploadsAcknowledged(recordCount: Int)
    /// A scheduled publication needs a fresh app exchange to complete.
    case publicationPending
    case accountChanged
    case failed(String)
}

/// A transport that also syncs on its own, for example after a push
/// notification, and tells the app when that work needs an exchange.
/// Transports that only sync when asked do not need this.
public protocol ActiveSyncTransport: SyncTransport {
    /// Activity hints for a single consumer.
    var activity: AsyncStream<SyncActivity> { get }
    /// The failure behind the most recent `.failed` activity.
    func lastFailure() async -> (any Error)?
    /// Makes the next fetch also read the server directly, so it finds
    /// changes whose notification never arrived.
    func requestServerCheck() async
}
