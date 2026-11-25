import Foundation
import XCTest
@testable import NotebookAppModel

@MainActor
final class SpeakerTimerTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)

    func testLengthStaysInRange() {
        let timer = SpeakerTimer(lengthMinutes: 7)
        XCTAssertEqual(timer.lengthMinutes, 7)
        timer.setLength(1)
        XCTAssertEqual(timer.lengthMinutes, 5)
        timer.setLength(90)
        XCTAssertEqual(timer.lengthMinutes, 60)
        timer.setLength(nil)
        XCTAssertNil(timer.lengthMinutes)
    }

    func testStopwatchCountsUpAndFillsTheDialOncePerHour() {
        let timer = SpeakerTimer()
        timer.start(at: start)
        let reading = timer.reading(at: start + 30 * 60 + 59)
        XCTAssertFalse(reading.isCountdown)
        XCTAssertEqual(reading.phase, .normal)
        XCTAssertEqual(reading.text, "30:59")
        XCTAssertEqual(reading.dialFraction, 0.5)
        XCTAssertEqual(timer.reading(at: start + 3 * 3600).dialFraction, 1)
        XCTAssertEqual(timer.reading(at: start + 3723).text, "1:02:03")
    }

    func testCountdownPhases() {
        let timer = SpeakerTimer(lengthMinutes: 5)
        timer.start(at: start)

        let early = timer.reading(at: start + 0.5)
        XCTAssertEqual(early.phase, .normal)
        XCTAssertEqual(early.text, "05:00")

        let last = timer.reading(at: start + 180)
        XCTAssertEqual(last.phase, .lastMinutes)
        XCTAssertEqual(last.text, "02:00")
        XCTAssertEqual(last.dialFraction, 0.4, accuracy: 0.0001)

        let up = timer.reading(at: start + 301)
        XCTAssertEqual(up.phase, .timeUp)
        XCTAssertEqual(up.text, "00:00")
        XCTAssertEqual(up.dialFraction, 0)

        let over = timer.reading(at: start + 300 + 83)
        XCTAssertEqual(over.phase, .overTime)
        XCTAssertEqual(over.text, "+01:23")
    }

    func testPauseKeepsElapsedTimeAndResetClearsIt() {
        let timer = SpeakerTimer(lengthMinutes: 10)
        timer.start(at: start)
        timer.pause(at: start + 60)
        XCTAssertFalse(timer.isRunning)
        XCTAssertTrue(timer.hasStarted)

        let paused = timer.reading(at: start + 600)
        XCTAssertTrue(paused.isPaused)
        XCTAssertEqual(paused.text, "09:00")

        timer.toggle(at: start + 600)
        XCTAssertEqual(timer.reading(at: start + 630).text, "08:30")

        timer.reset()
        XCTAssertFalse(timer.hasStarted)
        XCTAssertEqual(timer.reading(at: start + 700).text, "10:00")
    }
}
