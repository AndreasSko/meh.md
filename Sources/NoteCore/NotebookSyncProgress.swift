import Foundation

public struct NotebookSyncProgress: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case checking
        case receiving
        case uploadingNotes
        case uploadingCatalog
    }

    public let phase: Phase
    public let receivedRecords: Int
    public let completedNotes: Int
    public let totalNotes: Int
    public let lastProgressAt: Date

    public init(
        phase: Phase,
        receivedRecords: Int,
        completedNotes: Int,
        totalNotes: Int,
        lastProgressAt: Date
    ) {
        self.phase = phase
        self.receivedRecords = receivedRecords
        self.completedNotes = completedNotes
        self.totalNotes = totalNotes
        self.lastProgressAt = lastProgressAt
    }
}
