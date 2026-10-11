import Foundation

public struct NotebookSyncProgress: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case checking
        case receiving
        case uploadingNotes
        case uploadingCatalog
        case cleaningUp
        case cleaningUpSnapshots
    }

    public let phase: Phase
    public let receivedRecords: Int
    public let completedNotes: Int
    public let totalNotes: Int
    public let activeNoteIDs: [UUID]
    public let cleanupItemCount: Int
    public let lastProgressAt: Date

    public init(
        phase: Phase,
        receivedRecords: Int,
        completedNotes: Int,
        totalNotes: Int,
        lastProgressAt: Date,
        activeNoteIDs: [UUID] = [],
        cleanupItemCount: Int = 0
    ) {
        self.phase = phase
        self.receivedRecords = receivedRecords
        self.completedNotes = completedNotes
        self.totalNotes = totalNotes
        self.activeNoteIDs = activeNoteIDs
        self.cleanupItemCount = cleanupItemCount
        self.lastProgressAt = lastProgressAt
    }
}
