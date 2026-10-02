import CloudKit
import Foundation

/// Validates the durable envelope before a transport trusts a fetched asset.
struct CloudKitAttachmentRecordCodec {
    enum State: Equatable { case live, deleted }

    static let zoneName = "meh-md-attachments-v1"
    static let recordType = "NotebookAttachmentV1"
    let zoneID = CKRecordZone.ID(zoneName: zoneName)

    func recordID(notebookID: UUID, attachmentID: UUID) -> CKRecord.ID {
        CKRecord.ID(
            recordName: "\(notebookID.uuidString)-\(attachmentID.uuidString)",
            zoneID: zoneID
        )
    }

    func liveRecord(
        _ descriptor: NotebookAttachmentDescriptor,
        notebookID: UUID, fileURL: URL
    ) -> CKRecord {
        let record = CKRecord(recordType: Self.recordType, recordID:
            recordID(notebookID: notebookID, attachmentID: descriptor.id))
        encodeIdentity(record, notebookID: notebookID,
            attachmentID: descriptor.id)
        record["sha256"] = descriptor.content.sha256 as CKRecordValue
        record["byteCount"] = descriptor.content.byteCount as CKRecordValue
        record["deleted"] = 0 as CKRecordValue
        record["asset"] = CKAsset(fileURL: fileURL)
        return record
    }

    func tombstone(
        _ record: CKRecord?, notebookID: UUID, attachmentID: UUID
    ) -> CKRecord {
        let result = record ?? CKRecord(recordType: Self.recordType,
            recordID: recordID(notebookID: notebookID,
                attachmentID: attachmentID))
        encodeIdentity(result, notebookID: notebookID,
            attachmentID: attachmentID)
        result["deleted"] = 1 as CKRecordValue
        result["asset"] = nil
        return result
    }

    func state(
        of record: CKRecord, notebookID: UUID, attachmentID: UUID
    ) throws -> State {
        guard record.recordType == Self.recordType,
              record.recordID == recordID(
                notebookID: notebookID, attachmentID: attachmentID),
              record["notebookID"] as? String == notebookID.uuidString,
              record["attachmentID"] as? String == attachmentID.uuidString,
              let deleted = record["deleted"] as? NSNumber,
              deleted.intValue == 0 || deleted.intValue == 1 else {
            throw NotebookAttachmentTransferError.mismatchedRecord
        }
        if deleted.intValue == 1 {
            guard case nil = record["asset"] else {
                throw NotebookAttachmentTransferError.mismatchedRecord
            }
            return .deleted
        }
        return .live
    }

    func assetURL(
        in record: CKRecord, descriptor: NotebookAttachmentDescriptor,
        notebookID: UUID
    ) throws -> URL {
        guard try state(of: record, notebookID: notebookID,
            attachmentID: descriptor.id) == .live else {
            throw NotebookAttachmentTransferError.deleted
        }
        guard record["sha256"] as? String == descriptor.content.sha256,
              (record["byteCount"] as? NSNumber)?.int64Value
                == descriptor.content.byteCount else {
            throw NotebookAttachmentTransferError.mismatchedRecord
        }
        guard let asset = record["asset"] as? CKAsset,
              let source = asset.fileURL else {
            throw NotebookAttachmentTransferError.missingAsset
        }
        return source
    }

    private func encodeIdentity(
        _ record: CKRecord, notebookID: UUID, attachmentID: UUID
    ) {
        record["notebookID"] = notebookID.uuidString as CKRecordValue
        record["attachmentID"] = attachmentID.uuidString as CKRecordValue
    }
}

/// One attachment occupies one stable record. Deletion replaces its asset with
/// a tombstone at that same identity, so a delayed upload cannot recreate it.
public actor CloudKitAttachmentTransport: NotebookAttachmentTransport {
    public nonisolated let scope: String

    static let zoneName = CloudKitAttachmentRecordCodec.zoneName
    static let recordType = CloudKitAttachmentRecordCodec.recordType
    private let container: CKContainer
    private let database: CKDatabase
    private let accountRecordName: String
    private let notebookZoneID: CKRecordZone.ID
    private let codec = CloudKitAttachmentRecordCodec()
    private let zoneID = CloudKitAttachmentRecordCodec().zoneID

    public static func make(
        containerIdentifier: String,
        expectedUserRecordName: String,
        notebookZoneName: String = "meh-md-notebook-v2"
    ) async throws -> CloudKitAttachmentTransport {
        let container = CKContainer(identifier: containerIdentifier)
        guard try await container.accountStatus() == .available else {
            throw NotebookAttachmentTransferError.accountUnavailable
        }
        let account = try await container.userRecordID().recordName
        guard account == expectedUserRecordName else {
            throw NotebookAttachmentTransferError.accountChanged
        }
        return CloudKitAttachmentTransport(
            containerIdentifier: containerIdentifier,
            container: container, accountRecordName: account,
            notebookZoneName: notebookZoneName
        )
    }

    private init(
        containerIdentifier: String,
        container: CKContainer,
        accountRecordName: String,
        notebookZoneName: String
    ) {
        self.container = container
        database = container.privateCloudDatabase
        self.accountRecordName = accountRecordName
        notebookZoneID = CKRecordZone.ID(zoneName: notebookZoneName)
        scope = "\(containerIdentifier)/private/\(accountRecordName)/\(Self.zoneName)"
    }

    public func upload(
        _ descriptor: NotebookAttachmentDescriptor,
        notebookID: UUID,
        from fileURL: URL
    ) async throws {
        try Task.checkCancellation()
        try await verifyAccount()
        try await verifyNotebookFormat()
        try await ensureZone()
        try await NotebookAttachmentStore(
            directory: fileURL.deletingLastPathComponent()
        ).verifyExternalFile(at: fileURL,
            expectedContent: descriptor.content)
        try Task.checkCancellation()
        let id = codec.recordID(notebookID: notebookID,
            attachmentID: descriptor.id)

        do {
            let existing = try await database.record(for: id)
            try await acknowledgeExisting(existing, descriptor: descriptor,
                notebookID: notebookID)
            try await verifyAccount()
            try await verifyNotebookFormat()
            try Task.checkCancellation()
            return
        } catch let error as CKError where error.code == .unknownItem {
            // The conditional save below resolves a concurrent create/delete.
        }

        // The caller retains this immutable staged file until upload returns.
        let record = codec.liveRecord(descriptor,
            notebookID: notebookID, fileURL: fileURL)
        do {
            _ = try await save(record)
        } catch let error as CKError where error.code == .serverRecordChanged {
            // CloudKit's serverRecordChanged payload may omit the asset URL.
            // Fetch the complete server record before acknowledging this retry.
            let server = try await database.record(for: id)
            try await acknowledgeExisting(server, descriptor: descriptor,
                notebookID: notebookID)
            try await verifyAccount()
        }
    }

    public func download(
        _ descriptor: NotebookAttachmentDescriptor,
        notebookID: UUID,
        to destination: URL
    ) async throws {
        try Task.checkCancellation()
        try await verifyAccount()
        try await verifyNotebookFormat()
        let record: CKRecord
        do {
            record = try await database.record(for: codec.recordID(
                notebookID: notebookID, attachmentID: descriptor.id))
        } catch let error as CKError where error.code == .unknownItem
            || error.code == .zoneNotFound {
            throw NotebookAttachmentTransferError.notUploaded
        }
        let source = try codec.assetURL(in: record,
            descriptor: descriptor, notebookID: notebookID)
        let stage = try NotebookAttachmentTransferStage.make(near: destination)
        defer { try? FileManager.default.removeItem(at: stage.directory) }
        _ = try await stage.store.storeFile(
            at: source, attachmentID: descriptor.id,
            expectedContent: descriptor.content
        )
        try await verifyAccount()
        try await verifyNotebookFormat()
        try Task.checkCancellation()
        do {
            try await stage.store.export(descriptor, to: destination)
        } catch NotebookAttachmentError.destinationExists {
            throw NotebookAttachmentTransferError.destinationExists
        }
    }

    public func delete(
        attachmentIDs: Set<UUID>, notebookID: UUID
    ) async throws {
        try Task.checkCancellation()
        try await verifyAccount()
        try await verifyNotebookFormat()
        try await ensureZone()
        for attachmentID in attachmentIDs.sorted(by: {
            $0.uuidString < $1.uuidString
        }) {
            try Task.checkCancellation()
            try await deleteOne(attachmentID, notebookID: notebookID)
        }
    }

    private func deleteOne(
        _ attachmentID: UUID, notebookID: UUID
    ) async throws {
        let id = codec.recordID(notebookID: notebookID,
            attachmentID: attachmentID)
        // A fresh fetch supplies the change tag for the conditional save.
        // A bounded retry lets a deletion win a concurrent first upload.
        for attempt in 0..<4 {
            var record: CKRecord
            do {
                record = try await database.record(for: id)
                if try codec.state(of: record, notebookID: notebookID,
                    attachmentID: attachmentID) == .deleted { return }
            } catch let error as CKError where error.code == .unknownItem {
                record = codec.tombstone(nil, notebookID: notebookID,
                    attachmentID: attachmentID)
            }
            record = codec.tombstone(record, notebookID: notebookID,
                attachmentID: attachmentID)
            do {
                _ = try await save(record)
                return
            } catch let error as CKError
                where error.code == .serverRecordChanged && attempt < 3 {
                continue
            }
        }
        throw NotebookAttachmentTransferError.unacknowledged
    }

    private func acknowledgeExisting(
        _ record: CKRecord,
        descriptor: NotebookAttachmentDescriptor,
        notebookID: UUID
    ) async throws {
        let source = try codec.assetURL(in: record,
            descriptor: descriptor, notebookID: notebookID)
        try await NotebookAttachmentStore(
            directory: source.deletingLastPathComponent()
        ).verifyExternalFile(at: source, expectedContent: descriptor.content)
    }

    private func save(_ record: CKRecord) async throws -> CKRecord {
        try Task.checkCancellation()
        try await verifyAccount()
        try await verifyNotebookFormat()
        try Task.checkCancellation()
        let results = try await database.modifyRecords(
            saving: [record], deleting: [],
            savePolicy: .ifServerRecordUnchanged
        ).saveResults
        guard let result = results[record.recordID] else {
            throw NotebookAttachmentTransferError.unacknowledged
        }
        let saved = try result.get()
        try await verifyAccount()
        try await verifyNotebookFormat()
        try Task.checkCancellation()
        return saved
    }

    private func verifyNotebookFormat() async throws {
        try Task.checkCancellation()
        let canonicalID = CKRecord.ID(
            recordName: CloudKitTransportMode.notebook.bootstrapName,
            zoneID: notebookZoneID
        )
        let canonical = try await database.record(for: canonicalID)
        try CloudKitNotebookFormatGate.read(canonical)
            .requireSupported()
        try Task.checkCancellation()
    }

    private func verifyAccount() async throws {
        guard try await container.accountStatus() == .available else {
            throw NotebookAttachmentTransferError.accountUnavailable
        }
        guard try await container.userRecordID().recordName
            == accountRecordName else {
            throw NotebookAttachmentTransferError.accountChanged
        }
    }

    private func ensureZone() async throws {
        let result = try await database.recordZones(for: [zoneID])[zoneID]
        if let result {
            switch result {
            case .success: return
            case let .failure(error):
                guard let error = error as? CKError,
                      error.code == .unknownItem || error.code == .zoneNotFound
                else { throw error }
            }
        }
        let saved = try await database.modifyRecordZones(
            saving: [CKRecordZone(zoneID: zoneID)], deleting: []
        ).saveResults[zoneID]
        guard let saved else {
            throw NotebookAttachmentTransferError.unacknowledged
        }
        _ = try saved.get()
    }

}
