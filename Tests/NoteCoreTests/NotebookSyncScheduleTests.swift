import XCTest
@testable import NoteCore

final class NotebookSyncScheduleTests: XCTestCase {
    func testNoTypingUsesShortCoalescingDelay() {
        var schedule = NotebookSyncSchedule()
        schedule.request(at: .zero)
        XCTAssertEqual(schedule.delay(at: .zero), .milliseconds(750))
    }

    func testTypingResetsIdleDelay() {
        var schedule = NotebookSyncSchedule()
        schedule.noteEdited(at: .zero)
        schedule.request(at: .zero)
        schedule.noteEdited(at: .milliseconds(500))

        XCTAssertEqual(schedule.delay(at: .milliseconds(500)), .seconds(10))
    }

    func testRepeatedRequestsDoNotExtendMaximumDelay() {
        var schedule = NotebookSyncSchedule()
        schedule.request(at: .zero)
        schedule.request(at: .seconds(50))
        schedule.request(at: .seconds(59))
        schedule.noteEdited(at: .seconds(59))

        XCTAssertEqual(schedule.delay(at: .seconds(59)), .seconds(1))
    }

    func testEditingAloneDoesNotCreatePendingWork() {
        var schedule = NotebookSyncSchedule()
        schedule.noteEdited(at: .seconds(4))

        XCTAssertFalse(schedule.hasPending)
        XCTAssertNil(schedule.delay(at: .seconds(4)))
        XCTAssertFalse(schedule.takePending())
    }

    func testRequestAfterLongIdleWaitsForCoalescing() {
        var schedule = NotebookSyncSchedule()
        schedule.noteEdited(at: .zero)
        schedule.request(at: .seconds(30))

        XCTAssertEqual(schedule.delay(at: .seconds(30)), .milliseconds(750))
        let coalescedTime = Duration.seconds(30) + .milliseconds(750)
        XCTAssertEqual(schedule.delay(at: coalescedTime), .zero)
    }

    func testTakingPendingWorkKeepsLastEditForNextPass() {
        var schedule = NotebookSyncSchedule()
        schedule.noteEdited(at: .zero)
        schedule.request(at: .zero)

        XCTAssertTrue(schedule.takePending())
        XCTAssertFalse(schedule.hasPending)

        schedule.request(at: .seconds(9))
        XCTAssertEqual(schedule.delay(at: .seconds(9)), .seconds(1))
    }
}
