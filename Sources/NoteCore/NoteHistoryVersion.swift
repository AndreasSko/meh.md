import Foundation

/// A past body-text state retained by this note's Automerge history.
/// `id` identifies a causal frontier, not a wall-clock instant.
public struct NoteHistoryVersion: Identifiable, Equatable, Sendable {
    public let id: String
    public let ordinal: Int
    public let date: Date?
    /// The last recorded text state in a short typing run before another
    /// run. Raw versions remain available through More Detail.
    public let isOverviewStop: Bool

    init(
        id: String,
        ordinal: Int,
        date: Date?,
        isOverviewStop: Bool
    ) {
        self.id = id
        self.ordinal = ordinal
        self.date = date
        self.isOverviewStop = isOverviewStop
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
