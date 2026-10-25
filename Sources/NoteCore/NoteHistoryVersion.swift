import Foundation

/// A past body-text state retained by this note's Automerge history.
/// `id` identifies a causal frontier, not a wall-clock instant.
public struct NoteHistoryVersion: Identifiable, Equatable, Sendable {
    public let id: String
    public let ordinal: Int
    /// The content date, or the recorded change time if that date did not
    /// advance. Legacy changes may have neither.
    public let date: Date?
    /// The last recorded text state in a short typing run before another
    /// run. Raw versions remain available through More Detail.
    public let isOverviewStop: Bool
    /// Unicode scalars this state added and removed compared with the state
    /// before it. History draws its timeline from these, without loading text.
    public let addedCharacters: Int
    public let removedCharacters: Int

    init(
        id: String,
        ordinal: Int,
        date: Date?,
        isOverviewStop: Bool,
        addedCharacters: Int,
        removedCharacters: Int
    ) {
        self.id = id
        self.ordinal = ordinal
        self.date = date
        self.isOverviewStop = isOverviewStop
        self.addedCharacters = addedCharacters
        self.removedCharacters = removedCharacters
    }
}

public enum NoteHistoryError: Error, Equatable, LocalizedError {
    case currentChanged
    case versionUnavailable

    public var errorDescription: String? {
        switch self {
        case .currentChanged:
            "This note changed while you were browsing its history. Review the current text before restoring."
        case .versionUnavailable:
            "That version is no longer available in this note."
        }
    }
}
