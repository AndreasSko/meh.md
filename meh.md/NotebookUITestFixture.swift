import Foundation
import NoteCore

#if DEBUG
/// Fictional data is created only in an explicitly isolated preview run.
/// Catalog UUIDs are generated once and remain stable when the run relaunches.
enum NotebookUITestFixture: String, CaseIterable {
    case writing
    case syncStatus = "sync-status"
    case historyRestore = "history-restore"
    case dragOrder = "drag-order"
    case dragNested = "drag-nested"
    case dragSubtree = "drag-subtree"
    case dragLongList = "drag-long-list"
    case storageLarge = "storage-large"
    case flair
    case readme

    static let historyOriginalSource = "Morning light over the ridge."
    static let historyCurrentSource = "Morning light over the ridge.\nClear."

    static let literalSource =
        "# Fictional voyage\n\nLiteral **Markdown** stays intact."

    static func requested(
        environment: [String: String], isPreview: Bool, directory: URL
    ) -> Self? {
        guard isPreview, environment["MEH_NOTEBOOK_PREVIEW"] == "1",
              environment["MEH_SYNC_TEST_TRANSPORT"] == nil,
              environment["MEH_SYNC_URL"] == nil,
              environment["MEH_SYNC_CLOUDKIT"] != "1",
              let run = environment["MEH_NOTEBOOK_PREVIEW_RUN"],
              run.range(of: "^[A-Za-z0-9_-]{1,64}$",
                        options: .regularExpression) != nil,
              directory.lastPathComponent == run,
              directory.deletingLastPathComponent().lastPathComponent
                == "NotebookPreviewTests" else { return nil }
        if let name = environment["MEH_NOTEBOOK_TEST_FIXTURE"] {
            guard let fixture = Self(rawValue: name) else {
                print("Unknown MEH_NOTEBOOK_TEST_FIXTURE: \(name)")
                return nil
            }
            return fixture
        }
        switch environment["MEH_NOTEBOOK_DRAG_FIXTURE"] {
        case "long-list": return .dragLongList
        default: return nil
        }
    }

    static func seedIfRequested(
        _ replica: NotebookReplica, isPreview: Bool, directory: URL,
        documentsDirectory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws {
        guard let fixture = requested(
            environment: environment, isPreview: isPreview, directory: directory
        ) else { return }
        // Reopening the same run must retain IDs and any scenario edits.
        if replica.orderedChildren(parentID: nil).isEmpty {
            try await fixture.seed(replica)
        }
        // Use the real publisher only inside the same explicit preview run.
        // App-model tests omit this argument and keep all fixture files local.
        if fixture == .storageLarge, let documentsDirectory {
            let documents = documentsDirectory.standardizedFileURL
            let support = directory.standardizedFileURL
            guard documents.isFileURL, support.isFileURL,
                  documents.lastPathComponent == support.lastPathComponent,
                  documents.deletingLastPathComponent().lastPathComponent
                    == "NotebookPreviewTests",
                  support.deletingLastPathComponent().lastPathComponent
                    == "NotebookPreviewTests",
                  let catalog = replica.catalogSnapshot else { return }
            let publisher = NotebookMarkdownPublisher(
                directory: documents.appending(path: "Notebook Copies"))
            let notes = try await replica.persistedNoteSnapshots()
            try await publisher.publish(
                catalog: catalog, placements: replica.placements, notes: notes)
        }
    }

    private func seed(_ replica: NotebookReplica) async throws {
        switch self {
        case .storageLarge:
            let field = try await replica.createFolder(name: "Field journals")
            let coast = try await replica.createFolder(name: "Coastal surveys", parentID: field)
            let station = try await replica.createFolder(name: "Station logbooks", parentID: field)
            let destinations = [field, coast, station]
            for number in 1 ... 320 {
                let title = String(format: "%03d Fictional observation", number)
                let paragraph = "Observation \(number): imaginary tide charts, lantern signals, "
                    + "and migrating paper boats at the fictional Northwind station.\n"
                // Vary content and history independently: disk-heavy notes need
                // not have the longest current Markdown source.
                let repeats = number % 16 == 0 ? 1_000 : 4 + number % 28
                let source = "# \(title)\n\n" + String(repeating: paragraph, count: repeats)
                let id = try await replica.createNote(
                    name: "\(title).md", text: source,
                    parentID: destinations[(number - 1) % destinations.count])
                if number % 16 == 0 {
                    let note = try await replica.openNote(id)
                    for revision in 1 ... 4 {
                        try note.replaceAll(with: source + "\nFictional revision \(revision).\n")
                        try await note.flush()
                    }
                }
            }
            var trash: [UUID] = []
            for number in 1 ... 7 {
                let id = try await replica.createNote(
                    name: "Discarded fictional draft \(number).md",
                    text: "# Discarded fictional draft\n\n"
                        + String(repeating: "Imaginary harbor planning.\n", count: number * 90))
                trash.append(id)
            }
            _ = try await replica.trashItems(trash)
        case .historyRestore:
            let id = try await replica.createNote(
                name: "Recovery Sketch.md", text: Self.historyOriginalSource)
            let session = try await replica.openNote(id)
            try session.replaceAll(with: Self.historyCurrentSource)
            try await session.flush()
        case .writing:
            _ = try await replica.createNote(
                name: "Fictional field notes.md", text: Self.literalSource)
            _ = try await replica.createNote(
                name: "Save boundary.md", text: "# Save boundary\n\nFictional notes.")
        case .syncStatus:
            for name in ["Field notes", "Tide chart", "Island sketch"] {
                _ = try await replica.createNote(
                    name: "\(name).md",
                    text: "# \(name)\n\nFictional sync status sample."
                )
            }
            let deletedID = try await replica.createNote(
                name: "Old waypoint.md",
                text: "Fictional note scheduled for deletion cleanup."
            )
            _ = try await replica.trashItems([deletedID])
            let deletion = try replica.deletionSelection(rootID: deletedID)
            try await replica.permanentlyDelete(deletion)
        case .dragOrder:
            for name in ["Charlie", "Alpha", "Bravo"] {
                _ = try await replica.createNote(
                    name: "\(name).md",
                    text: name == "Bravo" ? Self.literalSource : "# Fictional \(name)")
            }
            let journeys = try await replica.createFolder(name: "Journeys")
            _ = try await replica.createFolder(name: "Weekend", parentID: journeys)
        case .dragNested, .dragLongList:
            if self == .dragLongList {
                for number in 1 ... 48 {
                    _ = try await replica.createNote(
                        name: String(format: "%02d Field observation.md", number),
                        text: "# Fictional observation \(number)\n\nSample voyage notes.\n")
                }
            } else {
                _ = try await replica.createNote(
                    name: "Travel checklist.md",
                    text: "# Fictional voyage\n\nSample checklist.\n")
            }
            let journeys = try await replica.createFolder(name: "Journeys")
            let weekend = try await replica.createFolder(
                name: "Weekend", parentID: journeys)
            if self == .dragLongList {
                _ = try await replica.createNote(
                    name: "Island.md",
                    text: "# Fictional island\n\nA sample itinerary.\n",
                    parentID: weekend)
            }
        case .flair:
            let home = try await replica.createFolder(name: "Home")
            _ = try await replica.createNote(
                name: "Garden plan.md",
                text: """
                    Tomatoes along the fence, ==herbs== by the door.

                    - [x] Buy seeds
                    - [ ] Water on Sunday

                    > Plant now, worry later.

                    """,
                parentID: home)
            _ = try await replica.createNote(
                name: "Weekend.md",
                text: """
                    Pick up the ==blue paint== before Saturday. Details are \
                    in [[Garden plan]].

                    - [x] Call the hardware store
                    - [x] Measure the fence
                    - [ ] Paint, two coats

                    > Good enough is good enough.

                    """,
                parentID: home)
            _ = try await replica.createNote(
                name: "Pancakes.md",
                text: "Flour, milk, two eggs, a pinch of salt.\n")
        case .readme:
            try await seedReadme(replica)
        case .dragSubtree:
            _ = try await replica.createNote(
                name: "Packing list.md", text: Self.literalSource)
            let trips = try await replica.createFolder(name: "Trips")
            _ = try await replica.createFolder(name: "Island", parentID: trips)
            _ = try await replica.createFolder(name: "Archive")
        }
    }

    /// The sample notebook behind the README screenshots, sorted the PARA
    /// way. The Lisbon note leads Recents, and its previous version has the
    /// overplanned trip. The weekly review comes from a template.
    private func seedReadme(_ replica: NotebookReplica) async throws {
        let inbox = try await replica.createFolder(name: "Inbox")
        let projects = try await replica.createFolder(name: "Projects")
        let areas = try await replica.createFolder(name: "Areas")
        let resources = try await replica.createFolder(name: "Resources")
        let archive = try await replica.createFolder(name: "Archive")
        try await replica.setDefaultNewNoteParentID(inbox)

        _ = try await replica.createNote(
            name: "Call landlord.md",
            text: "Heating makes the weird noise again. Ask about the window too.\n",
            parentID: inbox)
        let groceries = try await replica.createNote(
            name: "Groceries.md",
            text: "For Saturday: oat milk, lemons, coffee.\n",
            parentID: inbox)
        _ = try await replica.createNote(
            name: "Packing list.md",
            text: "- [x] Passport\n- [ ] Chargers\n- [ ] Sunscreen\n",
            parentID: resources)
        let book = try await replica.createNote(
            name: "Book notes.md",
            text: "> We are what we repeatedly do.\n",
            parentID: resources)
        _ = try await replica.createNote(
            name: "Barcelona 2025.md",
            text: "Best tapas: the tiny place behind the market. No name, no website.\n",
            parentID: archive)

        let templates = try await replica.createFolder(name: "Templates", parentID: resources)
        let weekly = try await replica.createNote(
            name: "Weekly review.md",
            text: "## Good\n\n- \n\n## Meh\n\n- \n\n## Next week\n\n- \n",
            parentID: templates)
        try await replica.setTemplateSource(weekly, enabled: true)
        try await replica.setTemplateSettings(
            NotebookTemplateSettings(destination: .folder(areas),
                                     filenamePattern: "Weekly review {{date}}"),
            for: weekly)

        let snippets = try await replica.createFolder(name: "Snippets", parentID: resources)
        for (name, text) in [
            ("Meeting notes", "## Meeting {{date:short}}\n\nWho: \n\n- \n\n**Action items**\n\n- [ ] \n"),
            ("Pros & cons", "| Pros | Cons |\n| --- | --- |\n|  |  |\n"),
            ("Decision", "**Decision:** \n**Why:** \n**Also considered:** \n"),
            ("Log entry", "**{{date:short}}** – "),
        ] {
            _ = try await replica.createNote(name: "\(name).md", text: text, parentID: snippets)
        }
        try await replica.setSnippetSource(snippets, enabled: true)

        let review = try await replica.createNoteFromTemplate(
            weekly, name: "Weekly review 2026-10-24")
        let reviewSession = try await replica.openNote(review)
        try reviewSession.replaceAll(with: """
            ## Good

            - Lisbon is booked 🎉
            - Finally found that sync bug

            ## Meh

            - Too many meetings. Again.

            ## Next week

            - Decide on the new laptop
            """)
        try await reviewSession.flush()

        let lisbon = try await replica.createNote(
            name: "Lisbon in May.md",
            text: """
                Four days, no plans before ten.

                ## To do

                - [ ] Book flights
                - [ ] Find a place in Alfama

                """,
            parentID: projects)
        let session = try await replica.openNote(lisbon)
        for text in [
            """
            Four days, no plans before ten. What to bring is in \
            [[Packing list]].

            ## To do

            - [x] Book flights
            - [ ] Find a place in Alfama
            - [ ] Reserve dinner in ==Bairro Alto==

            ## Plan

            | Day | What |
            | --- | --- |
            | Thu | Tram 28, castle, Alfama, fado |
            | Fri | Belém, LX Factory, sunset |
            | Sat | Sintra *and* Cascais |

            """,
            """
            Four days, no plans before ten. What to bring is in \
            [[Packing list]].

            ## To do

            - [x] Book flights
            - [x] Find a place in Alfama
            - [ ] Reserve dinner in ==Bairro Alto==
            - [ ] Charge the **good** camera

            ## Plan

            | Day | What |
            | --- | --- |
            | Thu | Tram 28, castle |
            | Fri | Belém, *pastéis* |
            | Sat | Sintra (just Sintra) |
            | Sun | Nothing 🏖️ |

            > Slow down. It's a holiday.

            """,
        ] {
            try session.replaceAll(with: text)
            try await session.flush()
        }
        for id in [book, groceries, review, lisbon] {
            try await replica.recordRecentActivity(for: id)
        }
    }
}
#endif
