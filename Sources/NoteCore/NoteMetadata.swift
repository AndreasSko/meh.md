import Foundation

public struct NoteMetadata: Codable, Equatable, Sendable {
    public let createdAt: Date?
    public let modifiedAt: Date?

    public init(createdAt: Date?, modifiedAt: Date?) {
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    public static var unknown: NoteMetadata {
        NoteMetadata(createdAt: nil, modifiedAt: nil)
    }

    public static func now(_ date: Date = Date()) -> NoteMetadata {
        NoteMetadata(createdAt: date, modifiedAt: date)
    }
}

public extension NoteSnapshot {
    var metadata: NoteMetadata {
        get throws {
            try NoteDocument(snapshot: self).metadata
        }
    }
}

extension Date {
    var noteTimestamp: Date? {
        let milliseconds = (timeIntervalSince1970 * 1_000).rounded()
        // Leave headroom below Int64's limits because Automerge performs the
        // same floating-point-to-integer conversion at its FFI boundary.
        let safeIntegerLimit = 9_000_000_000_000_000_000.0
        guard milliseconds.isFinite,
              milliseconds > -safeIntegerLimit,
              milliseconds < safeIntegerLimit else {
            return nil
        }
        return Date(
            timeIntervalSince1970: Double(Int64(milliseconds)) / 1_000
        )
    }
}
