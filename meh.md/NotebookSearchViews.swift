import NoteCore
import Observation
import SwiftUI

struct NotebookSearchResults: View {
    let results: [NotebookSearchResult]
    let query: String
    let isPreparing: Bool
    let unavailableCount: Int
    let error: String?
    @Binding var selection: UUID?
    let open: (NotebookSearchResult) -> Void
    @State private var scrollPosition = ScrollPosition(idType: UUID.self)

    var body: some View {
        Group {
            if let error {
                ContentUnavailableView("Search unavailable", systemImage: "exclamationmark.magnifyingglass",
                                       description: Text(error))
            } else if results.isEmpty && !isPreparing && !query.isEmpty {
                ContentUnavailableView {
                    Label("No results", systemImage: "magnifyingglass")
                } description: {
                    Text("No matches for “\(query)”. Try a shorter phrase or another word.")
                }
            } else if results.isEmpty && !isPreparing {
                ContentUnavailableView("Search your notes", systemImage: "magnifyingglass",
                                       description: Text("Search note titles and contents."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if query.isEmpty {
                            resultSection("Recents", items: results)
                        } else {
                            resultSection(nil, items: results)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, 16)
                }
                .scrollPosition($scrollPosition)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if unavailableCount > 0 {
                Text("Some notes aren’t available locally. Results may be incomplete.")
                    .font(.footnote).foregroundStyle(.secondary).padding()
            }
        }
        .accessibilityIdentifier("notebook-search-results")
    }

    @ViewBuilder
    private func resultSection(_ title: LocalizedStringKey?, items: [NotebookSearchResult]) -> some View {
        if !items.isEmpty {
            if let title {
                Text(title).font(.headline).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, 16).padding(.bottom, 8)
            }
            ForEach(items, id: \.id) { result in
                Button {
                    selection = result.id
                    open(result)
                } label: {
                    NotebookSearchRow(result: result)
                        .padding(.vertical, 14)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(selection == result.id ? Color.primary.opacity(0.08) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(alignment: .bottom) {
                    Divider().padding(.horizontal, 8)
                }
                .accessibilityIdentifier("search-result-\(result.id)")
                .id(result.id)
            }
        }
    }
}

struct NotebookSearchRow: View {
    let result: NotebookSearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(highlight(result.title, range: result.titleMatchRange)).font(.headline)
            if !result.path.isEmpty {
                Text(result.path).font(.caption).foregroundStyle(.secondary)
            }
            Text(highlight(
                result.bodyMatchRange == nil
                    ? NotebookRecentPreview.text(from: result.excerpt) : result.excerpt,
                range: result.excerptMatchRange
            ))
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func highlight(_ text: String, range: NSRange?) -> AttributedString {
        var result = AttributedString(text)
        if let range, let stringRange = Range(range, in: text),
           let lower = AttributedString.Index(stringRange.lowerBound, within: result),
           let upper = AttributedString.Index(stringRange.upperBound, within: result) {
            result[lower..<upper].font = .body.bold()
            result[lower..<upper].underlineStyle = .single
        }
        return result
    }
}

struct NotebookQuickOpen: View {
    @Bindable var search: NotebookSearchState
    let open: (NotebookSearchResult) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Quick Open").font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            TextField("Search all notes", text: $search.quickQuery)
                .textFieldStyle(.roundedBorder)
                .focused($queryFocused)
                .accessibilityIdentifier("quick-open-query")
                .onSubmit(openSelection)
            if let error = search.error {
                Text(error).foregroundStyle(.secondary)
            } else if search.results.isEmpty && !search.isPreparing {
                Text(search.quickQuery.isEmpty ? "No recent notes" : "No results")
                    .foregroundStyle(.secondary)
            }
            ScrollViewReader { proxy in
                List(selection: $search.quickSelectionID) {
                    ForEach(search.results, id: \.id) { result in
                        Button { open(result) } label: {
                            NotebookSearchRow(result: result).padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .tag(result.id)
                        .id(result.id)
                        .accessibilityIdentifier("quick-result-\(result.id)")
                    }
                }
                .onChange(of: search.quickSelectionID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
            if search.unavailableCount > 0 {
                Text("Some notes aren’t available locally.").font(.footnote)
            }
            HStack {
                Text("↑ ↓ Select · Return Open · Esc Cancel")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Open", action: openSelection)
                    .disabled(search.quickSelectionID == nil)
            }
        }
        .padding()
        .frame(idealWidth: 560, idealHeight: 440)
        .onAppear { queryFocused = true }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.return) { openSelection(); return .handled }
    }

    private func move(_ offset: Int) {
        let items = search.results
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == search.quickSelectionID }
            ?? (offset > 0 ? -1 : items.count)
        search.quickSelectionID = items[min(max(current + offset, 0), items.count - 1)].id
    }

    private func openSelection() {
        guard let result = search.results.first(where: { $0.id == search.quickSelectionID }) else { return }
        open(result)
    }
}

private struct NotebookSearchFocusKey: FocusedValueKey {
    typealias Value = NotebookSearchState
}

@MainActor
@Observable
final class NotebookRecentCommandState {
    @ObservationIgnored private let replica: NotebookReplica
    var focusedNoteID: UUID?
    var selectedNoteID: UUID?
    var errorMessage: String?

    init(replica: NotebookReplica) {
        self.replica = replica
    }

    var commandTitle: LocalizedStringKey {
        guard let targetNoteID, replica.isPinnedInRecents(targetNoteID) else {
            return "Pin in Recents"
        }
        return "Unpin from Recents"
    }

    var isAvailable: Bool {
        guard let targetNoteID else { return false }
        return replica.isPinnedInRecents(targetNoteID)
            || replica.canPinInRecents(targetNoteID)
    }

    func togglePin() {
        guard let targetNoteID else { return }
        let pinned = replica.isPinnedInRecents(targetNoteID)
        guard pinned || replica.canPinInRecents(targetNoteID) else { return }
        Task { @MainActor in
            do {
                try await replica.setPinnedInRecents(!pinned, for: targetNoteID)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var targetNoteID: UUID? {
        let recentIDs = Set(replica.recentNotes.map(\.id))
        if let focusedNoteID, recentIDs.contains(focusedNoteID) {
            return focusedNoteID
        }
        if let selectedNoteID, recentIDs.contains(selectedNoteID) {
            return selectedNoteID
        }
        return nil
    }
}

private struct NotebookRecentCommandsKey: FocusedValueKey {
    typealias Value = NotebookRecentCommandState
}

extension FocusedValues {
    var notebookRecentCommands: NotebookRecentCommandState? {
        get { self[NotebookRecentCommandsKey.self] }
        set { self[NotebookRecentCommandsKey.self] = newValue }
    }
}

extension FocusedValues {
    var notebookSearch: NotebookSearchState? {
        get { self[NotebookSearchFocusKey.self] }
        set { self[NotebookSearchFocusKey.self] = newValue }
    }
}

struct NotebookSearchCommands: Commands {
    @FocusedValue(\.notebookSearch) private var search

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Quick Open…") { search?.quickOpenRequest += 1 }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(search == nil)
        }
        CommandGroup(after: .textEditing) {
            Button("Find in Note…") { search?.findRequest += 1 }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(search?.canFind != true || search?.showingQuickOpen == true)
        }
    }
}

struct NotebookRecentCommands: Commands {
    @FocusedValue(\.notebookRecentCommands) private var recents

    var body: some Commands {
        CommandMenu("Recents") {
            Button(recents?.commandTitle ?? "Pin in Recents") {
                recents?.togglePin()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(recents?.isAvailable != true)
        }
    }
}
