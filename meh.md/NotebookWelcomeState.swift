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

    private(set) var firstUseIsPresented = false
    private(set) var presentedSceneIDs = Set<UUID>()
    private(set) var requestID = 0
    @ObservationIgnored private var pendingChoice: PendingChoice?
    @ObservationIgnored private var prepared = false
    @ObservationIgnored private var installingExamples = false

    private struct PendingChoice {
        let sceneID: UUID
        let choice: Choice
    }
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
            firstUseIsPresented = true
        }
    }

    func isPresented(in sceneID: UUID) -> Bool {
        firstUseIsPresented || presentedSceneIDs.contains(sceneID)
    }

    func show(in sceneID: UUID) {
        presentedSceneIDs.insert(sceneID)
    }

    func dismiss(in sceneID: UUID) {
        firstUseIsPresented = false
        presentedSceneIDs.remove(sceneID)
        store.set(true, forKey: storageKey)
    }

    func choose(_ choice: Choice, from sceneID: UUID) {
        guard pendingChoice == nil else { return }
        pendingChoice = PendingChoice(sceneID: sceneID, choice: choice)
        requestID += 1
        dismiss(in: sceneID)
    }

    func takeChoice(for sceneID: UUID) -> Choice? {
        guard let pendingChoice, pendingChoice.sceneID == sceneID else { return nil }
        self.pendingChoice = nil
        return pendingChoice.choice
    }

    func sceneDidClose(id: UUID) {
        presentedSceneIDs.remove(id)
        if pendingChoice?.sceneID == id {
            pendingChoice = nil
        }
    }

    /// Keep random identities through retries. Reopening examples never
    /// replays a successful import or resets template defaults.
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
        let existing = try replica.catalogItemIDsIncludingDeleted()
        let expected = Set(examples.plan.entries.map(\.id))
        if !examples.completed && expected.isDisjoint(with: existing) {
            // A durable interrupted import is resumed by the normal importer.
            // Any prior catalog identity, including a tombstone, prevents a
            // retry from replaying the whole example plan.
            try await replica.importMarkdown(examples.plan)
        }
        guard replica.placements.contains(where: {
            $0.item.id == examples.introductionID && !$0.isInTrash
                && !$0.item.isPermanentlyDeleted
        }) else { throw NotebookWelcomeExamplesError.unavailable }
        let templateIsActive = replica.placements.contains(where: {
            $0.item.id == examples.templateID && !$0.isInTrash
                && !$0.item.isPermanentlyDeleted
        })
        if !examples.completed {
            let alreadyRegistered = replica.isTemplateSource(examples.templateID)
            if templateIsActive && !alreadyRegistered {
                if replica.templateSettings(for: examples.templateID)
                    == NotebookTemplateSettings() {
                    try await replica.setTemplateSettings(
                        .init(destination: .root,
                              filenamePattern: "{{date}} - {{template}}"),
                        for: examples.templateID
                    )
                }
                try await replica.setTemplateSource(examples.templateID, enabled: true)
            }
            examples.completed = true
            store.set(try JSONEncoder().encode(examples), forKey: key)
        }
        return examples.introductionID
    }
}

private enum NotebookWelcomeExamplesError: LocalizedError {
    case unavailable
    var errorDescription: String? {
        "Start Here is unavailable. The other examples were left unchanged."
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

    - Tap **+** to make a note. Tap its title to rename it.
    - Use Search to find words in your notes.
    - Try the checkboxes, formatting, and table in [[Try Markdown]].
    - Tap the link button or type `[[` to connect notes.

    ## Use a template

    [[Meeting]] is already a template.

    - Tap **…** beside **+** in Files and choose **New from Template**.
    - Choose **Meeting** to make a separate note.
    - The new note and source are separate; the Meeting template stays put.
    - Tap **…** on any note and open **Templates & Snippets**.
    - Choose **Use as Template**. Set template defaults in Settings.

    ## When you need it

    - Tap **…** beside **+** in Files, then **Import Markdown**.
    - Settings can export Markdown and make automatic backups.
    - Files copies are one-way; editing one won't change your notebook.
    - Save an export elsewhere to keep it if you remove the app.
    - Find deleted notes in Trash.
    - Open **Version History** from a note's **…** to restore earlier text.
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

    - Tap **…** in a note and choose **Editor Display**.
    - Choose **Markdown Source** or **Live Preview**.

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
