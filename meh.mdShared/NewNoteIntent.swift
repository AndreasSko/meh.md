import AppIntents

/// Opens meh.md with a new note, from the New Note control. To open the
/// app, the system needs this type in both the app and the widget
/// extension. Only the app runs `perform()`; each target supplies its own
/// `openNewNote()`.
nonisolated struct NewNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "New Note"
    static let description = IntentDescription("Opens meh.md with a new note.")
    static let supportedModes: IntentModes = .foreground
    static let allowedExecutionTargets: IntentExecutionTargets = .main
    // Only the control uses it; Shortcuts gets its own actions.
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        await Self.openNewNote()
        return .result()
    }
}
