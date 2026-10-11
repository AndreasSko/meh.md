import XCTest
@testable import NoteCore

final class NotebookSyncProgressMeterTests: XCTestCase {
    func testUnknownInitialWaitHasNoFractionAndLaterWaitKeepsEarnedWork() {
        var meter = NotebookSyncProgressMeter()
        XCTAssertNil(meter.advance(phase: .checking))
        XCTAssertEqual(meter.advance(phase: .checking, completion: 0.5), 0.1)
        XCTAssertEqual(meter.advance(phase: .receiving), 0.2)
        XCTAssertEqual(meter.advance(phase: .receiving), 0.2)
    }

    func testFinalPageAndFollowingPhasesNeverResetProgress() throws {
        var meter = NotebookSyncProgressMeter()
        let checking = try XCTUnwrap(meter.advance(phase: .checking, completion: 1))
        let receiving = try XCTUnwrap(meter.advance(phase: .receiving, completion: 0.5))
        XCTAssertEqual(receiving, 0.35, accuracy: 0.0001)
        let compared = try XCTUnwrap(meter.advance(phase: .comparing))
        XCTAssertGreaterThanOrEqual(receiving, checking)
        XCTAssertGreaterThanOrEqual(compared, receiving)
        let sending = try XCTUnwrap(meter.advance(phase: .uploadingNotes, completion: 0.5))
        XCTAssertGreaterThanOrEqual(sending, compared)
        // A changed cleanup denominator cannot reverse work already credited.
        let cleanup = try XCTUnwrap(meter.advance(phase: .cleaningUpSnapshots, completion: 0.75))
        XCTAssertEqual(meter.advance(phase: .cleaningUpSnapshots, completion: 0.25), cleanup)
    }

    func testOnlySuccessfulFinishCanReachOneAndNewPassResets() {
        var meter = NotebookSyncProgressMeter()
        XCTAssertEqual(meter.advance(phase: .finalizing, completion: 1), 0.99)
        meter.finish()
        XCTAssertEqual(meter.fraction, 1)
        meter = NotebookSyncProgressMeter()
        XCTAssertNil(meter.advance(phase: .checking))
    }
}
