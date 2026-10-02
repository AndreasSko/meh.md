import Foundation

/// A read-only snapshot of active note structure and locally available text.
/// Unavailable bodies are explicit so link tools cannot treat them as empty.
public struct NotebookLinkCorpus: Sendable {
    public let notes: [NotebookLinkNote]
    public let texts: [UUID: String]
    public let unavailableIDs: Set<UUID>
    public let editorRevisions: [UUID: Data]

    public init(notes: [NotebookLinkNote], texts: [UUID: String],
                unavailableIDs: Set<UUID>, editorRevisions: [UUID: Data] = [:]) {
        self.notes = notes
        self.texts = texts
        self.unavailableIDs = unavailableIDs
        self.editorRevisions = editorRevisions
    }
}

enum NotebookLinkLocationStage: Equatable {
    case beforeCatalogSave
    case catalogSaved
}
