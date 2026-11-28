import Foundation
import Observation

/// The timer behind Speaker Mode. It counts up, or down from a talk length
/// and then on into over time. It keeps start times instead of ticking, so
/// it stays right while the app is in the background.
@Observable
final class SpeakerTimer {
    /// The Settings › Labs key that offers Speaker Mode in the note menu.
    static let enabledKey = "labs.speakerMode"
    /// The talk length last picked on this device, in minutes. 0 is the
    /// stopwatch.
    static let lengthKey = "speaker.lengthMinutes"
    static let lengthRange = 1...60
    /// Dragging the length snaps to this many minutes; scrolling or a fine
    /// drag steps by one, down to the shortest length.
    static let lengthStep = 5
    /// The countdown turns to its last-minutes look at this many seconds,
    /// or halfway through a shorter talk, so it doesn't start in that look.
    static func lastMinutesThreshold(length: TimeInterval) -> TimeInterval {
        min(120, length / 2)
    }
    /// How long "time's up" shows 00:00 before over time counts on.
    static let timeUpDuration: TimeInterval = 3

    /// The talk length in minutes, or nil for the stopwatch. Set it with
    /// `setLength(_:)`, which keeps it in range.
    private(set) var lengthMinutes: Int?
    private(set) var startedAt: Date?
    private(set) var accumulated: TimeInterval = 0

    init(lengthMinutes: Int? = nil) {
        self.lengthMinutes = lengthMinutes.map(Self.clamped)
    }

    func setLength(_ minutes: Int?) {
        lengthMinutes = minutes.map(Self.clamped)
    }

    private static func clamped(_ minutes: Int) -> Int {
        min(max(minutes, lengthRange.lowerBound), lengthRange.upperBound)
    }

    var isRunning: Bool { startedAt != nil }
    /// Started since the last reset, even if paused now.
    var hasStarted: Bool { isRunning || accumulated > 0 }

    func elapsed(at now: Date) -> TimeInterval {
        guard let startedAt else { return accumulated }
        return accumulated + max(0, now.timeIntervalSince(startedAt))
    }

    func start(at now: Date) {
        guard startedAt == nil else { return }
        startedAt = now
    }

    func pause(at now: Date) {
        guard startedAt != nil else { return }
        accumulated = elapsed(at: now)
        startedAt = nil
    }

    func toggle(at now: Date) {
        if isRunning { pause(at: now) } else { start(at: now) }
    }

    func reset() {
        startedAt = nil
        accumulated = 0
    }

    func reading(at now: Date) -> SpeakerTimerReading {
        SpeakerTimerReading(
            elapsed: elapsed(at: now),
            length: lengthMinutes.map { TimeInterval($0 * 60) },
            isRunning: isRunning
        )
    }
}

/// What the island shows at one moment.
struct SpeakerTimerReading: Equatable {
    enum Phase: Equatable {
        case normal, lastMinutes, timeUp, overTime
    }

    let phase: Phase
    /// Whole seconds to show: elapsed when counting up, left in a
    /// countdown, or past the end in over time.
    let seconds: Int
    /// How much of the dial is drawn in highlighter, from 0 to 1. Counting
    /// up fills it once an hour, a minute at a time; a countdown starts
    /// full and unwinds to empty.
    let dialFraction: Double
    let isCountdown: Bool
    let isRunning: Bool
    let isPaused: Bool

    init(elapsed: TimeInterval, length: TimeInterval?, isRunning: Bool) {
        self.isRunning = isRunning
        isPaused = !isRunning && elapsed > 0
        guard let length, length > 0 else {
            isCountdown = false
            phase = .normal
            seconds = Int(elapsed.rounded(.down))
            dialFraction = min((elapsed / 60).rounded(.down) / 60, 1)
            return
        }
        isCountdown = true
        let remaining = length - elapsed
        if remaining > 0 {
            seconds = Int(remaining.rounded(.up))
            phase = remaining <= SpeakerTimer.lastMinutesThreshold(length: length)
                ? .lastMinutes : .normal
            dialFraction = min(remaining / length, 1)
        } else {
            let over = -remaining
            if over < SpeakerTimer.timeUpDuration {
                seconds = 0
                phase = .timeUp
            } else {
                seconds = Int(over.rounded(.down))
                phase = .overTime
            }
            dialFraction = 0
        }
    }

    /// "12:48", "1:02:03", or "+01:23" in over time.
    var text: String {
        (phase == .overTime ? "+" : "") + Self.clock(seconds)
    }

    static func clock(_ seconds: Int) -> String {
        let hours = seconds / 3600, minutes = seconds / 60 % 60, rest = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%02d:%02d", minutes, rest)
    }
}
