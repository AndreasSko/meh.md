import NoteCore
import SwiftUI

struct NotebookLinkInsertionRequest: Identifiable {
    let id = UUID()
    let sourceID: UUID
    let text: String
    let range: NSRange
    let label: String
}

struct NotebookLinkPicker: View {
    let state: NotebookLinkState
    let replica: NotebookReplica
    let select: (NotebookLinkNote) -> Void
    let insertURL: (String) -> Void
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let error = state.error {
                    Text(error).foregroundStyle(.secondary)
                }
                if state.isLoading && state.notes.isEmpty {
                    ProgressView("Loading notes…")
                }
                if let url = URL(string: query),
                   ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                    Button {
                        insertURL(query)
                    } label: {
                        Label("Link to \(query)", systemImage: "link")
                    }
                }
                ForEach(state.suggestions(for: query), id: \.id) { note in
                    Button { select(note) } label: {
                        NotebookLinkNoteLabel(note: note)
                    }
                    .accessibilityIdentifier("note-link-choice-\(note.id)")
                }
                if !state.isLoading && state.suggestions(for: query).isEmpty {
                    Text("No matching notes").foregroundStyle(.secondary)
                }
            }
            .searchable(text: $query, prompt: "Note name or web address")
            .navigationTitle("Add Link")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task(id: replica.searchRevision.catalogHeads) {
            await state.refresh(replica: replica)
        }
        #if os(macOS)
        .frame(minWidth: 380, idealWidth: 460, minHeight: 350)
        #endif
    }
}

struct NotebookLinkNoteLabel: View {
    let note: NotebookLinkNote

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(NotebookNoteName.title(from: note.name))
                .foregroundStyle(.primary)
            if !note.path.isEmpty {
                Text(note.path).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

struct NotebookBacklinksView: View {
    let state: NotebookLinkState
    let replica: NotebookReplica
    let noteID: UUID
    let open: (NotebookBacklink) -> Void
    @Environment(\.dismiss) private var dismiss

    private var backlinks: [NotebookBacklink] {
        state.hasBacklinkScope(replica: replica, targetID: noteID) ? state.backlinks : []
    }

    private var sourceNotes: [NotebookLinkNote] {
        let ids = Set(backlinks.map(\.sourceID))
        return state.notes.filter { ids.contains($0.id) }.sorted {
            $0.fullPath.localizedStandardCompare($1.fullPath) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if state.hasBacklinkScope(replica: replica, targetID: noteID), let error = state.error {
                    Text(error).foregroundStyle(.secondary)
                }
                if !state.hasBacklinkScope(replica: replica, targetID: noteID)
                    || (state.isLoading && backlinks.isEmpty) {
                    ProgressView("Finding links…")
                        .accessibilityIdentifier("backlinks-loading")
                } else if backlinks.isEmpty {
                    ContentUnavailableView("No linked notes", systemImage: "link",
                        description: Text("Links to this note will appear here."))
                }
                ForEach(sourceNotes, id: \.id) { source in
                    Section {
                        ForEach(backlinks.filter { $0.sourceID == source.id },
                                id: \.occurrence.range.location) { backlink in
                            Button { open(backlink) } label: {
                                Text(backlink.snippet)
                                    .foregroundStyle(.primary).lineLimit(3)
                            }
                            .accessibilityIdentifier("backlink-\(source.id)-\(backlink.occurrence.range.location)")
                        }
                    } header: {
                        NotebookLinkNoteLabel(note: source)
                    }
                }
                if state.hasBacklinkScope(replica: replica, targetID: noteID), state.unavailableCount > 0 {
                    Text("\(state.unavailableCount) notes are not available on this device yet. More links may appear when they download.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Linked from")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task(id: replica.searchRevision) {
            await state.refresh(replica: replica, targetID: noteID)
        }
        #if os(macOS)
        .frame(minWidth: 400, idealWidth: 520, minHeight: 360)
        #endif
    }
}

/// A transient authoring control. One glass surface separates the choices
/// from the document; individual rows retain ordinary native button behavior.
struct NotebookLinkSuggestions: View {
    let notes: [NotebookLinkNote]
    let isLoading: Bool
    let selection: Int
    let headings: [String]
    let selectHeading: (String) -> Void
    let select: (NotebookLinkNote) -> Void
    let dismiss: () -> Void
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 56

    private var selectedNoteID: UUID? {
        notes.isEmpty ? nil : notes[min(max(0, selection), notes.count - 1)].id
    }

    private var selectedHeading: String? {
        headings.isEmpty ? nil : headings[min(max(0, selection), headings.count - 1)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NotebookLinkSuggestionsHeader(isHeading: !headings.isEmpty, dismiss: dismiss)
            if isLoading && notes.isEmpty && headings.isEmpty {
                ProgressView("Loading notes…").padding(16)
            } else if !headings.isEmpty {
                ScrollViewReader { scroll in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(headings, id: \.self) { heading in
                                NotebookLinkSuggestionRow(
                                    title: heading, subtitle: nil,
                                    systemImage: "number", isSelected: selectedHeading == heading,
                                    height: rowHeight
                                ) { selectHeading(heading) }
                                .id(heading)
                                .accessibilityIdentifier("link-heading-\(heading)")
                            }
                        }
                    }
                    .frame(height: rowHeight * CGFloat(min(3, headings.count)))
                    .onChange(of: selectedHeading, initial: true) { _, heading in
                        if let heading { scroll.scrollTo(heading, anchor: .center) }
                    }
                }
            } else if notes.isEmpty {
                Text("No matching notes").font(.callout)
                    .foregroundStyle(.secondary).padding(16)
            } else {
                ScrollViewReader { scroll in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(notes, id: \.id) { note in
                                NotebookLinkSuggestionRow(
                                    title: NotebookNoteName.title(from: note.name),
                                    subtitle: note.path.isEmpty ? nil : note.path,
                                    systemImage: "doc.text", isSelected: selectedNoteID == note.id,
                                    height: rowHeight
                                ) { select(note) }
                                .id(note.id)
                                .accessibilityIdentifier("link-suggestion-\(note.id)")
                            }
                        }
                    }
                    .frame(height: rowHeight * CGFloat(min(3, notes.count)))
                    .onChange(of: selectedNoteID, initial: true) { _, id in
                        if let id { scroll.scrollTo(id, anchor: .center) }
                    }
                }
            }
        }
        .padding(.bottom, 6)
        .frame(maxWidth: 480)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("note-link-suggestions")
    }
}

private struct NotebookLinkSuggestionsHeader: View {
    let isHeading: Bool
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(isHeading ? "Link to heading" : "Link to note")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 16)
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss suggestions")
        }
    }
}

private struct NotebookLinkSuggestionRow: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    let isSelected: Bool
    let height: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body).foregroundStyle(.primary)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: max(44, height), alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.12) : .clear,
                        in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Variable tokens stay literal in the source and expand at snippet insertion.
struct NotebookSnippetVariableSuggestions: View {
    let variables: [NotebookSnippetVariable]
    let selection: Int
    let title: String
    let select: (NotebookSnippetVariable) -> Void
    let dismiss: () -> Void
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 68

    private var selectedVariable: NotebookSnippetVariable? {
        variables.isEmpty ? nil : variables[min(max(0, selection), variables.count - 1)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Snippet variable")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.leading, 16)
                Spacer(minLength: 0)
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss suggestions")
            }
            if variables.isEmpty {
                Text("No matching variables").font(.callout)
                    .foregroundStyle(.secondary).padding(16)
            } else {
                ScrollViewReader { scroll in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(variables, id: \.rawValue) { variable in
                                Button { select(variable) } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack {
                                            Text(variable.token).font(.body.monospaced())
                                            Spacer(minLength: 8)
                                            Text(descriptor(variable)).font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Text(variable.value(title: title, date: Date(),
                                            timeZone: timeZone, locale: locale))
                                            .font(.caption).foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    .foregroundStyle(.primary)
                                    .padding(.horizontal, 12)
                                    .frame(maxWidth: .infinity, minHeight: rowHeight,
                                        alignment: .leading)
                                    .background(selectedVariable == variable
                                        ? Color.accentColor.opacity(0.12) : .clear,
                                        in: RoundedRectangle(cornerRadius: 12))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain).padding(.horizontal, 6)
                                .id(variable.rawValue)
                                .accessibilityIdentifier("snippet-variable-\(variable.rawValue)")
                                .accessibilityAddTraits(selectedVariable == variable
                                    ? .isSelected : [])
                            }
                        }
                    }
                    .frame(height: rowHeight * CGFloat(min(3, variables.count)))
                    .onChange(of: selectedVariable, initial: true) { _, variable in
                        if let variable { scroll.scrollTo(variable.rawValue, anchor: .center) }
                    }
                }
            }
        }
        .padding(.bottom, 6).frame(maxWidth: 480)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("note-snippet-variable-suggestions")
    }

    private func descriptor(_ variable: NotebookSnippetVariable) -> LocalizedStringKey {
        switch variable {
        case .date: "Date"
        case .shortDate: "Date without year"
        case .longDate: "Long date"
        case .isoDate: "ISO date"
        case .time: "Time"
        case .title: "Note title"
        }
    }
}
