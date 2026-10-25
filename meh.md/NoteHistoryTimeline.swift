import CoreGraphics
import Foundation
import NoteCore

/// History's timeline: edit sessions grouped by day on one line, with the
/// current text at its end. See docs/note-history.md.
struct NoteHistoryTimeline: Equatable {
    /// One tick: a run of versions that ends at an overview stop.
    struct Session: Equatable {
        let first: Int
        let last: Int
        let day: Date?
        let addedCharacters: Int
        let removedCharacters: Int
        var size: Int { addedCharacters + removedCharacters }
    }

    struct Day: Equatable {
        let day: Date?
        var sessions: Range<Int>
        /// Days without edits since the previous day, up to a week.
        var quietDaysBefore = 0
    }

    /// The selection along the timeline. `.current` is the live text.
    enum Item: Hashable {
        case session(Int)
        case current
    }

    private(set) var sessions: [Session] = []
    private(set) var days: [Day] = []
    private(set) var versionCount = 0
    /// Versions after the last stop are typing that continues into the
    /// current text, so they belong to the current item.
    private var openRunStart = 0
    private var openRunAdded = 0
    private var openRunRemoved = 0

    /// Published versions never change, so each index update only needs its
    /// new suffix.
    mutating func append(_ versions: [NoteHistoryVersion]) {
        guard versions.count > versionCount else {
            if versions.count < versionCount { self = .init(); append(versions) }
            return
        }
        let calendar = Calendar.current
        for index in versionCount ..< versions.count {
            let version = versions[index]
            openRunAdded += version.addedCharacters
            openRunRemoved += version.removedCharacters
            guard version.isOverviewStop else { continue }
            let day = version.date.map(calendar.startOfDay(for:))
            let session = Session(
                first: openRunStart, last: index, day: day,
                addedCharacters: openRunAdded, removedCharacters: openRunRemoved
            )
            if let lastDay = days.indices.last, days[lastDay].day == day {
                days[lastDay].sessions = days[lastDay].sessions.lowerBound
                    ..< sessions.count + 1
            } else {
                var quiet = 0
                if let previous = days.last?.day, let day {
                    let elapsed = calendar.dateComponents([.day], from: previous, to: day).day ?? 1
                    quiet = min(max(elapsed - 1, 0), 7)
                }
                days.append(Day(
                    day: day, sessions: sessions.count ..< sessions.count + 1,
                    quietDaysBefore: quiet
                ))
            }
            sessions.append(session)
            openRunStart = index + 1
            openRunAdded = 0
            openRunRemoved = 0
        }
        versionCount = versions.count
    }

    func item(containing versionIndex: Int) -> Item {
        guard versionIndex < openRunStart else { return .current }
        var low = 0
        var high = sessions.count - 1
        while low < high {
            let middle = (low + high) / 2
            if sessions[middle].last < versionIndex { low = middle + 1 } else { high = middle }
        }
        return .session(low)
    }

    /// Whether a version ends a session, or is the current text. Other
    /// versions are single states inside a session.
    func isSessionEnd(_ versionIndex: Int) -> Bool {
        switch item(containing: versionIndex) {
        case let .session(index): sessions[index].last == versionIndex
        case .current: versionIndex == versionCount
        }
    }

    /// The version an item shows: a session's final state, or the current
    /// text at `versionCount`.
    func versionIndex(of item: Item) -> Int {
        switch item {
        case let .session(index): sessions[index].last
        case .current: versionCount
        }
    }

    func day(of item: Item) -> Int? {
        guard case let .session(index) = item else { return nil }
        return dayIndex(ofSession: index)
    }

    func dayIndex(ofSession session: Int) -> Int {
        var low = 0
        var high = days.count - 1
        while low < high {
            let middle = (low + high) / 2
            if days[middle].sessions.upperBound <= session { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// Previous or next item, staying inside the timeline.
    func item(_ item: Item, movedBy offset: Int) -> Item {
        let position: Int
        switch item {
        case let .session(index): position = index
        case .current: position = sessions.count
        }
        let moved = min(max(position + offset, 0), sessions.count)
        return moved == sessions.count ? .current : .session(moved)
    }

    /// Where the session's changes start: the version before it, or none for
    /// the first one.
    func baseVersionIndex(ofSession index: Int) -> Int? {
        index == 0 ? nil : sessions[index - 1].last
    }
}

// MARK: - Layout

extension NoteHistoryTimeline {
    struct Metrics: Equatable {
        /// Tick distance inside the selected day, which spreads out.
        var spreadSpacing: CGFloat = 9
        /// The selected day never grows wider than this; its ticks move
        /// closer instead.
        var spreadWidth: CGFloat = 150
        var clusterSpacing: CGFloat = 3
        var clusterWidth: CGFloat = 24
        var dayGap: CGFloat = 12
        /// Extra room per quiet day between two days, up to a week.
        var quietDayGap: CGFloat = 3
        var selectedDayMargin: CGFloat = 12
        var currentGap: CGFloat = 16
        static let compact = Metrics()
        static let regular = Metrics(spreadSpacing: 11, spreadWidth: 280)
    }

    struct Layout: Equatable {
        var sessionX: [CGFloat]
        var currentX: CGFloat
        /// The span of each day's ticks, for its label and the selected
        /// day's background.
        var dayRanges: [ClosedRange<CGFloat>]

        func x(of item: Item) -> CGFloat {
            switch item {
            case let .session(index): sessionX[index]
            case .current: currentX
            }
        }

        /// The item closest to a position, for taps and hover.
        func item(nearest x: CGFloat) -> Item {
            if sessionX.isEmpty || x >= currentX { return .current }
            var low = 0
            var high = sessionX.count
            while low < high {
                let middle = (low + high) / 2
                if sessionX[middle] < x { low = middle + 1 } else { high = middle }
            }
            let next = low < sessionX.count ? sessionX[low] : currentX
            if low > 0, x - sessionX[low - 1] < next - x { return .session(low - 1) }
            return low < sessionX.count ? .session(low) : .current
        }
    }

    func layout(spreading selectedDay: Int?, metrics: Metrics) -> Layout {
        var sessionX = [CGFloat](repeating: 0, count: sessions.count)
        var dayRanges: [ClosedRange<CGFloat>] = []
        dayRanges.reserveCapacity(days.count)
        var x: CGFloat = 0
        for (dayIndex, day) in days.enumerated() {
            if dayIndex > 0 {
                x += gap(before: dayIndex, spreading: selectedDay, metrics: metrics)
            }
            let spacing = tickSpacing(in: dayIndex, spreading: selectedDay, metrics: metrics)
            let start = x
            for (offset, session) in day.sessions.enumerated() {
                sessionX[session] = start + CGFloat(offset) * spacing
            }
            x = start + CGFloat(max(day.sessions.count - 1, 0)) * spacing
            dayRanges.append(start ... x)
        }
        let currentX = sessions.isEmpty ? 0 : x + currentGap(spreading: selectedDay, metrics: metrics)
        return Layout(sessionX: sessionX, currentX: currentX, dayRanges: dayRanges)
    }

    /// The distance from a session to the item after it, the same as in
    /// `layout` but without laying out the whole timeline. Drags step with
    /// it on every move.
    func distance(
        afterSession session: Int, spreading selectedDay: Int?, metrics: Metrics
    ) -> CGFloat {
        let day = dayIndex(ofSession: session)
        if session + 1 < days[day].sessions.upperBound {
            return tickSpacing(in: day, spreading: selectedDay, metrics: metrics)
        }
        if day == days.count - 1 {
            return currentGap(spreading: selectedDay, metrics: metrics)
        }
        return gap(before: day + 1, spreading: selectedDay, metrics: metrics)
    }

    private func tickSpacing(in day: Int, spreading selectedDay: Int?, metrics: Metrics) -> CGFloat {
        let count = days[day].sessions.count
        guard count > 1 else { return 0 }
        return day == selectedDay
            ? min(metrics.spreadSpacing, metrics.spreadWidth / CGFloat(count - 1))
            : min(metrics.clusterSpacing, metrics.clusterWidth / CGFloat(count - 1))
    }

    private func gap(before day: Int, spreading selectedDay: Int?, metrics: Metrics) -> CGFloat {
        var gap = metrics.dayGap + CGFloat(days[day].quietDaysBefore) * metrics.quietDayGap
        if day == selectedDay || day - 1 == selectedDay { gap += metrics.selectedDayMargin }
        return gap
    }

    private func currentGap(spreading selectedDay: Int?, metrics: Metrics) -> CGFloat {
        metrics.currentGap + (selectedDay == days.count - 1 ? metrics.selectedDayMargin : 0)
    }

    /// Tick height for an edit size on a log scale, so one typo and a pasted
    /// page both stay readable.
    static func tickHeight(for size: Int, minimum: CGFloat = 5, maximum: CGFloat = 22) -> CGFloat {
        let fraction = min(1, log(1 + Double(size)) / log(1 + 1_000))
        return minimum + (maximum - minimum) * CGFloat(fraction)
    }
}
