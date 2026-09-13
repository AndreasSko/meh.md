import CryptoKit
import Foundation

/// Immutable full-history payload. The identifier makes retries idempotent.
public struct SyncRecord: Codable, Equatable, Sendable {
    public let id: String
    public let snapshot: NoteSnapshot

    public init(snapshot: NoteSnapshot) {
        self.snapshot = snapshot
        id = SHA256.hash(data: snapshot.data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    public func validate() throws {
        guard id == SyncRecord(snapshot: snapshot).id else {
            throw SyncError.invalidRecord
        }
        _ = try NoteDocument(snapshot: snapshot)
    }
}

public struct SyncPage: Codable, Equatable, Sendable {
    public let records: [SyncRecord]
    public let cursor: String
    public let hasMore: Bool

    public init(records: [SyncRecord], cursor: String, hasMore: Bool) {
        self.records = records
        self.cursor = cursor
        self.hasMore = hasMore
    }
}

/// A remote record store, not a peer-to-peer stream. All methods may be
/// retried after an uncertain result. Cursors are scoped to one backend.
public protocol SyncTransport: Sendable {
    /// Stable account + container + workspace scope; never a credential.
    var scope: String { get }
    /// Atomically create the canonical seed if absent, otherwise return it.
    /// The canonical seed must also be discoverable through fetch.
    func bootstrap(proposing record: SyncRecord) async throws -> SyncRecord
    /// A successful return acknowledges durable remote storage of this ID.
    func publish(_ record: SyncRecord) async throws
    /// nil starts a complete replay. No record is deleted in this milestone.
    func fetch(after cursor: String?) async throws -> SyncPage
}

public enum SyncError: Error, Equatable, LocalizedError {
    case invalidRecord
    case identityConflict
    case disconnectedHistory
    case scopeChanged
    case invalidCursor
    case localSaveRequired
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRecord: "The received note failed validation."
        case .identityConflict:
            "This device and the sync workspace contain different notes. Both have been preserved."
        case .disconnectedHistory:
            "The received note does not share this note's history."
        case .scopeChanged:
            "The sync account or workspace changed. Sync is paused to protect the local note."
        case .invalidCursor: "The sync cursor is invalid. A full replay is required."
        case .localSaveRequired: "Save this note locally before synchronizing."
        case let .unavailable(message): message
        }
    }
}
