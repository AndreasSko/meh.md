import Foundation
import NoteCore
import XCTest
@testable import NotebookAppModel

final class NotebookSnapshotMaintenancePolicyTests: XCTestCase {
    func testCopiesWaitForThresholdAndUnchangedGroupsWaitForDailyDeadline() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func status(copies: Int, bytes: Int = 0, changed: Bool = true,
                    age: TimeInterval = 60, pending: Bool = true)
            -> SyncSnapshotMaintenanceStatus {
            SyncSnapshotMaintenanceStatus(
                lastSuccessfulCleanup: now.addingTimeInterval(-age),
                maximumSnapshotsPerDocument: copies,
                retainedSnapshotBytes: bytes, hasPendingCleanup: pending,
                hasNewSnapshotsSinceLastCleanup: changed
            )
        }
        XCTAssertFalse(NotebookSnapshotMaintenancePolicy.isDue(
            status(copies: 9), now: now))
        XCTAssertTrue(NotebookSnapshotMaintenancePolicy.isDue(
            status(copies: 10), now: now))
        XCTAssertTrue(NotebookSnapshotMaintenancePolicy.isDue(
            status(copies: 2, bytes: 16 * 1_024 * 1_024), now: now))
        XCTAssertFalse(NotebookSnapshotMaintenancePolicy.isDue(
            status(copies: 100, changed: false), now: now))
        XCTAssertTrue(NotebookSnapshotMaintenancePolicy.isDue(
            status(copies: 2, changed: false, age: 86_400), now: now))
        XCTAssertFalse(NotebookSnapshotMaintenancePolicy.isDue(
            status(copies: 100, age: 86_400, pending: false), now: now))
    }
    func testFirstCleanupAndExactThresholdBoundaries() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let neverCleaned = SyncSnapshotMaintenanceStatus(
            lastSuccessfulCleanup: nil, maximumSnapshotsPerDocument: 2,
            retainedSnapshotBytes: 1, hasPendingCleanup: true
        )
        XCTAssertTrue(NotebookSnapshotMaintenancePolicy.isDue(neverCleaned, now: now))
        let belowByteThreshold = SyncSnapshotMaintenanceStatus(
            lastSuccessfulCleanup: now.addingTimeInterval(-86_399),
            maximumSnapshotsPerDocument: 9,
            retainedSnapshotBytes: 16 * 1_024 * 1_024 - 1,
            hasPendingCleanup: true
        )
        XCTAssertFalse(NotebookSnapshotMaintenancePolicy.isDue(
            belowByteThreshold, now: now))
    }

    func testPolicyCanRunOutsideMainActor() async {
        let due = await Task.detached {
            let status = SyncSnapshotMaintenanceStatus(
                lastSuccessfulCleanup: nil, maximumSnapshotsPerDocument: 2,
                retainedSnapshotBytes: 1, hasPendingCleanup: true
            )
            return NotebookSnapshotMaintenancePolicy.isDue(status)
        }.value
        XCTAssertTrue(due)
    }
}
