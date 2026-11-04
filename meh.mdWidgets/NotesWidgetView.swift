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
                case .recents(let count, let previews):
                    NotesRecentsView(
                        snapshot: snapshot, count: count, previews: previews,
                        date: entry.date
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
    let count: Int
    let previews: Bool
    let date: Date
    @Environment(\.widgetFamily) private var family
    // The line heights of the row fonts, which follow the text size.
    @ScaledMetric(relativeTo: .subheadline) private var titleLine: CGFloat = 20
    @ScaledMetric(relativeTo: .footnote) private var compactTitleLine: CGFloat = 18
    @ScaledMetric(relativeTo: .caption) private var previewLine: CGFloat = 16
    @ScaledMetric(relativeTo: .caption2) private var compactPreviewLine: CGFloat = 13

    var body: some View {
        let limit = MehWidgetRecentsLayout.limit(
            count: count, previews: previews, size: .init(family)
        )
        let rows = snapshot.recentRows(limit: limit)
        Group {
            if rows.isEmpty {
                NotesWidgetMessage(text: "No recent notes yet.")
            } else {
                GeometryReader { proxy in
                    list(rows: rows, limit: limit, height: proxy.size.height)
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            NotesNewNoteButton().padding(-8)
        }
    }

    /// The notes in one card, or in two side by side on extra large.
    private func list(
        rows: [MehWidgetSnapshot.Row], limit: Int, height: CGFloat
    ) -> some View {
        let columns = family == .systemExtraLarge ? 2 : 1
        let plan = MehWidgetRecentsLayout.plan(
            limit: limit, columns: columns, height: height,
            regularText: textHeight(compact: false),
            compactText: textHeight(compact: true)
        )
        let shown = Array(rows.prefix(plan.count))
        let perColumn = (shown.count + columns - 1) / columns
        let groups = stride(from: 0, to: shown.count, by: perColumn).map {
            Array(shown[$0..<min($0 + perColumn, shown.count)])
        }
        return HStack(alignment: .top, spacing: 12) {
            ForEach(groups.indices, id: \.self) { index in
                let group = groups[index]
                let covered = index == groups.count - 1
                    ? MehWidgetRecentsLayout.rowsUnderButton(
                        rows: group.count, rowHeight: plan.rowHeight,
                        text: textHeight(compact: plan.isCompact),
                        gap: height - CGFloat(group.count) * plan.rowHeight,
                        buttonTop: NotesNewNoteButton.reach
                    )
                    : 0
                NotesRecentsCard(
                    rows: group, date: date, previews: previews,
                    compact: plan.isCompact, rowHeight: plan.rowHeight,
                    rowsUnderButton: covered
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func textHeight(compact: Bool) -> CGFloat {
        let title = compact ? compactTitleLine : titleLine
        guard previews else { return title }
        return title + 1 + (compact ? compactPreviewLine : previewLine)
    }
}

/// The yellow + in the bottom-right corner, like the app's own button.
private struct NotesNewNoteButton: View {
    static let size: CGFloat = 32
    /// How far the circle reaches up from the bottom of the widget's
    /// content: it hangs 2 points past the edge.
    static let reach: CGFloat = size - 2
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
    let previews: Bool
    let compact: Bool
    let rowHeight: CGFloat
    /// The last rows, which leave the corner to the new note button.
    let rowsUnderButton: Int
    @Environment(\.notesWidgetPens) private var pens

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                Link(destination: MehWidgetLink.note(row.id).url) {
                    NotesRecentRow(
                        row: row, date: date, preview: previews, compact: compact,
                        clearsButton: index >= rows.count - rowsUnderButton
                    )
                }
                .frame(height: rowHeight)
                .overlay(alignment: .top) {
                    if index > 0 { Divider().padding(.leading, 12) }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(pens.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct NotesRecentRow: View {
    let row: MehWidgetSnapshot.Row
    let date: Date
    let preview: Bool
    let compact: Bool
    /// Leaves the bottom-right corner to the new note button.
    let clearsButton: Bool
    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(row.note.title)
                    .font((compact ? Font.footnote : .subheadline).weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if !clearsButton { trailing }
            }
            if preview {
                let excerpt = row.content?.excerpt ?? ""
                // A blank line keeps every row's title at the same height.
                Text(excerpt.isEmpty ? " " : excerpt)
                    .font(compact ? .caption2 : .caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .privacySensitive()
        .padding(.leading, 12)
        .padding(.trailing, clearsButton ? 38 : 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
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
