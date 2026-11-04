import Foundation

/// What the app shares with its widgets. Widgets cannot open the notebook,
/// so the app writes this small copy whenever Recents or a shown note
/// changes.
public struct MehWidgetSnapshot: Codable, Equatable, Sendable {
    public struct Note: Codable, Equatable, Sendable, Identifiable {
        public let id: UUID
        public let title: String
        /// Folder names from the top of the library down to the note.
        public let folders: [String]

        public init(id: UUID, title: String, folders: [String]) {
            self.id = id
            self.title = title
            self.folders = folders
        }
    }

    public struct Recent: Codable, Equatable, Sendable {
        public let id: UUID
        public let isPinned: Bool

        public init(id: UUID, isPinned: Bool) {
            self.id = id
            self.isPinned = isPinned
        }
    }

    /// The start of a note, for excerpts and the One note widget.
    public struct Content: Codable, Equatable, Sendable {
        public let id: UUID
        /// The Markdown source, cut after the first few lines.
        public let text: String
        /// One plain line, the same one the app's Recents shows.
        public let excerpt: String
        public let modifiedAt: Date?

        public init(id: UUID, text: String, excerpt: String, modifiedAt: Date?) {
            self.id = id
            self.text = text
            self.excerpt = excerpt
            self.modifiedAt = modifiedAt
        }
    }

    public struct Row: Equatable, Sendable, Identifiable {
        public let note: Note
        public let isPinned: Bool
        public let content: Content?

        public var id: UUID { note.id }
    }

    /// Every note in the library, for the widget's note picker.
    public let notes: [Note]
    /// Recents in the app's order: pins first, then the newest notes.
    public let recents: [Recent]
    public let contents: [Content]
    /// The chosen pens, as stored in Settings > Appearance.
    public let ink: String
    public let highlighter: String

    public init(
        notes: [Note], recents: [Recent], contents: [Content],
        ink: String, highlighter: String
    ) {
        self.notes = notes
        self.recents = recents
        self.contents = contents
        self.ink = ink
        self.highlighter = highlighter
    }

    public func note(_ id: UUID) -> Note? {
        notes.first { $0.id == id }
    }

    public func content(_ id: UUID) -> Content? {
        contents.first { $0.id == id }
    }

    /// The rows a Recents widget shows, cut at the widget's size.
    public func recentRows(limit: Int) -> [Row] {
        Array(recents.lazy
            .compactMap { recent in
                note(recent.id).map {
                    Row(note: $0, isPinned: recent.isPinned, content: content(recent.id))
                }
            }
            .prefix(max(0, limit)))
    }

    /// Pins and recent notes first, then the rest of the library by title,
    /// so the note picker starts with the notes people use.
    public var notesForPicker: [Note] {
        let recentIDs = recents.map(\.id)
        let first = recentIDs.compactMap(note)
        let shown = Set(recentIDs)
        let rest = notes.filter { !shown.contains($0.id) }.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        return first + rest
    }
}
