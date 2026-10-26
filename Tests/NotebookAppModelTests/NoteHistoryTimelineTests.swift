import Foundation
import XCTest
import NoteCore
@testable import NotebookAppModel

#if DEBUG
@MainActor
final class NoteHistoryTimelineTests: XCTestCase {
    private let calendar = Calendar.current

    private func date(daysAgo: Int, hour: Int, minute: Int = 0) -> Date {
        let day = calendar.date(
            byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: .now))!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    /// Two edits on one day, a typed run the next day, then the current text.
    private func versions() async throws -> [NoteHistoryVersion] {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        let id = try await replica.createNote(name: "Trip.md", history: [
            .init(date: date(daysAgo: 5, hour: 9), text: "A\n"),
            .init(date: date(daysAgo: 5, hour: 18), text: "A\nB\n"),
            .init(date: date(daysAgo: 2, hour: 10), text: "A\nB\nhello\n", isTyped: true),
            .init(date: date(daysAgo: 1, hour: 8), text: "A\nhello\n"),
        ])
        return try await replica.openNote(id).loadHistoryVersions()
    }

    func testSessionsGroupTypingAndDays() async throws {
        let versions = try await versions()
        var timeline = NoteHistoryTimeline()
        timeline.append(versions)

        // Each replacement is a session. Typing "hello" is one more, and the
        // typed line break starts its own.
        XCTAssertEqual(timeline.sessions.count, 4)
        XCTAssertEqual(timeline.days.map(\.sessions), [0 ..< 2, 2 ..< 4])
        XCTAssertEqual(timeline.sessions[2].addedCharacters, 5)
        let typedRun = timeline.sessions[2]
        XCTAssertGreaterThan(typedRun.last, typedRun.first)
        XCTAssertEqual(timeline.item(containing: typedRun.first), .session(2))
        XCTAssertEqual(timeline.item(containing: versions.count), .current)
        XCTAssertEqual(timeline.versionIndex(of: .current), versions.count)
        XCTAssertEqual(timeline.baseVersionIndex(ofSession: 2), timeline.sessions[1].last)
        XCTAssertNil(timeline.baseVersionIndex(ofSession: 0))
        XCTAssertEqual(timeline.item(.session(3), movedBy: 1), .current)
        XCTAssertEqual(timeline.item(.session(0), movedBy: -1), .session(0))
    }

    func testAppendingPrefixesMatchesOneAppend() async throws {
        let versions = try await versions()
        var whole = NoteHistoryTimeline()
        whole.append(versions)
        var growing = NoteHistoryTimeline()
        for count in 0 ... versions.count {
            growing.append(Array(versions.prefix(count)))
        }
        XCTAssertEqual(growing, whole)
    }

    func testSelectedDaySpreadsWithinItsWidth() async throws {
        let versions = try await versions()
        var timeline = NoteHistoryTimeline()
        timeline.append(versions)
        let metrics = NoteHistoryTimeline.Metrics.compact
        let folded = timeline.layout(spreading: nil, metrics: metrics)
        let spread = timeline.layout(spreading: 0, metrics: metrics)

        XCTAssertEqual(folded.sessionX[1] - folded.sessionX[0], metrics.clusterSpacing)
        XCTAssertEqual(spread.sessionX[1] - spread.sessionX[0], metrics.spreadSpacing)
        XCTAssertEqual(spread.sessionX, spread.sessionX.sorted())
        XCTAssertGreaterThan(spread.currentX, spread.sessionX.last!)
        XCTAssertEqual(spread.item(nearest: spread.sessionX[1] + 1), .session(1))
        XCTAssertEqual(spread.item(nearest: spread.currentX + 50), .current)

        var busy = NoteHistoryTimeline.Metrics.compact
        busy.spreadWidth = 4
        let capped = timeline.layout(spreading: 0, metrics: busy)
        XCTAssertEqual(capped.dayRanges[0].upperBound - capped.dayRanges[0].lowerBound, 4)
    }

    func testStepDistanceMatchesTheLayout() async throws {
        let versions = try await versions()
        var timeline = NoteHistoryTimeline()
        timeline.append(versions)
        // Two days apart, with one quiet day between them.
        XCTAssertEqual(timeline.days.map(\.quietDaysBefore), [0, 2])
        let metrics = NoteHistoryTimeline.Metrics.compact
        for selectedDay in [nil, 0, 1] {
            let layout = timeline.layout(spreading: selectedDay, metrics: metrics)
            let positions = layout.sessionX + [layout.currentX]
            for session in timeline.sessions.indices {
                XCTAssertEqual(
                    timeline.distance(afterSession: session, spreading: selectedDay, metrics: metrics),
                    positions[session + 1] - positions[session],
                    "session \(session), selected day \(String(describing: selectedDay))"
                )
            }
        }
    }

    func testTickHeightGrowsWithEditSizeWithinBounds() {
        let sizes = [0, 1, 10, 100, 1_000, 100_000]
        let heights = sizes.map { NoteHistoryTimeline.tickHeight(for: $0) }
        XCTAssertEqual(heights, heights.sorted())
        XCTAssertEqual(heights.first, 5)
        XCTAssertEqual(heights.last, 22)
    }
}
#endif
