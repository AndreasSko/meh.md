import CryptoKit
import Foundation
import NoteCore
import Observation

/// Device-local guidance. Choosing examples is the only path that adds them.
@MainActor
@Observable
final class NotebookWelcomeState {
    enum Choice: Equatable {
        case newNote, examples, importNotes
    }

    private(set) var isPresented = false
    private(set) var requestID = 0
    @ObservationIgnored private var pendingChoice: Choice?
    @ObservationIgnored private var prepared = false
    @ObservationIgnored private var installingExamples = false
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let store: UserDefaults
    @ObservationIgnored private let storageKey: String

    init(directory: URL, store: UserDefaults = .standard) {
        self.directory = directory
        self.store = store
        let scope = SHA256.hash(data: Data(directory.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        storageKey = "meh.md.welcome.\(scope)"
    }

    func prepare(enabled: Bool) {
        guard !prepared else { return }
        prepared = true
        guard enabled, !store.bool(forKey: storageKey) else { return }
        let storage = NotebookCatalogStorage(directory: directory)
        // Existing and damaged notebooks keep their ordinary opening/recovery
        // flow. Upgrading the app must never put a tour in front of your notes.
        let existing = [storage.currentURL, storage.previousURL].contains {
            FileManager.default.fileExists(atPath: $0.path)
        }
        if existing {
            store.set(true, forKey: storageKey)
        } else {
            isPresented = true
        }
    }

    func show() { isPresented = true }

    func dismiss() {
        store.set(true, forKey: storageKey)
        isPresented = false
    }

    func choose(_ choice: Choice) {
        guard pendingChoice == nil else { return }
        pendingChoice = choice
        requestID += 1
        dismiss()
    }

    func takeChoice() -> Choice? {
        defer { pendingChoice = nil }
        return pendingChoice
    }

    /// Keep random identities through retries. Reopening examples never
    /// replaces an edited body, repeats an import, or resets template defaults.
    func installExamples(in replica: NotebookReplica) async throws -> UUID {
        guard !installingExamples else { throw NotebookReplicaError.busy }
        guard let notebookID = replica.catalogSnapshot?.notebookID else {
            throw NotebookReplicaError.notJoined
        }
        guard !replica.hasPendingImport else {
            throw NotebookImportError.pendingImportExists
        }
        installingExamples = true
        defer { installingExamples = false }
        let key = storageKey + ".examples.\(notebookID.uuidString)"
        var examples: NotebookWelcomeExamples
        if let data = store.data(forKey: key) {
            examples = try JSONDecoder().decode(NotebookWelcomeExamples.self, from: data)
        } else {
            examples = NotebookWelcomeExamples()
            store.set(try JSONEncoder().encode(examples), forKey: key)
        }
        let existing = Set(replica.placements.map(\.item.id))
        let expected = Set(examples.plan.entries.map(\.id))
        if !expected.isSubset(of: existing) {
            // A durable interrupted import is resumed by the normal importer.
            // Its saved snapshots, rather than a new plan, own that recovery.
            try await replica.importMarkdown(examples.plan)
        }
        guard replica.placements.contains(where: {
            $0.item.id == examples.introductionID && !$0.isInTrash
                && !$0.item.isPermanentlyDeleted
        }) else { throw NotebookWelcomeExamplesError.unavailable }
        if !examples.completed {
            try await replica.setTemplateSource(examples.templateID, enabled: true)
            try await replica.setTemplateSettings(
                .init(destination: .root,
                      filenamePattern: "{{date}} - {{template}}"),
                for: examples.templateID
            )
            examples.completed = true
            store.set(try JSONEncoder().encode(examples), forKey: key)
        }
        return examples.introductionID
    }
}

private enum NotebookWelcomeExamplesError: LocalizedError {
    case unavailable
    var errorDescription: String? {
        "The example notes were removed. You can restore them from Trash."
    }
}

private struct NotebookWelcomeExamples: Codable {
    let plan: NotebookImportPlan
    let introductionID: UUID
    let templateID: UUID
    var completed = false

    init() {
        let folderID = UUID()
        introductionID = UUID()
        templateID = UUID()
        plan = NotebookImportPlan(id: UUID(), entries: [
            .init(id: folderID, kind: .folder, name: "Example Notes",
                  parentID: nil, text: nil),
            .init(id: introductionID, kind: .note, name: "Start Here.md",
                  parentID: folderID, text: Self.introduction),
            .init(id: UUID(), kind: .note, name: "Try Markdown.md",
                  parentID: folderID, text: Self.markdown),
            .init(id: templateID, kind: .note, name: "Meeting.md",
                  parentID: folderID, text: Self.meeting)
        ], skippedPaths: [])
    }

    private static let introduction = """
    This is an ordinary note. Edit it, keep it, or delete this whole folder.

    ## Make yourself at home

    - Tap **+** to start a blank note. Tap its title to rename it.
    - Search finds words across your notes. Note Actions has Find in Note.
    - Try the checkboxes, formatting, and table in [[Try Markdown]].
    - Use the link button or type two opening brackets to connect notes.

    ## Try a template

    [[Meeting]] is already a template. Open Browser Actions and choose
    **New from Template**, then choose Meeting. Holding **+** also opens
    that menu. You'll get a separate note to fill in; the template stays put.

    Any note can be a template: choose **Use as Template** in Note Actions.
    Manage templates and their defaults in Settings.

    ## Your notes stay yours

    After initial iCloud setup, you can write offline. Your changes sync
    when a connection is available. Tap the cloud button for sync details.

    Settings has Markdown import, export, and automatic backups. Readable
    local copies and backups are one-way copies: editing them in Files or
    Finder won't change your notebook. Save an export elsewhere for a backup
    that survives removing the app.

    Accidentally deleted a note? Look in Trash. For earlier text, open
    **Version History** in Note Actions.
    """ + "\n"

    private static let markdown = """
    Tap here and change something. This is all plain text underneath.

    **Bold**, *italic*, ==highlight==, and `inline code` all work.

    ## A small plan

    - [ ] Pick a place for a weekend walk
    - [x] Pack a notebook
    - [ ] Bring coffee

    Tap a checkbox to change it. Lists continue when you press Return.

    > Leave a little room for a detour.

    | Bring | Who |
    | --- | --- |
    | Coffee | Sam |
    | Map | Alex |

    Tap a table cell to edit it. Formatting has more table actions.

    Note Actions lets you switch between Live Preview and Source.
    Go back to [[Start Here]] whenever you like.
    """ + "\n"

    private static let meeting = """
    # Meeting

    ## People

    -

    ## Notes


    ## Next steps

    - [ ]
    """ + "\n"
}
