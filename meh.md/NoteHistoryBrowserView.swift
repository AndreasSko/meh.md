import NoteCore
import SwiftUI

@MainActor
@Observable
final class NoteHistoryBrowserState {
    let noteID: UUID
    private(set) var versions: [NoteHistoryVersion]
    private(set) var timeline = NoteHistoryTimeline()
    let expectedHeads: Set<String>
    let originalPosition: MarkdownEditorPosition?
    let currentText: String
    let reader: NoteHistoryReader
    let navigation = MarkdownEditorNavigation()
    private(set) var selectedIndex: Int
    private(set) var text: String
    /// What the selected version changed, compared with the version before
    /// it at the timeline's current level of detail.
    private(set) var changes = NoteHistoryChanges.none
    private var comparedBase: Int?
    private(set) var isLoadingIndex = true
    private(set) var isLoadingPreview = false
    @ObservationIgnored private var revision = -1
    /// The version whose text the preview shows; empty for the current
    /// text. Loaded details can move the selection's index and base, so the
    /// text is tracked by version rather than by index.
    @ObservationIgnored private var shownTextID = ""
    /// The version the last selection asked for, shown or still loading.
    @ObservationIgnored private var requestedTextID = ""
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    @ObservationIgnored private var selectionGeneration = 0

    init(
        noteID: UUID,
        versions: [NoteHistoryVersion],
        expectedHeads: Set<String>,
        originalPosition: MarkdownEditorPosition?,
        text: String,
        reader: NoteHistoryReader
    ) {
        self.noteID = noteID
        self.versions = versions
        timeline = NoteHistoryTimeline(versions)
        self.expectedHeads = expectedHeads
        self.originalPosition = originalPosition
        currentText = text
        self.reader = reader
        selectedIndex = versions.count
        self.text = text
    }

    var selectedVersion: NoteHistoryVersion? {
        versions.indices.contains(selectedIndex) ? versions[selectedIndex] : nil
    }
    var isViewingCurrent: Bool { selectedIndex == versions.count }

    /// Updates arrive from the index and from detail loading. Loaded
    /// details insert versions, so the selection follows its version.
    func apply(_ update: NoteHistoryIndexUpdate) {
        guard update.revision > revision else { return }
        revision = update.revision
        let selectedID = selectedVersion?.id
        let baseID = comparedBase.flatMap { versions.indices.contains($0) ? versions[$0].id : nil }
        versions = update.versions
        timeline = NoteHistoryTimeline(versions)
        selectedIndex = selectedID.flatMap { id in versions.firstIndex { $0.id == id } }
            ?? versions.count
        comparedBase = baseID.flatMap { id in versions.firstIndex { $0.id == id } }
        isLoadingIndex = !update.isComplete
    }

    /// Loads single saved states around a version, or around the current
    /// text, so the rail can show them when asked.
    func loadDetails(near version: NoteHistoryVersion?) {
        detailTask?.cancel()
        detailTask = Task { @MainActor [weak self, reader] in
            // Index errors reach History through the index updates.
            do {
                for try await update in await reader.details(near: version) {
                    self?.apply(update)
                }
            } catch {}
        }
    }

    func cancel() {
        cancelPreview()
        detailTask?.cancel()
        detailTask = nil
    }

    private func cancelPreview() {
        selectionGeneration += 1
        previewTask?.cancel()
        previewTask = nil
    }

    /// `base` is the version the changes are compared with; `nil` compares
    /// with an empty note.
    func select(
        _ index: Int, comparedWith base: Int?, onError: @escaping (Error) -> Void
    ) {
        guard (0...versions.count).contains(index) else { return }
        let target = versions.indices.contains(index) ? versions[index] : nil
        let targetID = target?.id ?? ""
        guard targetID != requestedTextID || index != selectedIndex
                || (target != nil && base != comparedBase) else { return }
        // The same version at another level of detail only needs new marks.
        let isSameText = targetID == shownTextID
        requestedTextID = targetID
        cancelPreview()
        if !isSameText { loadDetails(near: target) }
        let generation = selectionGeneration
        let previousPosition = isSameText ? nil : navigation.capturePosition?()
        selectedIndex = index
        comparedBase = base
        if isViewingCurrent {
            isLoadingPreview = false
            changes = .none
            installText(currentText, of: "", position: previousPosition, generation: generation)
            return
        }
        let version = versions[index]
        let baseVersion = base.flatMap { versions.indices.contains($0) ? versions[$0] : nil }
        isLoadingPreview = true
        previewTask = Task { @MainActor [weak self, reader] in
            do {
                let nextText = isSameText ? nil : try await reader.historicalText(for: version)
                // The reader keeps both texts cached, so comparing them right
                // away lets text and marks arrive in one update.
                let nextChanges = try await reader.changes(for: version, since: baseVersion)
                try Task.checkCancellation()
                guard let self, selectionGeneration == generation else { return }
                changes = nextChanges
                if let nextText {
                    installText(nextText, of: version.id, position: previousPosition,
                                generation: generation)
                }
                isLoadingPreview = false
                previewTask = nil
            } catch is CancellationError {
                // A newer selection or closing History owns the screen now.
            } catch {
                guard let self, selectionGeneration == generation else { return }
                selectedIndex = versions.count
                comparedBase = nil
                text = currentText
                shownTextID = ""
                requestedTextID = ""
                changes = .none
                isLoadingPreview = false
                previewTask = nil
                onError(error)
            }
        }
    }

    private func installText(
        _ nextText: String, of id: String, position previousPosition: MarkdownEditorPosition?,
        generation: Int
    ) {
        text = nextText
        shownTextID = id
        if let previousPosition {
            let length = (nextText as NSString).length
            let position = MarkdownEditorPosition(
                selection: NSRange(location: min(previousPosition.selection.location, length), length: 0),
                scrollAnchor: min(previousPosition.scrollAnchor, length),
                scrollAnchorOffset: previousPosition.scrollAnchorOffset
            )
            Task { @MainActor [weak self] in
                await Task.yield()
                guard self?.selectionGeneration == generation else { return }
                self?.navigation.restorePosition?(position)
            }
        }
    }
}

struct NoteHistoryBrowserView: View {
    let state: NoteHistoryBrowserState
    let session: NoteSession
    let title: String
    let fontSize: Double
    let fontFamily: EditorFontFamily
    let mode: MarkdownEditorMode
    let onDone: () -> Void
    let onRestoreThisNote: () -> Void
    let onRestoreAsNewNote: () -> Void
    let onError: (Error) -> Void
    @State private var showingRestoreChoices = false
    @State private var confirmingReplacement = false
    @State private var isDetailed = false
    @State private var viewport = NoteHistoryViewport()
    @State private var removal: NoteHistoryRemovalPopover?
    @Environment(\.mehPalette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            NoteHistoryHeading(
                title: title,
                version: state.selectedVersion,
                // A single state picked inside a session reads to the second,
                // like the rail's caption.
                isDetailed: isDetailed || !state.timeline.isSessionEnd(state.selectedIndex),
                fontSize: fontSize,
                fontFamily: fontFamily
            )
            MarkdownEditor(
                text: Binding(get: { state.text }, set: { _ in }),
                isReadOnly: true,
                navigation: state.navigation,
                fontSize: fontSize,
                fontFamily: fontFamily,
                mode: mode,
                palette: palette,
                historyChanges: state.changes
            )
            .accessibilityIdentifier("note-history-preview")
            .overlay(alignment: .trailing) {
                NoteHistoryScrollMarks(changes: state.changes, textLength: (state.text as NSString).length)
            }
            .overlay {
                if state.isLoadingPreview {
                    NoteHistoryLoadingIndicator()
                }
            }
            .popover(item: $removal, attachmentAnchor: .rect(.rect(removal?.rect ?? .zero))) { removal in
                Text(removal.text)
                    .strikethrough()
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .padding()
                    .frame(maxWidth: 320, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Text("Removed: \(removal.text)"))
                    .presentationCompactAdaptation(.popover)
            }
            // Fill the area behind the floating controls. The safe-area
            // inset still keeps the last lines reachable above them.
            .ignoresSafeArea(.container, edges: .bottom)
        }
        .background(MehStyle.paperColor.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 10) {
                NoteHistoryTimelineView(
                    isLoading: state.isLoadingIndex,
                    timeline: state.timeline,
                    versions: state.versions,
                    selectedIndex: state.selectedIndex,
                    changes: state.changes,
                    isDetailed: $isDetailed,
                    select: { index, base in
                        removal = nil
                        state.select(index, comparedWith: base, onError: onError)
                    }
                )
            }
            .padding(.top, 18)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                state.navigation.coveredBottomHeight = height
            }
            // The jumper comes and goes; floating it above the panel keeps the
            // preview's inset steady, so the text does not jump when it shows.
            .overlay(alignment: .top) {
                NoteHistoryChangeJumper(
                    changes: state.changes,
                    viewport: viewport,
                    reveal: { location in
                        state.navigation.revealSearchMatch?(NSRange(location: location, length: 0))
                    }
                )
                .alignmentGuide(.top) { $0[.bottom] - 8 }
            }
            .background {
                LinearGradient(
                    stops: [
                        .init(color: MehStyle.paperColor.opacity(0), location: 0),
                        .init(color: MehStyle.paperColor, location: 0.35),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }
        }
        // History must fit the window it opens in; on the Mac a taller
        // minimum would grow the window.
        .frame(minHeight: 0, maxHeight: .infinity)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: onDone)
                    .accessibilityIdentifier("note-history-done")
            }
            ToolbarItem {
                Button("Restore…") { showingRestoreChoices = true }
                    .disabled(state.isViewingCurrent || state.isLoadingPreview)
                    .accessibilityIdentifier("note-history-restore")
            }
        }
        .confirmationDialog(
            "Restore this version?",
            isPresented: $showingRestoreChoices,
            titleVisibility: .visible
        ) {
            Button("Restore This Note…") { confirmingReplacement = true }
            Button("Restore as New Note", action: onRestoreAsNewNote)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Choose where to put the selected text.")
        }
        .alert(
            "Replace this note’s current text?",
            isPresented: $confirmingReplacement
        ) {
            Button("Restore This Note", role: .destructive, action: onRestoreThisNote)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current text will remain available in History.")
        }
        .onAppear {
            let browser = state
            let navigation = browser.navigation
            let viewport = viewport
            navigation.visibleRangeChanged = { [weak viewport] range in
                if viewport?.range != range { viewport?.range = range }
            }
            navigation.removalTapped = { removal, rect in
                self.removal = NoteHistoryRemovalPopover(text: removal.text, rect: rect)
            }
            navigation.whenAttached { [weak navigation, weak browser] in
                // At the top, the editor's offset includes the note title,
                // which the preview shows above the text instead.
                guard let navigation, let position = browser?.originalPosition,
                      position.scrollAnchor > 0 else {
                    return
                }
                navigation.restorePosition?(position)
            }
        }
    }
}

private struct NoteHistoryRemovalPopover: Identifiable {
    let id = UUID()
    let text: String
    let rect: CGRect
}

/// The text range on screen. Only the change jumper reads it, so scrolling
/// does not re-render the rest of History.
@MainActor
@Observable
private final class NoteHistoryViewport {
    var range: NSRange?
}

private struct NoteHistoryHeading: View {
    let title: String
    let version: NoteHistoryVersion?
    let isDetailed: Bool
    let fontSize: Double
    let fontFamily: EditorFontFamily
    @AppStorage(EditorLineWidth.key, store: NotebookEditorPreferences.store)
    private var lineWidth = EditorLineWidth.standard
    @State private var width: CGFloat = 0
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var margin: CGFloat {
        EditorTextMargin.horizontal(
            width: width,
            maxTextWidth: lineWidth.maxTextWidth(fontSize: fontSize, fontFamily: fontFamily),
            isCompact: sizeClass == .compact
        )
    }

    private var status: String {
        guard let version else { return String(localized: "Current version") }
        guard let date = version.date else { return String(localized: "Date unavailable") }
        var format = Date.FormatStyle.dateTime.weekday(.wide).day().month(.wide).hour().minute()
        if !Calendar.current.isDate(date, equalTo: .now, toGranularity: .year) {
            format = format.year()
        }
        if isDetailed { format = format.second() }
        return date.formatted(format)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(Font(MarkdownPresentation.headingFont(
                    level: 1,
                    bodyFont: MarkdownPresentation.bodyFont(
                        for: fontFamily,
                        pointSize: MarkdownPresentation.normalizedFontSize(fontSize)
                    )
                )))
                .foregroundStyle(.primary)
                .accessibilityIdentifier("note-history-title")
            Label(status, systemImage: "clock.arrow.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("note-history-status")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, margin)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

/// Fast steps would flash a spinner for every version. It shows only when
/// a version takes a moment.
private struct NoteHistoryLoadingIndicator: View {
    @State private var isVisible = false

    var body: some View {
        ProgressView("Loading version…")
            .padding(12)
            .background(.regularMaterial, in: .rect(cornerRadius: 12))
            .opacity(isVisible ? 1 : 0)
            .accessibilityHidden(true)
            .background {
                // VoiceOver and UI tests learn about loading right away.
                Color.clear
                    .accessibilityElement()
                    .accessibilityLabel("Loading version…")
                    .accessibilityIdentifier("note-history-preview-loading")
            }
            .task {
                try? await Task.sleep(for: .milliseconds(250))
                isVisible = true
            }
    }
}

// MARK: - Changes

/// Where the changes are in the whole note, along the right edge.
private struct NoteHistoryScrollMarks: View {
    let changes: NoteHistoryChanges
    let textLength: Int
    @Environment(\.mehPalette) private var palette

    var body: some View {
        if !changes.isEmpty, textLength > 0 {
            Canvas { context, size in
                let length = CGFloat(textLength)
                func mark(at location: Int, color: Color) {
                    let y = size.height * CGFloat(location) / length
                    context.fill(
                        Path(roundedRect: CGRect(x: 0, y: min(y, size.height - 3), width: 6, height: 3),
                             cornerRadius: 1.5),
                        with: .color(color)
                    )
                }
                for range in changes.changed { mark(at: range.location, color: palette.strokeColor) }
                for removal in changes.removed { mark(at: removal.location, color: .secondary) }
            }
            .frame(width: 6)
            .padding(.vertical, 24)
            .padding(.trailing, 3)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// Steps through changes that are off screen. Hidden when every change is
/// already visible.
private struct NoteHistoryChangeJumper: View {
    let changes: NoteHistoryChanges
    let viewport: NoteHistoryViewport
    let reveal: (Int) -> Void
    @State private var current: Int?

    private var locations: [Int] {
        (changes.changed.map(\.location) + changes.removed.map(\.location)).sorted()
    }

    var body: some View {
        let locations = locations
        let visible = viewport.range
        let isAllVisible = visible.map { range in
            locations.allSatisfy { $0 >= range.location && $0 <= NSMaxRange(range) }
        } ?? true
        if !locations.isEmpty, !isAllVisible {
            let targets = targets(in: locations, visible: visible)
            HStack(spacing: 2) {
                Button {
                    targets.previous.map { move(to: $0, in: locations) }
                } label: {
                    Image(systemName: "chevron.up").frame(width: 32, height: 30)
                }
                .disabled(targets.previous == nil)
                .accessibilityLabel("Previous change")
                Text("Change \(targets.shown + 1) of \(locations.count)")
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
                Button {
                    targets.next.map { move(to: $0, in: locations) }
                } label: {
                    Image(systemName: "chevron.down").frame(width: 32, height: 30)
                }
                .disabled(targets.next == nil)
                .accessibilityLabel("Next change")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
            .glassEffect(.regular.interactive(), in: .capsule)
            .accessibilityIdentifier("note-history-change-jumper")
            .onChange(of: changes) { current = nil }
            .transition(.opacity)
        }
    }

    /// After a jump the arrows step from that change. Otherwise they go to
    /// the nearest change above or below the screen.
    private func targets(
        in locations: [Int], visible: NSRange?
    ) -> (shown: Int, previous: Int?, next: Int?) {
        let range = visible ?? NSRange(location: 0, length: 0)
        func isVisible(_ location: Int) -> Bool {
            location >= range.location && location <= NSMaxRange(range)
        }
        if let current, locations.indices.contains(current), isVisible(locations[current]) {
            return (
                current,
                current > 0 ? current - 1 : nil,
                current < locations.count - 1 ? current + 1 : nil
            )
        }
        let above = locations.lastIndex { $0 < range.location }
        let below = locations.firstIndex { $0 > NSMaxRange(range) }
        return (below ?? above ?? 0, above, below)
    }

    private func move(to index: Int, in locations: [Int]) {
        guard locations.indices.contains(index) else { return }
        current = index
        reveal(locations[index])
    }
}
