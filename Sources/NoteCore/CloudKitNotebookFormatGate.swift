import CloudKit
import Foundation

/// Optional fields on the existing canonical notebook snapshot. Older
/// canonical records have no fields and therefore describe format one.
struct CloudKitNotebookFormatGate: Equatable {
    static let readerKey = "minimumReaderVersion"
    static let writerKey = "minimumWriterVersion"
    static let catalogKey = "catalogFormatVersion"
    static let migrationKey = "migrationSnapshotID"
    static let publicationKey = "publicationID"

    var minimumReaderVersion: UInt64
    var minimumWriterVersion: UInt64
    var catalogFormatVersion: UInt64
    var migrationSnapshotID: String?

    static func read(_ record: CKRecord) throws -> Self {
        func version(_ key: String) throws -> UInt64 {
            guard let value = record[key] else { return 1 }
            guard let number = value as? NSNumber,
                  number.doubleValue.isFinite,
                  number.doubleValue >= 1,
                  number.doubleValue.rounded() == number.doubleValue,
                  number.uint64Value > 0,
                  Double(number.uint64Value) == number.doubleValue else {
                throw CloudKitSyncTransportError.invalidRemoteRecord
            }
            return number.uint64Value
        }
        let reader = try version(readerKey)
        let writer = try version(writerKey)
        let catalog = try version(catalogKey)
        guard reader <= catalog, writer <= catalog else {
            throw CloudKitSyncTransportError.invalidRemoteRecord
        }
        let migration = record[migrationKey] as? String
        if record[migrationKey] != nil && migration == nil {
            throw CloudKitSyncTransportError.invalidRemoteRecord
        }
        if let migration {
            try CloudKitRemoteRecordValidator.validateSnapshotID(migration)
        }
        return Self(
            minimumReaderVersion: reader,
            minimumWriterVersion: writer,
            catalogFormatVersion: catalog,
            migrationSnapshotID: migration
        )
    }

    func requireSupported() throws {
        try NotebookSyncFormat.requireSupported(minimumReaderVersion)
        try NotebookSyncFormat.requireSupported(minimumWriterVersion)
        try NotebookSyncFormat.requireSupported(catalogFormatVersion)
    }

    /// Mutate a fetched record, retaining its CloudKit change tag. The
    /// publication ID forces even an ordinary write to advance that tag.
    func publish(on record: CKRecord, catalogVersion: UInt64?,
                 snapshotID: String?) throws {
        let version = max(catalogFormatVersion, catalogVersion ?? 1)
        try NotebookSyncFormat.requireSupported(version)
        record[Self.readerKey] = NSNumber(value: version)
        record[Self.writerKey] = NSNumber(value: version)
        record[Self.catalogKey] = NSNumber(value: version)
        if version > catalogFormatVersion {
            guard let snapshotID else { throw SyncError.invalidRecord }
            record[Self.migrationKey] = snapshotID
        }
        record[Self.publicationKey] = UUID().uuidString
    }
}
