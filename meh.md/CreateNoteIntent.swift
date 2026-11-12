import AppIntents
import MehWidgetData

/// The Create Note action in Shortcuts: adds a note without opening the
/// app and returns a link that opens it.
struct CreateNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Create Note"
    static let description = IntentDescription(
        "Adds a note to the folder for new notes, without opening meh.md. Returns a link that opens the note."
    )
    static let supportedModes: IntentModes = .background
    // Only the app may open the notebook.
    static let allowedExecutionTargets: IntentExecutionTargets = .main

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true))
    var text: String

    @Parameter(
        title: "Name",
        description: "Leave empty to name the note after today’s date, like a new note in the app."
    )
    var name: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Create note with \(\.$text)") {
            \.$name
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<URL> {
        let id: UUID
        do {
            id = try await Self.createNote(text: text, name: name)
        } catch {
            throw CreateNoteError(message: error.localizedDescription)
        }
        return .result(value: MehWidgetLink.note(id).url)
    }

    @MainActor
    private static func createNote(text: String, name: String?) async throws -> UUID {
        let workspace = NotebookWorkspace.shared
        let id = try await workspace.createNote(text: text, name: name)
        // Now, as the system may suspend the app right after the action.
        if let replica = workspace.replica {
            NotebookWidgetSnapshotWriter.shared.flush(replica)
        }
        return id
    }
}

/// Shortcuts shows only errors it can convert, so this carries the app's
/// message, such as why a name isn't allowed.
struct CreateNoteError: Error, CustomLocalizedStringResourceConvertible {
    let message: String

    var localizedStringResource: LocalizedStringResource {
        LocalizedStringResource(String.LocalizationValue(message))
    }
}

struct MehShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CreateNoteIntent(),
            phrases: [
                "Create a note in \(.applicationName)",
                "Add a note to \(.applicationName)",
            ],
            shortTitle: "Create Note",
            systemImageName: "square.and.pencil"
        )
    }
}
