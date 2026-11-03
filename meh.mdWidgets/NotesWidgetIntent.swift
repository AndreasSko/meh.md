import AppIntents
import MehWidgetData
import WidgetKit

enum NotesWidgetContent: String, AppEnum {
    case recents
    case note

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Content"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .recents: "Recents",
        .note: "One Note",
    ]
}

enum NotesWidgetFilter: String, AppEnum {
    case pinnedAndRecent
    case pinnedOnly

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Notes"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .pinnedAndRecent: "Pinned & Recent",
        .pinnedOnly: "Pinned Only",
    ]
}

struct NotesWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Notes"
    static let description = IntentDescription("Shows Recents or one note.")

    @Parameter(title: "Show", default: .recents)
    var content: NotesWidgetContent

    @Parameter(title: "Notes", default: .pinnedAndRecent)
    var filter: NotesWidgetFilter

    @Parameter(title: "Note")
    var note: NoteEntity?

    static var parameterSummary: some ParameterSummary {
        When(\.$content, .equalTo, .note) {
            Summary("Show \(\.$content)") { \.$note }
        } otherwise: {
            Summary("Show \(\.$content)") { \.$filter }
        }
    }
}

struct NoteEntity: AppEntity {
    let id: UUID
    let title: String
    let folders: [String]

    init(_ note: MehWidgetSnapshot.Note) {
        id = note.id
        title = note.title
        folders = note.folders
    }

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Note"
    static let defaultQuery = NoteEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        if folders.isEmpty { return DisplayRepresentation(title: "\(title)") }
        return DisplayRepresentation(
            title: "\(title)", subtitle: "\(folders.joined(separator: " › "))"
        )
    }
}

/// The picker lists pins and recent notes first; search finds the rest.
struct NoteEntityQuery: EntityStringQuery {
    private var notes: [MehWidgetSnapshot.Note] {
        MehWidgetStore()?.load()?.notesForPicker ?? []
    }

    func entities(for identifiers: [UUID]) async throws -> [NoteEntity] {
        let wanted = Set(identifiers)
        return notes.filter { wanted.contains($0.id) }.map(NoteEntity.init)
    }

    func entities(matching string: String) async throws -> [NoteEntity] {
        notes.filter {
            $0.title.localizedStandardContains(string)
                || $0.folders.contains { $0.localizedStandardContains(string) }
        }.map(NoteEntity.init)
    }

    func suggestedEntities() async throws -> [NoteEntity] {
        notes.map(NoteEntity.init)
    }
}
