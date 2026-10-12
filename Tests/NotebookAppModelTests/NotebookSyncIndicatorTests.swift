import XCTest
@testable import NotebookAppModel

final class NotebookSyncIndicatorTests: XCTestCase {
    func testAppManagedLocalSaveWaitUsesNeutralCloud() {
        let waiting = indicator(paused: true, pending: true, waitingForSave: true)
        XCTAssertEqual(waiting, .waiting)
        XCTAssertEqual(waiting.symbol, "icloud")
        XCTAssertEqual(indicator(waitingForSave: true), .waiting)
        XCTAssertEqual(indicator(syncing: true, waitingForSave: true), .syncing)
    }

    func testRealErrorsAndDisabledSyncOverrideLocalSaveWait() {
        XCTAssertEqual(
            indicator(paused: true, error: true, waitingForSave: true), .failed
        )
        XCTAssertEqual(
            indicator(enabled: false, paused: true, waitingForSave: true), .disabled
        )
    }

    func testPendingChangesAreNotAnError() {
        XCTAssertEqual(indicator(pending: true), .syncing)
        XCTAssertEqual(indicator(), .synced)
        XCTAssertEqual(indicator(error: true, pending: true), .failed)
    }

    func testActiveRetryReplacesOldErrorWithCurrentActivity() {
        XCTAssertEqual(indicator(syncing: true, error: true), .syncing)
        XCTAssertEqual(indicator(syncing: true), .syncing)
    }

    func testRetryDeadlineTakesPrecedenceOverActivity() {
        XCTAssertEqual(
            indicator(syncing: true, paused: true, error: true),
            .failed
        )
        XCTAssertEqual(indicator(paused: true, pending: true), .failed)
    }

    func testDisabledSyncTakesPrecedenceOverStaleActivityAndErrors() {
        XCTAssertEqual(indicator(enabled: false), .disabled)
        XCTAssertEqual(
            indicator(enabled: false, syncing: true, paused: true,
                      error: true, pending: true),
            .disabled
        )
    }

    private func indicator(
        enabled: Bool = true,
        syncing: Bool = false,
        paused: Bool = false,
        error: Bool = false,
        pending: Bool = false,
        waitingForSave: Bool = false
    ) -> NotebookSyncIndicator {
        NotebookSyncIndicator(
            isEnabled: enabled, isSyncing: syncing, isRetryPaused: paused,
            hasError: error, hasPendingChanges: pending,
            isWaitingForLocalSave: waitingForSave
        )
    }
}
