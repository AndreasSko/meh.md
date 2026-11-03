import MehWidgetData
import SwiftUI
import WidgetKit

@main
struct MehWidgets: WidgetBundle {
    var body: some Widget {
        NotesWidget()
    }
}

struct NotesWidget: Widget {
    static let kind = "notes"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: Self.kind, intent: NotesWidgetIntent.self,
            provider: NotesProvider()
        ) { entry in
            NotesWidgetView(entry: entry)
        }
        .configurationDisplayName("Notes")
        .description("Your pinned and recent notes, or one note you pick.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
        .contentMarginsDisabled()
    }
}

struct NotesEntry: TimelineEntry {
    enum Content {
        case recents(pinnedOnly: Bool)
        case note(UUID?)
    }

    let date: Date
    let snapshot: MehWidgetSnapshot?
    let content: Content
}

struct NotesProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> NotesEntry {
        NotesEntry(date: .now, snapshot: .sample, content: .recents(pinnedOnly: false))
    }

    func snapshot(for configuration: NotesWidgetIntent, in context: Context) async -> NotesEntry {
        entry(for: configuration, at: .now, preview: context.isPreview)
    }

    func timeline(
        for configuration: NotesWidgetIntent, in context: Context
    ) async -> Timeline<NotesEntry> {
        let now = Date.now
        let first = entry(for: configuration, at: now, preview: false)
        if case .note(let id?) = first.content, let store = MehWidgetStore(),
           first.snapshot?.note(id) != nil, first.snapshot?.content(id) == nil {
            try? store.requestContent(for: id)
        }
        let entries = MehWidgetTime.refreshDates(from: now).map {
            NotesEntry(date: $0, snapshot: first.snapshot, content: first.content)
        }
        return Timeline(entries: entries, policy: .atEnd)
    }

    private func entry(
        for configuration: NotesWidgetIntent, at date: Date, preview: Bool
    ) -> NotesEntry {
        var snapshot = MehWidgetStore()?.load()
        if preview, snapshot?.notes.isEmpty != false { snapshot = .sample }
        let content: NotesEntry.Content = switch configuration.content {
        case .recents: .recents(pinnedOnly: configuration.filter == .pinnedOnly)
        case .note: .note(configuration.note?.id ?? (preview ? snapshot?.recents.first?.id : nil))
        }
        return NotesEntry(date: date, snapshot: snapshot, content: content)
    }
}

extension MehWidgetSnapshot {
    /// Fictional notes for the widget gallery before the app has run.
    static let sample: MehWidgetSnapshot = {
        let now = Date.now
        func note(_ title: String, _ folders: [String] = []) -> Note {
            Note(id: UUID(), title: title, folders: folders)
        }
        let lisbon = note("Lisbon in May", ["Projects"])
        let groceries = note("Groceries")
        let review = note("Weekly review", ["Areas"])
        let packing = note("Packing list", ["Projects"])
        let books = note("Book notes", ["Resources"])
        let notes = [lisbon, books, groceries, review, packing]
        let texts = [
            (lisbon, "Four days, no plans before ten. What to bring is in [[Packing list]].", -86_400.0 * 2),
            (books, "We are what we repeatedly do.", -86_400.0 * 9),
            (groceries, "- [x] oat milk\n- [ ] lemons\n- [ ] coffee\n- [ ] bread", -120.0),
            (review, "Good: Lisbon is booked. Next week: ==call the landlord==.", -3_600.0),
            (packing, "Charger, adapter, the good sunglasses.", -86_400.0 * 3),
        ]
        return MehWidgetSnapshot(
            notes: notes,
            recents: [
                Recent(id: lisbon.id, isPinned: true), Recent(id: books.id, isPinned: true),
                Recent(id: groceries.id, isPinned: false),
                Recent(id: review.id, isPinned: false), Recent(id: packing.id, isPinned: false),
            ],
            contents: texts.map { note, text, age in
                Content(
                    id: note.id, text: text,
                    excerpt: text.replacingOccurrences(of: "- [x] ", with: "")
                        .replacingOccurrences(of: "- [ ] ", with: "")
                        .replacingOccurrences(of: "\n", with: " "),
                    modifiedAt: now.addingTimeInterval(age)
                )
            },
            ink: "black", highlighter: "yellow"
        )
    }()
}
