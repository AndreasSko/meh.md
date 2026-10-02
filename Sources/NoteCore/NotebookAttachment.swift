import Foundation

/// Identifies immutable file contents without putting their bytes into a
/// catalog, an import journal, or an Automerge document.
public struct NotebookAttachmentContent: Codable, Equatable, Sendable {
    public let sha256: String
    public let byteCount: Int64

    public init(sha256: String, byteCount: Int64) throws {
        guard byteCount >= 0,
            sha256.utf8.count == 64,
            sha256.utf8.allSatisfy({
                (48...57).contains($0) || (97...102).contains($0)
            })
        else { throw NotebookAttachmentError.invalidMetadata }
        self.sha256 = sha256
        self.byteCount = byteCount
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sha256: values.decode(String.self, forKey: .sha256),
            byteCount: values.decode(Int64.self, forKey: .byteCount)
        )
    }
}

/// Identity belongs to the notebook item. Equal contents do not combine two
/// separately imported items, and moving or renaming an item keeps its ID.
public struct NotebookAttachmentDescriptor: Codable, Equatable, Sendable {
    public let id: UUID
    public let content: NotebookAttachmentContent

    public init(id: UUID, content: NotebookAttachmentContent) {
        self.id = id
        self.content = content
    }
}

public enum NotebookAttachmentError: Error, Equatable, Sendable, LocalizedError {
    case invalidMetadata
    case unsupportedFormat
    case unsupportedSource
    case sourceChanged
    case missing(UUID)
    case identityConflict(UUID)
    case checksumMismatch
    case destinationExists
    case invalidStoredAttachment

    public var errorDescription: String? {
        switch self {
        case .invalidMetadata:
            "The attachment's checksum or size is invalid."
        case .unsupportedFormat:
            "This attachment was saved in an unsupported format. Update the app to open it."
        case .unsupportedSource:
            "Choose a regular file. Folders and symbolic links cannot be stored as attachments."
        case .sourceChanged:
            "The file changed while it was being copied. Try importing it again."
        case .missing:
            "This attachment is not available on this device."
        case .identityConflict:
            "Different contents already exist for this attachment. The saved file was left untouched."
        case .checksumMismatch:
            "The attachment's contents do not match its checksum or size."
        case .destinationExists:
            "A file already exists at the export destination. Choose another name."
        case .invalidStoredAttachment:
            "The saved attachment is damaged or incomplete. Its files were left untouched."
        }
    }
}
