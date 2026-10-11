import Foundation

public struct NotebookSyncProgress: Equatable, Sendable {
    public enum Phase: String, Equatable, Sendable {
        case checking
        case receiving
        case checkingRemoteHistory
        case comparing
        case uploadingNotes
        case uploadingCatalog
        case cleaningUp
        case cleaningUpSnapshots
        case finalizing

        /// Fixed work budgets for one exchange, not estimates of elapsed time.
        var range: ClosedRange<Double> {
            switch self {
            case .checking: 0...0.20
            case .receiving, .checkingRemoteHistory: 0.20...0.50
            case .comparing: 0.50...0.55
            case .uploadingNotes: 0.55...0.78
            case .uploadingCatalog: 0.78...0.80
            case .cleaningUp: 0.80...0.85
            case .cleaningUpSnapshots: 0.85...0.98
            case .finalizing: 0.98...1
            }
        }
    }

    public let phase: Phase
    public let receivedRecords: Int
    public let completedNotes: Int
    public let totalNotes: Int
    public let activeNoteIDs: [UUID]
    public let cleanupItemCount: Int
    public let lastProgressAt: Date
    public let overallFraction: Double?
    public let completedUnits: Int?
    public let totalUnits: Int?
    public let waitingSince: Date?

    public init(
        phase: Phase,
        receivedRecords: Int,
        completedNotes: Int,
        totalNotes: Int,
        lastProgressAt: Date,
        activeNoteIDs: [UUID] = [],
        cleanupItemCount: Int = 0,
        overallFraction: Double? = nil,
        completedUnits: Int? = nil,
        totalUnits: Int? = nil,
        waitingSince: Date? = nil
    ) {
        self.phase = phase
        self.receivedRecords = receivedRecords
        self.completedNotes = completedNotes
        self.totalNotes = totalNotes
        self.activeNoteIDs = activeNoteIDs
        self.cleanupItemCount = cleanupItemCount
        self.lastProgressAt = lastProgressAt
        self.overallFraction = overallFraction
        self.completedUnits = completedUnits
        self.totalUnits = totalUnits
        self.waitingSince = waitingSince
    }
}

/// An exchange keeps its budgets fixed even when pages, skipped uploads or
/// newly edited notes change the amount of work discovered along the way.
struct NotebookSyncProgressMeter {
    private(set) var fraction: Double?

    mutating func advance(
        phase: NotebookSyncProgress.Phase, completion: Double? = nil
    ) -> Double? {
        guard phase != .checking || completion != nil || fraction != nil else {
            return nil
        }
        let range = phase.range
        let bounded = min(1, max(0, completion ?? 0))
        let candidate = range.lowerBound
            + (range.upperBound - range.lowerBound) * bounded
        // Only the coordinator's successful final checkpoint can reach 100%.
        fraction = max(fraction ?? 0, min(0.99, candidate))
        return fraction
    }

    mutating func finish() { fraction = 1 }
}
