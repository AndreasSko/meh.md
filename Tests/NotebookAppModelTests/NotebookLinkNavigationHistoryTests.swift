import Foundation
import XCTest

@testable import NotebookAppModel

@MainActor
final class NotebookLinkNavigationHistoryTests: XCTestCase {
    func testBackAndForwardPreserveRepeatedNoteVisitsAndPositions() {
        let history = NotebookLinkNavigationHistory()
        let note = UUID()
        let first = NotebookLinkNavigationHistory.Visit(
            noteID: note,
            position: Data([1])
        )
        let second = NotebookLinkNavigationHistory.Visit(
            noteID: note,
            position: Data([2])
        )
        let third = NotebookLinkNavigationHistory.Visit(
            noteID: UUID(),
            position: Data([3])
        )

        history.recordDeparture(first)
        history.recordDeparture(second)
        XCTAssertEqual(history.backTarget, second)

        XCTAssertEqual(history.commitBack(current: third), second)
        XCTAssertEqual(history.backTarget, first)
        XCTAssertEqual(history.forwardTarget, third)

        let returnedToSecond = history.commitForward(current: second)
        XCTAssertEqual(returnedToSecond, third)
        XCTAssertEqual(history.backTarget, second)
        XCTAssertNil(history.forwardTarget)
    }

    func testInspectingTargetDoesNotConsumeHistoryWhenNavigationFails() {
        let history = NotebookLinkNavigationHistory()
        let visit = NotebookLinkNavigationHistory.Visit(noteID: UUID())
        history.recordDeparture(visit)

        // Callers inspect the destination before attempting a potentially
        // failing save/open. Until commit, the pending target remains intact.
        XCTAssertEqual(history.backTarget, visit)
        XCTAssertEqual(history.backTarget, visit)
        XCTAssertNil(history.forwardTarget)
    }

    func testNewLinkVisitClearsForwardHistory() {
        let history = NotebookLinkNavigationHistory()
        let first = NotebookLinkNavigationHistory.Visit(noteID: UUID())
        let second = NotebookLinkNavigationHistory.Visit(noteID: UUID())
        let third = NotebookLinkNavigationHistory.Visit(noteID: UUID())

        history.recordDeparture(first)
        XCTAssertEqual(history.commitBack(current: second), first)
        XCTAssertEqual(history.forwardTarget, second)

        history.recordDeparture(third)

        XCTAssertEqual(history.backTarget, third)
        XCTAssertNil(history.forwardTarget)
    }

    func testNativeBackCanReturnAcrossSeveralVisits() {
        let history = NotebookLinkNavigationHistory()
        let project = NotebookLinkNavigationHistory.Visit(noteID: UUID(), position: Data([1]))
        let meeting = NotebookLinkNavigationHistory.Visit(noteID: UUID(), position: Data([2]))
        let person = NotebookLinkNavigationHistory.Visit(noteID: UUID(), position: Data([3]))
        history.recordDeparture(project)
        history.recordDeparture(meeting)

        XCTAssertNil(history.backTarget(steps: 0))
        XCTAssertNil(history.backTarget(steps: 3))
        XCTAssertEqual(history.backTarget(steps: 2), project)
        XCTAssertEqual(history.commitBack(current: person, steps: 2), project)
        XCTAssertNil(history.backTarget)
        XCTAssertEqual(history.forwardTarget, meeting)
        XCTAssertEqual(history.commitForward(current: project), meeting)
        XCTAssertEqual(history.forwardTarget, person)
    }

    func testStartingAnotherJourneyClearsBothDirections() {
        let history = NotebookLinkNavigationHistory()
        let first = NotebookLinkNavigationHistory.Visit(noteID: UUID())
        let second = NotebookLinkNavigationHistory.Visit(noteID: UUID())
        history.recordDeparture(first)
        history.recordDeparture(second)
        history.commitBack(current: .init(noteID: UUID()))
        XCTAssertNotNil(history.backTarget)
        XCTAssertNotNil(history.forwardTarget)

        history.clear()
        XCTAssertNil(history.backTarget)
        XCTAssertNil(history.forwardTarget)
        XCTAssertNil(history.commitBack(current: .init(noteID: UUID()), steps: 2))
    }

    func testHistoryIsBoundedAndCanBeClearedOnNotebookSwitch() {
        let history = NotebookLinkNavigationHistory(limit: 2)
        let visits = (0..<3).map { _ in
            NotebookLinkNavigationHistory.Visit(noteID: UUID())
        }

        visits.forEach(history.recordDeparture)

        XCTAssertEqual(history.backTarget, visits[2])
        XCTAssertEqual(history.commitBack(current: NotebookLinkNavigationHistory.Visit(
            noteID: UUID()
        )), visits[2])
        XCTAssertEqual(history.backTarget, visits[1])
        XCTAssertEqual(history.commitBack(current: visits[2]), visits[1])
        XCTAssertNil(history.backTarget)

        history.clear()
        XCTAssertNil(history.backTarget)
        XCTAssertNil(history.forwardTarget)
    }
}
