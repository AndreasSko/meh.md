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

struct NotesWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Notes"
    static let description = IntentDescription("Shows Recents or one note.")

    @Parameter(title: "Show", default: .recents)
    var content: NotesWidgetContent

    // Edit Widget shows the count that fits the widget's size and
    // previews. Without an explicit `.stepper` it draws a text field that
    // ignores the range. The ranges repeat `MehWidgetRecentsLayout.most`;
    // small and medium with previews always show 3.
    @Parameter(title: "Number of Notes", default: 5, controlStyle: .stepper, inclusiveRange: (3, 5))
    var smallCount: Int

    @Parameter(title: "Number of Notes", default: 5, controlStyle: .stepper, inclusiveRange: (3, 6))
    var mediumCount: Int

    @Parameter(title: "Number of Notes", default: 5, controlStyle: .stepper, inclusiveRange: (3, 12))
    var largeCount: Int

    @Parameter(title: "Number of Notes", default: 5, controlStyle: .stepper, inclusiveRange: (3, 8))
    var largePreviewCount: Int

    @Parameter(title: "Show Previews", default: false)
    var previews: Bool

    @Parameter(title: "Note")
    var note: NoteEntity?

    static var parameterSummary: some ParameterSummary {
        When(\.$content, .equalTo, .note) {
            Summary("Show \(\.$content)") { \.$note }
        } otherwise: {
            When(\.$previews, .equalTo, true) {
                When(widgetFamily: .oneOf, [.systemLarge, .systemExtraLarge]) {
                    Summary("Show \(\.$content)") {
                        \.$largePreviewCount
                        \.$previews
                    }
                } otherwise: {
                    Summary("Show \(\.$content)") { \.$previews }
                }
            } otherwise: {
                Switch(.widgetFamily) {
                    Case(.systemSmall) {
                        Summary("Show \(\.$content)") {
                            \.$smallCount
                            \.$previews
                        }
                    }
                    Case(.systemMedium) {
                        Summary("Show \(\.$content)") {
                            \.$mediumCount
                            \.$previews
                        }
                    }
                    DefaultCase {
                        Summary("Show \(\.$content)") {
                            \.$largeCount
                            \.$previews
                        }
                    }
                }
            }
        }
    }

    func count(for size: MehWidgetRecentsLayout.Size) -> Int {
        switch (size, previews) {
        case (.small, false): smallCount
        case (.medium, false): mediumCount
        case (.large, false), (.extraLarge, false): largeCount
        case (.large, true), (.extraLarge, true): largePreviewCount
        case (.small, true), (.medium, true):
            MehWidgetRecentsLayout.most(previews: true, size: size)
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
