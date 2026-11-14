import Foundation

/// What the catalog remembers about one item. Unknown fields from a newer
/// version are ignored, and an unknown state makes this version leave the
/// item alone rather than import it again.
public struct NotebookIntegrationRecord: Codable, Equatable, Sendable {
    public static let active = "active"
    public static let removed = "removed"
    public static let deleted = "deleted"

    public var item: String
    public var note: UUID
    /// Hash of the item as last synced, to skip unchanged items cheaply.
    public var hash: String?
    /// Name and folder at the last sync, to tell whether the person has
    /// renamed or moved the note since.
    public var name: String?
    public var folder: UUID?
    public var state: String
    /// Notes created for the same item that lost to `note`.
    public var duplicates: [UUID]

    public init(
        item: String, note: UUID, hash: String?, name: String?, folder: UUID?,
        state: String, duplicates: [UUID] = []
    ) {
        self.item = item
        self.note = note
        self.hash = hash
        self.name = name
        self.folder = folder
        self.state = state
        self.duplicates = duplicates
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        item = try container.decode(String.self, forKey: .item)
        note = try container.decode(UUID.self, forKey: .note)
        hash = try container.decodeIfPresent(String.self, forKey: .hash)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        folder = try container.decodeIfPresent(UUID.self, forKey: .folder)
        state = try container.decode(String.self, forKey: .state)
        duplicates = try container.decodeIfPresent([UUID].self, forKey: .duplicates) ?? []
    }
}
