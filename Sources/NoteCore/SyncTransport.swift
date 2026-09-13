import CryptoKit
import Foundation

public enum SyncDocumentKind: String, Codable, Sendable {
    case note, catalog
}

/// Version 1 preserves the single-note wire format. Version 2 binds each
/// snapshot to a notebook and distinguishes note bodies from catalog metadata.
/// The legacy `snapshot.noteID` field is the document ID for either kind.
public struct SyncRecord: Codable, Equatable, Sendable {
    public let id: String
    public let snapshot: NoteSnapshot
    public let protocolVersion: Int
    public let kind: SyncDocumentKind
    public let notebookID: UUID?

    public init(snapshot: NoteSnapshot) {
        self.snapshot = snapshot
        protocolVersion = 1
        kind = .note
        notebookID = nil
        id = Self.digest(snapshot: snapshot, kind: .note, notebookID: nil)
    }

    public init(snapshot: NoteSnapshot, notebookID: UUID) {
        self.snapshot = snapshot
        protocolVersion = 2
        kind = .note
        self.notebookID = notebookID
        id = Self.digest(snapshot: snapshot, kind: .note, notebookID: notebookID)
    }

    public init(catalog: NotebookCatalogSnapshot) {
        snapshot = NoteSnapshot(
            data: catalog.data, heads: catalog.heads, noteID: catalog.notebookID)
        protocolVersion = 2
        kind = .catalog
        notebookID = catalog.notebookID
        id = Self.digest(snapshot: snapshot, kind: .catalog, notebookID: notebookID)
    }

    public var catalogSnapshot: NotebookCatalogSnapshot? {
        guard protocolVersion == 2, kind == .catalog, let notebookID else { return nil }
        return NotebookCatalogSnapshot(
            data: snapshot.data, heads: snapshot.heads, notebookID: notebookID)
    }

    public func validate() throws {
        switch protocolVersion {
        case 1:
            guard kind == .note, notebookID == nil else { throw SyncError.invalidRecord }
            _ = try NoteDocument(snapshot: snapshot)
        case 2:
            guard let notebookID else { throw SyncError.invalidRecord }
            switch kind {
            case .note:
                _ = try NoteDocument(snapshot: snapshot)
            case .catalog:
                guard snapshot.noteID == notebookID, let catalogSnapshot else {
                    throw SyncError.invalidRecord
                }
                _ = try NotebookCatalogDocument(snapshot: catalogSnapshot)
            }
        default:
            throw SyncError.invalidRecord
        }
        guard id == Self.digest(snapshot: snapshot, kind: kind, notebookID: notebookID) else {
            throw SyncError.invalidRecord
        }
    }

    private static func digest(snapshot: NoteSnapshot, kind: SyncDocumentKind, notebookID: UUID?)
        -> String
    {
        var bytes = Data()
        if let notebookID {
            bytes.append(
                Data(
                    "meh-notebook-v2\n\(kind.rawValue)\n\(notebookID.uuidString)\n\(snapshot.noteID.uuidString)\n"
                        .utf8))
        }
        bytes.append(snapshot.data)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private enum CodingKeys: String, CodingKey {
        case id, snapshot, protocolVersion, kind, notebookID
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        snapshot = try values.decode(NoteSnapshot.self, forKey: .snapshot)
        protocolVersion = try values.decodeIfPresent(Int.self, forKey: .protocolVersion) ?? 1
        kind =
            protocolVersion == 2
            ? try values.decode(SyncDocumentKind.self, forKey: .kind)
            : try values.decodeIfPresent(SyncDocumentKind.self, forKey: .kind) ?? .note
        notebookID = try values.decodeIfPresent(UUID.self, forKey: .notebookID)
        if protocolVersion == 2 && !values.contains(.kind) { throw SyncError.invalidRecord }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(snapshot, forKey: .snapshot)
        if protocolVersion != 1 {
            try values.encode(protocolVersion, forKey: .protocolVersion)
            try values.encode(kind, forKey: .kind)
            try values.encodeIfPresent(notebookID, forKey: .notebookID)
        }
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

public struct SyncBatchResult: Sendable {
    public let acknowledgedIDs: Set<String>
    public let error: (any Error)?

    public init(acknowledgedIDs: Set<String>, error: (any Error)?) {
        self.acknowledgedIDs = acknowledgedIDs
        self.error = error
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
    /// Publish records together when the backend supports it. The result keeps
    /// partial acknowledgements if a later record fails.
    func publishBatch(_ records: [SyncRecord]) async throws -> SyncBatchResult
    /// nil starts a complete replay. Cleanup may leave stable cursor tombstones.
    func fetch(after cursor: String?) async throws -> SyncPage
    /// Durably suppress and remove version 2 note-body snapshots for confirmed
    /// deleted identities. Catalog snapshots and deletion markers remain.
    func purgeDeletedNotes(
        _ noteIDs: Set<UUID>, notebookID: UUID
    ) async throws
    /// The earliest useful retry time known by the transport.
    func retryNotBefore() async -> Date?
}

extension SyncTransport {
    public func publishBatch(
        _ records: [SyncRecord]
    ) async throws -> SyncBatchResult {
        var acknowledgedIDs = Set<String>()
        for record in records {
            do {
                try await publish(record)
                acknowledgedIDs.insert(record.id)
            } catch {
                return SyncBatchResult(
                    acknowledgedIDs: acknowledgedIDs,
                    error: error
                )
            }
        }
        return SyncBatchResult(
            acknowledgedIDs: acknowledgedIDs,
            error: nil
        )
    }

    public func retryNotBefore() async -> Date? { nil }

    public func purgeDeletedNotes(
        _ noteIDs: Set<UUID>, notebookID: UUID
    ) async throws {
        throw SyncError.unavailable(
            "This sync transport does not support permanent body cleanup."
        )
    }
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
        case .unavailable(let message): message
        }
    }
}
