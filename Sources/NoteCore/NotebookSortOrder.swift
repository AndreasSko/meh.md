import Foundation

/// An explicit, one-time change to a folder's durable manual order.
public enum NotebookSortOrder: String, CaseIterable, Sendable {
    case nameAscending, nameDescending
    case createdNewest, createdOldest
    case modifiedNewest, modifiedOldest
}
