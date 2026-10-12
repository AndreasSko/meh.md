import Foundation
import NoteCore

/// Idle maintenance may wait for ordinary exchanges; note sync never waits
/// for its daily deadline. Unchanged incomparable copies are retried daily.
enum NotebookSnapshotMaintenancePolicy {
    nonisolated static func isDue(_ status: SyncSnapshotMaintenanceStatus,
                      now: Date = Date()) -> Bool {
        guard status.hasPendingCleanup else { return false }
        let dailyDeadlineReached = status.lastSuccessfulCleanup.map {
            now.timeIntervalSince($0) >= 24 * 60 * 60
        } ?? true
        let thresholdReached = status.hasNewSnapshotsSinceLastCleanup && (
            status.maximumSnapshotsPerDocument >= 10
            || status.retainedSnapshotBytes >= 16 * 1_024 * 1_024
        )
        return dailyDeadlineReached || thresholdReached
    }
}
