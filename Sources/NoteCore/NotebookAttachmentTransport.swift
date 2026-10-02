import Foundation

/// Transfers immutable attachment files independently of notebook snapshots.
public protocol NotebookAttachmentTransport: Sendable {
    var scope: String { get }

    func upload(
        _ descriptor: NotebookAttachmentDescriptor,
        notebookID: UUID,
        from fileURL: URL
    ) async throws

    func download(
        _ descriptor: NotebookAttachmentDescriptor,
        notebookID: UUID,
        to destination: URL
    ) async throws

    func delete(attachmentIDs: Set<UUID>, notebookID: UUID) async throws
}

public enum NotebookAttachmentTransferError: Error, Equatable, Sendable,
    LocalizedError {
    case accountUnavailable
    case accountChanged
    case notUploaded
    case deleted
    case mismatchedRecord
    case missingAsset
    case destinationExists
    case unacknowledged

    public var errorDescription: String? {
        switch self {
        case .accountUnavailable: "iCloud is unavailable."
        case .accountChanged: "The iCloud account changed during attachment sync."
        case .notUploaded: "This attachment has not reached iCloud yet."
        case .deleted: "This attachment was permanently deleted from iCloud."
        case .mismatchedRecord: "The iCloud attachment metadata does not match."
        case .missingAsset: "The iCloud attachment file is unavailable."
        case .destinationExists: "A file already exists at the destination."
        case .unacknowledged: "iCloud did not acknowledge the attachment change."
        }
    }
}

/// Uses the attachment store's streamed copy and checksum verification to
/// prepare a CKAsset or safely publish a fetched asset.
enum NotebookAttachmentTransferStage {
    static func make(near fileURL: URL) throws
        -> (directory: URL, store: NotebookAttachmentStore) {
        let directory = fileURL.deletingLastPathComponent()
            .appendingPathComponent("attachment-transfer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory,
            withIntermediateDirectories: false)
        return (directory, NotebookAttachmentStore(
            directory: directory.appendingPathComponent("files")))
    }
}
