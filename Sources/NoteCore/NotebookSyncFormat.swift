import Automerge
import Foundation

/// The data format understood by this release. This is independent of the
/// record protocol version and is checked before interpreting catalog items.
public enum NotebookSyncFormat {
    public static let supportedVersion: UInt64 = 2

    public static func requireSupported(_ version: UInt64) throws {
        guard version > 0 else { throw SyncError.invalidRecord }
        if version > supportedVersion {
            throw SyncError.updateRequired(requiredVersion: version)
        }
    }

    public static func version(of record: SyncRecord) throws -> UInt64 {
        guard record.kind == .catalog else { return 1 }
        let document = try Document(record.snapshot.data)
        guard let snapshot = record.catalogSnapshot else { throw SyncError.invalidRecord }
        try validateIdentity(of: document, snapshot: snapshot)
        return try version(of: document)
    }

    static func validateIdentity(
        of document: Document, snapshot: NotebookCatalogSnapshot
    ) throws {
        let identities = try document.getAll(obj: .ROOT, key: "notebookID")
        guard Set(document.heads().map(\.debugDescription)) == snapshot.heads,
              identities.count == 1,
              case .Scalar(.String(let identity)) = identities.first,
              UUID(uuidString: identity) == snapshot.notebookID else {
            throw NotebookCatalogError.identityMismatch
        }
    }

    static func version(of document: Document) throws -> UInt64 {
        guard try document.getAll(obj: .ROOT, key: "kind")
            == [.Scalar(.String("notebookCatalog"))] else {
            throw SyncError.invalidRecord
        }
        let values = try document.getAll(obj: .ROOT, key: "schemaVersion")
        guard !values.isEmpty else { throw SyncError.invalidRecord }
        var version: UInt64 = 0
        for value in values {
            guard case .Scalar(.Uint(let candidate)) = value, candidate > 0 else {
                throw SyncError.invalidRecord
            }
            version = max(version, candidate)
        }
        return version
    }
}
