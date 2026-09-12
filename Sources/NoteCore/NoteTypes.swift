import Foundation

public struct NoteSnapshot: Equatable, Sendable {
    public let data: Data
    public let heads: Set<String>
    public let noteID: UUID

    public init(data: Data, heads: Set<String>, noteID: UUID) {
        self.data = data
        self.heads = heads
        self.noteID = noteID
    }
}

public enum NoteFileFailure: Equatable, Sendable {
    case valid
    case absent
    case corrupt
    case unreadable
    case unsupportedSchemaVersion
}

public struct NoteRecovery: Equatable, Sendable {
    public let previous: NoteSnapshot
    public let currentFailure: NoteFileFailure
    let currentMarker: NoteFileMarker?

    public init(
        previous: NoteSnapshot,
        currentFailure: NoteFileFailure
    ) {
        self.previous = previous
        self.currentFailure = currentFailure
        currentMarker = nil
    }

    init(
        previous: NoteSnapshot,
        currentFailure: NoteFileFailure,
        currentMarker: NoteFileMarker
    ) {
        self.previous = previous
        self.currentFailure = currentFailure
        self.currentMarker = currentMarker
    }
}

enum NoteFileMarker: Equatable, Sendable {
    case absent
    case bytes(Data)
    case unreadable(String)
}

public struct NoteLoadFailure: Equatable, Sendable {
    public let current: NoteFileFailure
    public let previous: NoteFileFailure

    public init(
        current: NoteFileFailure,
        previous: NoteFileFailure
    ) {
        self.current = current
        self.previous = previous
    }
}

public enum NoteLoadResult: Equatable, Sendable {
    case firstLaunch
    case current(NoteSnapshot)
    case recoveryRequired(NoteRecovery)
    case blocked(NoteLoadFailure)
}

public protocol NoteStorage: Sendable {
    func load() async -> NoteLoadResult
    func save(_ snapshot: NoteSnapshot) async throws
    func recover(_ recovery: NoteRecovery) async throws -> NoteSnapshot
}
