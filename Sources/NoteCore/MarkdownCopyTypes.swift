import Foundation

public enum MarkdownCopySnapshotError: Error, Equatable, LocalizedError {
    case invalidPersistedSnapshot

    public var errorDescription: String? {
        switch self {
        case .invalidPersistedSnapshot:
            "The saved note could not be read for the Markdown copy."
        }
    }
}

public struct MarkdownCopySnapshot: Equatable, Sendable {
    public let utf8: Data
    public let heads: Set<String>
    public let noteID: UUID

    public init(text: String, heads: Set<String>, noteID: UUID) {
        utf8 = Data(text.utf8)
        self.heads = heads
        self.noteID = noteID
    }

    public init(persisted snapshot: NoteSnapshot) throws {
        do {
            let document = try NoteDocument(snapshot: snapshot)
            self.init(
                text: try document.text,
                heads: snapshot.heads,
                noteID: snapshot.noteID
            )
        } catch {
            throw MarkdownCopySnapshotError.invalidPersistedSnapshot
        }
    }
}

public enum MarkdownCopyPause: Equatable, Sendable {
    case preexistingFile
    case unsafeDestination
    case destinationReplaced
}

public enum MarkdownCopyReport: Equatable, Sendable {
    case needsMaterialization
    case current(heads: Set<String>)
    case paused(MarkdownCopyPause)
}

public enum MarkdownCopyError: Error, Equatable, Sendable, LocalizedError {
    case invalidBookkeeping
    case unsupportedBookkeepingVersion
    case noteIdentityMismatch
    case fileSystem(operation: String, domain: String, code: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidBookkeeping:
            return "The Markdown copy state is damaged and could not be read."
        case .unsupportedBookkeepingVersion:
            return "The Markdown copy state was created by a newer version of meh.md."
        case .noteIdentityMismatch:
            return "The Markdown copy state belongs to a different note."
        case let .fileSystem(operation, domain, code):
            let detail = NSError(domain: domain, code: code)
                .localizedDescription
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if [NSCocoaErrorDomain, NSPOSIXErrorDomain].contains(domain),
               !detail.isEmpty {
                return "Could not \(operation): \(detail)"
            }
            return "Could not \(operation) (\(domain), code \(code))."
        }
    }
}
