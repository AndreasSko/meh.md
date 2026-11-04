import MehWidgetData
import SwiftUI
import WidgetKit

struct NotesWidgetView: View {
    let entry: NotesEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme

    private var pens: NotesWidgetPens {
        NotesWidgetPens(snapshot: entry.snapshot, colorScheme: colorScheme)
    }

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                switch entry.content {
                case .recents(let pinnedOnly):
                    NotesRecentsView(
                        snapshot: snapshot, pinnedOnly: pinnedOnly, date: entry.date
                    )
                case .note(let id):
                    NotesSingleNoteView(snapshot: snapshot, id: id, date: entry.date)
                }
            } else {
                NotesWidgetMessage(text: "Open meh.md to see your notes here.")
            }
        }
        .padding(12)
        .environment(\.notesWidgetPens, pens)
        .containerBackground(pens.paper, for: .widget)
    }
}

// MARK: Recents

private struct NotesRecentsView: View {
    let snapshot: MehWidgetSnapshot
    let pinnedOnly: Bool
    let date: Date
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let rows = snapshot.recentRows(pinnedOnly: pinnedOnly, limit: limit)
        // A full list of titles fills the widget, so its last row makes room
        // for the new note button. Otherwise the button sits below the notes.
        let fills = !showsExcerpts && rows.count == limit
        content(rows: rows, fills: fills)
            .padding(.bottom, fills ? 0 : NotesNewNoteButton.size + 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .overlay(alignment: .bottomTrailing) {
                NotesNewNoteButton().padding(-8)
            }
    }

    @ViewBuilder private func content(
        rows: [MehWidgetSnapshot.Row], fills: Bool
    ) -> some View {
        if rows.isEmpty {
            NotesWidgetMessage(text: pinnedOnly ? "No pinned notes." : "No recent notes yet.")
        } else if family == .systemExtraLarge && !pinnedOnly {
            let all = snapshot.recentRows(pinnedOnly: false, limit: .max)
            let pins = all.filter(\.isPinned).prefix(4)
            let others = all.filter { !$0.isPinned }.prefix(10 - pins.count)
            HStack(alignment: .top, spacing: 12) {
                if !pins.isEmpty {
                    NotesRecentsCard(rows: Array(pins), date: date, excerpts: true)
                }
                if !others.isEmpty {
                    NotesRecentsCard(rows: Array(others), date: date, excerpts: pins.isEmpty)
                }
            }
        } else {
            NotesRecentsCard(rows: rows, date: date, excerpts: showsExcerpts, fills: fills)
        }
    }

    private var limit: Int {
        switch family {
        case .systemSmall, .systemMedium: 3
        case .systemExtraLarge: pinnedOnly ? 5 : 10
        default: 5
        }
    }

    private var showsExcerpts: Bool {
        family == .systemLarge || family == .systemExtraLarge
    }
}

/// The yellow + in the bottom-right corner, like the app's own button.
private struct NotesNewNoteButton: View {
    static let size: CGFloat = 32
    @Environment(\.notesWidgetPens) private var pens

    var body: some View {
        Link(destination: MehWidgetLink.newNote.url) {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(pens.onHighlighter)
                .frame(width: Self.size, height: Self.size)
                .background(pens.highlighter, in: Circle())
                .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("New Note")
    }
}

private struct NotesRecentsCard: View {
    let rows: [MehWidgetSnapshot.Row]
    let date: Date
    let excerpts: Bool
    /// A full list of titles spreads over the widget's height.
    var fills = false
    @Environment(\.notesWidgetPens) private var pens

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider().padding(.leading, 12) }
                Link(destination: MehWidgetLink.note(row.id).url) {
                    NotesRecentRow(
                        row: row, date: date, excerpt: excerpts,
                        clearsButton: fills && index == rows.count - 1
                    )
                    .frame(maxHeight: fills ? .infinity : nil)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: fills ? .infinity : nil)
        .background(pens.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct NotesRecentRow: View {
    let row: MehWidgetSnapshot.Row
    let date: Date
    let excerpt: Bool
    /// Leaves the bottom-right corner to the new note button.
    var clearsButton = false
    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(row.note.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if !clearsButton { trailing }
            }
            if excerpt, let text = row.content?.excerpt, !text.isEmpty {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .privacySensitive()
        .padding(.leading, 12)
        .padding(.trailing, clearsButton ? 38 : 12)
        .padding(.vertical, excerpt ? 7 : 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var trailing: some View {
        if row.isPinned {
            Image(systemName: "pin.fill")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .accessibilityLabel("Pinned")
        } else if let modified = row.content?.modifiedAt {
            Text(MehWidgetTime.label(
                for: modified, now: date, compact: family == .systemSmall
            ))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
        }
    }
}

// MARK: One note

private struct NotesSingleNoteView: View {
    let snapshot: MehWidgetSnapshot
    let id: UUID?
    let date: Date
    @Environment(\.widgetFamily) private var family
    @Environment(\.notesWidgetPens) private var pens

    var body: some View {
        if let id, let note = snapshot.note(id) {
            VStack(alignment: .leading, spacing: 6) {
                header(for: note)
                NotesNoteBody(content: snapshot.content(id))
                    .privacySensitive()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(pens.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .widgetURL(MehWidgetLink.note(id).url)
        } else {
            NotesWidgetMessage(text: id == nil
                ? "Edit the widget to pick a note."
                : "This note is no longer in your notebook.")
        }
    }

    private func header(for note: MehWidgetSnapshot.Note) -> some View {
        HStack(spacing: 6) {
            Text(path(for: note))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .privacySensitive()
            Spacer(minLength: 0)
            if let modified = snapshot.content(note.id)?.modifiedAt {
                Text(MehWidgetTime.label(
                    for: modified, now: date, compact: family == .systemSmall
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize()
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 24)
    }

    private func path(for note: MehWidgetSnapshot.Note) -> String {
        family == .systemSmall
            ? note.title
            : (note.folders + [note.title]).joined(separator: " › ")
    }
}

private struct NotesNoteBody: View {
    let content: MehWidgetSnapshot.Content?
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let content {
            let blocks = Array(MehWidgetMarkdown.blocks(from: content.text).prefix(limit))
            if blocks.isEmpty {
                Text("Empty note").font(.caption).foregroundStyle(.secondary)
            } else if family == .systemExtraLarge {
                let half = (blocks.count + 1) / 2
                HStack(alignment: .top, spacing: 20) {
                    NotesBlockList(blocks: Array(blocks.prefix(half)))
                    NotesBlockList(blocks: Array(blocks.dropFirst(half)))
                }
            } else {
                NotesBlockList(blocks: blocks)
            }
        } else {
            Text("Open meh.md to show this note here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var limit: Int {
        switch family {
        case .systemSmall, .systemMedium: 5
        case .systemLarge: 14
        default: 26
        }
    }
}

private struct NotesBlockList: View {
    let blocks: [MehWidgetMarkdown.Block]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                NotesBlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NotesBlockView: View {
    let block: MehWidgetMarkdown.Block
    @Environment(\.notesWidgetPens) private var pens

    var body: some View {
        switch block {
        case .heading(let text):
            line(text).font(.footnote.weight(.semibold)).padding(.top, 2)
        case .task(let text, let done):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: done ? "checkmark.square.fill" : "square")
                    .font(.caption2)
                    .foregroundStyle(done ? pens.ink : .secondary)
                    .accessibilityLabel(done ? "Done" : "Open")
                line(text)
                    .strikethrough(done)
                    .foregroundStyle(done ? .secondary : .primary)
            }
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").font(.caption).foregroundStyle(.secondary)
                line(text)
            }
        case .numbered(let text, let number):
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(number).").font(.caption).foregroundStyle(.secondary)
                line(text)
            }
        case .quote(let text):
            line(text)
                .foregroundStyle(.secondary)
                .padding(.leading, 8)
                .overlay(alignment: .leading) {
                    Capsule().fill(pens.stroke).frame(width: 2)
                }
        case .paragraph(let text):
            line(text)
        }
    }

    private func line(_ text: String) -> some View {
        Text(pens.inline(text))
            .font(.caption)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Shared pieces

private struct NotesWidgetFace: View {
    var body: some View {
        Text("•_•")
            .font(.system(.caption, design: .monospaced).weight(.bold))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }
}

private struct NotesWidgetMessage: View {
    let text: LocalizedStringKey

    var body: some View {
        VStack(spacing: 6) {
            NotesWidgetFace()
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
