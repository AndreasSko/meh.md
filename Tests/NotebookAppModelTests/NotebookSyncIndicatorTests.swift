import XCTest
import NoteCore
@testable import NotebookAppModel

final class NotebookSyncIndicatorTests: XCTestCase {
    func testPendingChangesAreNotAnError() {
        XCTAssertEqual(indicator(pending: true), .waiting)
        XCTAssertEqual(indicator(), .idle)
        XCTAssertEqual(indicator(error: true, pending: true), .failed)
    }

    func testActiveRetryReplacesOldErrorWithCurrentActivity() {
        XCTAssertEqual(indicator(syncing: true, error: true), .checking)
        XCTAssertEqual(indicator(syncing: true, phase: .receiving), .receiving)
        XCTAssertEqual(indicator(syncing: true, phase: .uploadingNotes), .uploading)
        XCTAssertEqual(indicator(syncing: true, phase: .uploadingCatalog), .uploading)
        XCTAssertEqual(indicator(syncing: true, phase: .cleaningUp), .checking)
    }

    func testRetryDeadlineTakesPrecedenceOverActivity() {
        XCTAssertEqual(
            indicator(syncing: true, phase: .uploadingNotes, paused: true, error: true),
            .paused
        )
        XCTAssertEqual(indicator(paused: true, pending: true), .paused)
    }

    private func indicator(
        syncing: Bool = false,
        phase: NotebookSyncProgress.Phase? = nil,
        paused: Bool = false,
        error: Bool = false,
        pending: Bool = false
    ) -> NotebookSyncIndicator {
        NotebookSyncIndicator(
            isSyncing: syncing, phase: phase, isRetryPaused: paused,
            hasError: error, hasPendingChanges: pending
        )
    }
}
