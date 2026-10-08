import NoteCore
import SwiftUI

@MainActor
@Observable
final class NoteHistoryBrowserState {
    let noteID: UUID
    private(set) var versions: [NoteHistoryVersion]
    private(set) var overviewNavigationStops: [Int]
    private(set) var overviewStops: [Int]
    let expectedHeads: Set<String>
    let originalPosition: MarkdownEditorPosition?
    let currentText: String
    let reader: NoteHistoryReader
    let navigation = MarkdownEditorNavigation()
    private(set) var selectedIndex: Int
    private(set) var text: String
    private(set) var isLoadingIndex = true
    private(set) var isLoadingPreview = false
    @ObservationIgnored private var previewTask: Task<Void, Never>?
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
        let navigationStops = versions.indices.filter {
            versions[$0].isOverviewStop
        } + [versions.count]
        overviewNavigationStops = navigationStops
        overviewStops = Self.makeOverviewStops(from: navigationStops)
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

    func apply(_ update: NoteHistoryIndexUpdate) {
        let viewingCurrent = isViewingCurrent
        versions = update.versions
        overviewNavigationStops = versions.indices.filter {
            versions[$0].isOverviewStop
        } + [versions.count]
        overviewStops = Self.makeOverviewStops(from: overviewNavigationStops)
        if viewingCurrent { selectedIndex = versions.count }
        isLoadingIndex = !update.isComplete
    }

    func cancel() {
        selectionGeneration += 1
        previewTask?.cancel()
        previewTask = nil
    }

    func select(_ index: Int, onError: @escaping (Error) -> Void) {
        guard (0...versions.count).contains(index), index != selectedIndex else { return }
        cancel()
        let generation = selectionGeneration
        let previousPosition = navigation.capturePosition?()
        selectedIndex = index
        if isViewingCurrent {
            isLoadingPreview = false
            installText(currentText, position: previousPosition, generation: generation)
            return
        }
        let version = versions[index]
        isLoadingPreview = true
        previewTask = Task { @MainActor [weak self, reader] in
            do {
                let nextText = try await reader.historicalText(for: version)
                try Task.checkCancellation()
                guard let self, selectionGeneration == generation else { return }
                installText(nextText, position: previousPosition, generation: generation)
                isLoadingPreview = false
                previewTask = nil
            } catch is CancellationError {
                // A newer selection or closing History owns the screen now.
            } catch {
                guard let self, selectionGeneration == generation else { return }
                selectedIndex = versions.count
                text = currentText
                isLoadingPreview = false
                previewTask = nil
                onError(error)
            }
        }
    }

    private func installText(
        _ nextText: String, position previousPosition: MarkdownEditorPosition?,
        generation: Int
    ) {
        text = nextText
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

    private static func makeOverviewStops(from allStops: [Int]) -> [Int] {
        guard allStops.count > 25 else { return allStops }
        // The global slider and date menu stay compact. Previous and Next
        // still visit every grouped stop, and Detail visits every raw state.
        return (0..<25).map { position in
            let offset = position * (allStops.count - 1) / 24
            return allStops[offset]
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

    var body: some View {
        VStack(spacing: 0) {
            NoteHistoryHeading(
                title: title,
                isCurrent: state.isViewingCurrent,
                fontSize: fontSize,
                fontFamily: fontFamily
            )
            MarkdownEditor(
                text: Binding(get: { state.text }, set: { _ in }),
                isReadOnly: true,
                navigation: state.navigation,
                fontSize: fontSize,
                fontFamily: fontFamily,
                mode: mode
            )
            .accessibilityIdentifier("note-history-preview")
            .overlay {
                if state.isLoadingPreview {
                    ProgressView("Loading version…")
                        .padding(12)
                        .background(.regularMaterial, in: .rect(cornerRadius: 12))
                        .accessibilityIdentifier("note-history-preview-loading")
                }
            }
            // Fill the area behind the floating controls. The safe-area
            // inset still keeps the last lines reachable above them.
            .ignoresSafeArea(.container, edges: .bottom)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            NoteHistoryTimeline(
                isLoading: state.isLoadingIndex,
                versions: state.versions,
                overviewNavigationStops: state.overviewNavigationStops,
                overviewStops: state.overviewStops,
                selectedIndex: state.selectedIndex,
                select: { index in
                    state.select(index ?? state.versions.count, onError: onError)
                }
            )
        }
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
            navigation.whenAttached { [weak navigation, weak browser] in
                guard let navigation, let position = browser?.originalPosition else {
                    return
                }
                navigation.restorePosition?(position)
            }
        }
    }

}

private struct NoteHistoryHeading: View {
    let title: String
    let isCurrent: Bool
    let fontSize: Double
    let fontFamily: EditorFontFamily

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
            Label(
                isCurrent ? "Current version" : "Viewing an older version",
                systemImage: "clock.arrow.circlepath"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("note-history-status")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }
}

private struct NoteHistoryTimeline: View {
    private struct DayGroup: Identifiable {
        let id: Int
        let day: Date?
        var indices: [Int]
    }

    let isLoading: Bool
    let versions: [NoteHistoryVersion]
    let overviewNavigationStops: [Int]
    let overviewStops: [Int]
    let selectedIndex: Int
    let select: (Int?) -> Void
    @State private var showingDetail = false
    @State private var detailRange: ClosedRange<Int>?

    private var stops: [Int] {
        if showingDetail {
            return Array(detailRange ?? range(around: selectedIndex))
        }
        return overviewStops
    }

    private var sliderIndex: Int {
        stops.firstIndex(of: selectedIndex) ??
            (stops.lastIndex { $0 < selectedIndex } ?? 0)
    }

    private var menuGroups: [DayGroup] {
        var groups: [DayGroup] = []
        for index in stops where versions.indices.contains(index) {
            let day = versions[index].date.map(Calendar.current.startOfDay(for:))
            if let last = groups.indices.last, groups[last].day == day {
                groups[last].indices.append(index)
            } else {
                groups.append(DayGroup(id: index, day: day, indices: [index]))
            }
        }
        return groups
    }

    var body: some View {
        VStack(spacing: 8) {
            if isLoading {
                ProgressView("Loading versions…")
                    .font(.caption)
                    .accessibilityIdentifier("note-history-index-loading")
            }
            HStack(spacing: 12) {
                Button { step(backward: true) } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .disabled(showingDetail ? selectedIndex == 0
                          : selectedIndex == overviewStops.first)
                .accessibilityLabel("Previous version")
                .accessibilityIdentifier("note-history-previous")

                if stops.count > 1 {
                    Slider(
                        value: Binding(
                            get: { Double(sliderIndex) },
                            set: { value in
                                let offset = min(max(Int(value.rounded()), 0), stops.count - 1)
                                requestSelection(stops[offset])
                            }
                        ),
                        in: 0...Double(stops.count - 1),
                        step: 1
                    )
                    .accessibilityLabel("Version timeline")
                    .accessibilityValue(versionLabel(at: selectedIndex))
                    .accessibilityIdentifier("note-history-timeline")
                }

                Button { step(backward: false) } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .disabled(showingDetail ? selectedIndex == versions.count
                          : selectedIndex == overviewStops.last)
                .accessibilityLabel("Next version")
                .accessibilityIdentifier("note-history-next")
            }
            HStack(spacing: 10) {
                Button {
                    showingDetail.toggle()
                    if showingDetail { detailRange = range(around: selectedIndex) }
                } label: {
                    Text(showingDetail ? "Overview" : "More Detail")
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .disabled(versions.count < 2)
                .accessibilityIdentifier("note-history-detail-toggle")
                Spacer(minLength: 0)
                Menu {
                    ForEach(menuGroups) { group in
                        Section(groupTitle(for: group)) {
                            ForEach(group.indices, id: \.self) { index in
                                Button { requestSelection(index) } label: {
                                    Label(
                                        menuRowLabel(at: index),
                                        systemImage: "number"
                                    )
                                }
                                .accessibilityLabel(versionLabel(at: index))
                            }
                        }
                    }
                    if stops.contains(versions.count) {
                        Button("Current version") { select(nil) }
                    }
                } label: {
                    Label(menuTriggerLabel(at: selectedIndex), systemImage: "calendar")
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .frame(minWidth: 160, maxWidth: 220, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("note-history-date-list")
                .accessibilityLabel(versionLabel(at: selectedIndex))
                .accessibilityHint("Choose a version")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .frame(maxWidth: 520)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .onChange(of: versions.count) { _, _ in
            if showingDetail { detailRange = range(around: selectedIndex) }
        }
    }

    private func requestSelection(_ index: Int) {
        select(versions.indices.contains(index) ? index : nil)
    }

    private func step(backward: Bool) {
        if showingDetail {
            let index = selectedIndex + (backward ? -1 : 1)
            if detailRange?.contains(index) != true {
                detailRange = range(around: index)
            }
            requestSelection(index)
        } else {
            let offset: Int
            if backward {
                let lower = overviewNavigationStops.lastIndex {
                    $0 <= selectedIndex
                } ?? 0
                offset = overviewNavigationStops[lower] == selectedIndex
                    ? max(0, lower - 1) : lower
            } else {
                offset = overviewNavigationStops.firstIndex {
                    $0 > selectedIndex
                } ?? overviewNavigationStops.count - 1
            }
            requestSelection(overviewNavigationStops[offset])
        }
    }

    private func range(around index: Int) -> ClosedRange<Int> {
        max(0, index - 12)...min(versions.count, index + 12)
    }

    private func versionLabel(at index: Int) -> String {
        guard versions.indices.contains(index) else {
            return String(localized: "Current version")
        }
        let version = versions[index]
        guard let date = version.date else {
            return String(localized: "Version \(version.ordinal) · Date unavailable")
        }
        let formattedDate = date.formatted(date: .abbreviated, time: .shortened)
        return String(localized: "Version \(version.ordinal) · \(formattedDate)")
    }

    private func menuTriggerLabel(at index: Int) -> String {
        guard versions.indices.contains(index) else {
            return String(localized: "Current version")
        }
        guard let date = versions[index].date else {
            return String(localized: "Date unavailable")
        }
        return date.formatted(date: .numeric, time: .shortened)
    }

    private func groupTitle(for group: DayGroup) -> String {
        guard let day = group.day else {
            return String(localized: "Date unavailable")
        }
        let groups = menuGroups
        if let position = groups.firstIndex(where: { $0.id == group.id }),
           position > 0,
           let previousDay = groups[position - 1].day,
           Calendar.current.isDate(
               previousDay, equalTo: day, toGranularity: .year
           ) {
            return day.formatted(.dateTime.day().month(.abbreviated))
        }
        return day.formatted(.dateTime.day().month(.abbreviated).year())
    }

    private func menuRowLabel(at index: Int) -> String {
        let ordinal = versions[index].ordinal.formatted()
        guard let date = versions[index].date else { return ordinal }
        let time = date.formatted(date: .omitted, time: .shortened)
        return String(localized: "\(ordinal) · \(time)")
    }
}
