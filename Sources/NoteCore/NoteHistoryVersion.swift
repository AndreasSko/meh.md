import Foundation

/// A past body-text state retained by this note's Automerge history.
/// `id` identifies a causal frontier, not a wall-clock instant.
public struct NoteHistoryVersion: Identifiable, Equatable, Sendable {
    public let id: String
    /// The content date, or the recorded change time if that date did not
    /// advance. Legacy changes may have neither.
    public let date: Date?
    /// The last text state of an edit session. A session's other states
    /// appear once a reader loads its details.
    public let isOverviewStop: Bool
    /// Unicode scalars this state added and removed compared with the state
    /// before it in the index. Until a session's details load, its stop
    /// compares with the previous stop. History draws its timeline from
    /// these, without loading text.
    public let addedCharacters: Int
    public let removedCharacters: Int
    /// What the whole session added and removed, for its stop; zero for
    /// other states. Loading details does not change it.
    public let sessionAddedCharacters: Int
    public let sessionRemovedCharacters: Int

    init(
        id: String,
        date: Date?,
        isOverviewStop: Bool,
        addedCharacters: Int,
        removedCharacters: Int,
        sessionAddedCharacters: Int = 0,
        sessionRemovedCharacters: Int = 0
    ) {
        self.id = id
        self.date = date
        self.isOverviewStop = isOverviewStop
        self.addedCharacters = addedCharacters
        self.removedCharacters = removedCharacters
        self.sessionAddedCharacters = sessionAddedCharacters
        self.sessionRemovedCharacters = sessionRemovedCharacters
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
