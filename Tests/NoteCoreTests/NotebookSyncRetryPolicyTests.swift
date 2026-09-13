import CloudKit
import XCTest
@testable import NoteCore

final class NotebookSyncRetryPolicyTests: XCTestCase {
    func testBackoffCapsAndSuccessResets() {
        var policy = NotebookSyncRetryPolicy()
        let now = Date(timeIntervalSince1970: 100)
        let error = URLError(.notConnectedToInternet)
        let delays = (0..<9).map { _ in
            policy.retryDate(for: error, now: now)!.timeIntervalSince(now)
        }
        XCTAssertEqual(delays, [5, 10, 20, 40, 80, 160, 300, 300, 300])
        policy.reset()
        XCTAssertEqual(policy.retryDate(for: error, now: now), now.addingTimeInterval(5))
    }

    func testServerDeadlineIsNeverShortened() {
        var policy = NotebookSyncRetryPolicy()
        let now = Date(timeIntervalSince1970: 100)
        let deadline = now.addingTimeInterval(600)
        XCTAssertEqual(policy.retryDate(for: CKError(.requestRateLimited), now: now,
                                        serverNotBefore: deadline), deadline)
    }

    func testPermanentFailuresAndCancellationDoNotLoop() {
        for error: any Error in [SyncError.scopeChanged, SyncError.invalidRecord,
                                  CloudKitSyncTransportError.corruptState,
                                  CloudKitSyncTransportError.accountUnavailable,
                                  CKError(.partialFailure),
                                  CancellationError()] {
            var policy = NotebookSyncRetryPolicy()
            XCTAssertNil(policy.retryDate(for: error, now: Date()))
            XCTAssertEqual(policy.failureCount, 0)
        }
    }
}
