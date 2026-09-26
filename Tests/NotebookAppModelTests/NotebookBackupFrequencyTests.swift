import Foundation
import XCTest

@testable import NotebookAppModel

@MainActor
final class NotebookBackupFrequencyTests: XCTestCase {
    func testCalendarSchedulesAndOff() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 25, hour: 9
        ))!

        XCTAssertNil(NotebookBackupFrequency.off.nextDate(
            after: start, calendar: calendar
        ))
        XCTAssertEqual(NotebookBackupFrequency.daily.nextDate(
            after: start, calendar: calendar
        ), calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 26, hour: 9
        )))
        XCTAssertEqual(NotebookBackupFrequency.weekly.nextDate(
            after: start, calendar: calendar
        ), calendar.date(from: DateComponents(
            year: 2026, month: 10, day: 2, hour: 9
        )))
        XCTAssertEqual(NotebookBackupFrequency.monthly.nextDate(
            after: start, calendar: calendar
        ), calendar.date(from: DateComponents(
            year: 2026, month: 10, day: 25, hour: 9
        )))
    }
}
