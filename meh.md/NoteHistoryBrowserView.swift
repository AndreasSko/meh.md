import NoteCore
import SwiftUI

@MainActor
@Observable
final class NoteHistoryBrowserState {
    let noteID: UUID
    let versions: [NoteHistoryVersion]
    let overviewNavigationStops: [Int]
    let overviewStops: [Int]
    let expectedHeads: Set<String>
    let originalPosition: MarkdownEditorPosition?
    let currentText: String
    let navigation = MarkdownEditorNavigation()
    private(set) var selectedIndex: Int
    private(set) var text: String

    init(
        noteID: UUID,
        versions: [NoteHistoryVersion],
        expectedHeads: Set<String>,
        originalPosition: MarkdownEditorPosition?,
        text: String
    ) {
        self.noteID = noteID
        self.versions = versions
        overviewNavigationStops = versions.indices.filter {
            versions[$0].isOverviewStop
        } + [versions.count]
        overviewStops = Self.makeOverviewStops(from: overviewNavigationStops)
        self.expectedHeads = expectedHeads
        self.originalPosition = originalPosition
        currentText = text
        selectedIndex = versions.count
        self.text = text
    }

    var selectedVersion: NoteHistoryVersion? {
        versions.indices.contains(selectedIndex) ? versions[selectedIndex] : nil
    }
    var isViewingCurrent: Bool { selectedIndex == versions.count }

    func select(_ index: Int, in session: NoteSession) throws {
        guard (0...versions.count).contains(index), index != selectedIndex else { return }
        let previousPosition = navigation.capturePosition?()
        let nextText = index == versions.count
            ? currentText : try session.historicalText(for: versions[index])
        selectedIndex = index
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
                guard self?.selectedIndex == index else { return }
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
            NoteHistoryTimeline(
                versions: state.versions,
                overviewNavigationStops: state.overviewNavigationStops,
                overviewStops: state.overviewStops,
                selectedIndex: state.selectedIndex,
                select: select
            )
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: onDone)
                    .accessibilityIdentifier("note-history-done")
            }
            ToolbarItem {
                Button("Restore…") { showingRestoreChoices = true }
                    .disabled(state.isViewingCurrent)
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

    private func select(_ index: Int) {
        do { try state.select(index, in: session) }
        catch { onError(error) }
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
    let versions: [NoteHistoryVersion]
    let overviewNavigationStops: [Int]
    let overviewStops: [Int]
    let selectedIndex: Int
    let select: (Int) -> Void
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

    var body: some View {
        VStack(spacing: 8) {
            Divider()
            HStack(spacing: 12) {
                Button { step(backward: true) } label: {
                    Image(systemName: "chevron.left")
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
                                select(stops[offset])
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
                }
                .disabled(showingDetail ? selectedIndex == versions.count
                          : selectedIndex == overviewStops.last)
                .accessibilityLabel("Next version")
                .accessibilityIdentifier("note-history-next")
            }
            HStack(spacing: 10) {
                Button(showingDetail ? "Overview" : "More Detail") {
                    showingDetail.toggle()
                    if showingDetail { detailRange = range(around: selectedIndex) }
                }
                .disabled(versions.count < 2)
                .accessibilityIdentifier("note-history-detail-toggle")
                Spacer(minLength: 0)
                Menu {
                    ForEach(stops, id: \.self) { index in
                        Button(versionLabel(at: index)) { select(index) }
                    }
                } label: {
                    Label(versionLabel(at: selectedIndex), systemImage: "calendar")
                }
                .accessibilityIdentifier("note-history-date-list")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
        .background(.bar)
    }

    private func step(backward: Bool) {
        if showingDetail {
            let index = selectedIndex + (backward ? -1 : 1)
            if detailRange?.contains(index) != true {
                detailRange = range(around: index)
            }
            select(index)
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
            select(overviewNavigationStops[offset])
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
            return String(localized: "Version \(version.ordinal)")
        }
        let formattedDate = date.formatted(date: .abbreviated, time: .shortened)
        return String(localized: "Version \(version.ordinal) · \(formattedDate)")
    }
}
