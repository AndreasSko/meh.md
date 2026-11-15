import NoteCore
import SwiftUI

enum NotebookSettingsRoute: Hashable {
    case syncBackups
}

struct NotebookSettingsView: View {
    let replica: NotebookReplica
    let workspace: NotebookWorkspace
    let beforeExport: () async throws -> Void
    var onOpenNote: ((UUID) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @AppStorage(NotebookReadwise.enabledKey) private var readwiseLabs = false
    @State private var path: [NotebookSettingsRoute]
    @State private var exporting = false

    init(
        replica: NotebookReplica, workspace: NotebookWorkspace,
        beforeExport: @escaping () async throws -> Void,
        onOpenNote: ((UUID) -> Void)? = nil,
        initialRoute: NotebookSettingsRoute? = nil
    ) {
        self.replica = replica
        self.workspace = workspace
        self.beforeExport = beforeExport
        self.onOpenNote = onOpenNote
        _path = State(initialValue: initialRoute.map { [$0] } ?? [])
    }

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section {
                    NavigationLink(value: NotebookSettingsRoute.syncBackups) {
                        NotebookSettingsCard(replica: replica, workspace: workspace)
                    }
                    .accessibilityIdentifier("notebook-sync-backups-settings")
                }
                NotebookWritingSection(replica: replica, onOpenNote: onOpenNote)
                if readwiseLabs {
                    Section {
                        NavigationLink {
                            NotebookReadwiseView(readwise: workspace.readwise, onOpenNote: onOpenNote)
                        } label: {
                            Label("Readwise", systemImage: "highlighter")
                        }
                        .accessibilityIdentifier("notebook-readwise-settings")
                    }
                }
                NotebookAppearanceSection()
                NotebookFeedbackSection(
                    log: workspace.syncEventLog, storage: workspace.syncStorage
                )
                Section {
                    NavigationLink {
                        NotebookLabsView()
                    } label: {
                        Label("Labs", systemImage: "flask")
                    }
                    .accessibilityIdentifier("notebook-labs-settings")
                }
                Section {
                    NotebookSettingsSignature()
                        .listRowBackground(Color.clear)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .navigationDestination(for: NotebookSettingsRoute.self) { _ in
                NotebookSyncBackupsView(
                    replica: replica, workspace: workspace, exporting: $exporting,
                    beforeExport: beforeExport, onOpenNote: onOpenNote
                )
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .disabled(exporting)
                }
            }
            .task { await workspace.reloadBackupInfo() }
        }
        .interactiveDismissDisabled(exporting)
        .notebookMarkdownExporter(
            isPresented: $exporting, replica: replica, beforeExport: beforeExport
        )
    }
}

#if os(macOS)
enum NotebookSettingsTab: Hashable {
    case general, appearance, syncBackups, readwise, labs
}

/// The tab the Settings window shows. Notebook windows set it before they
/// open Settings, such as from the sync popover.
@MainActor @Observable final class NotebookSettingsSelection {
    static let shared = NotebookSettingsSelection()
    var tab = NotebookSettingsTab.general

    func open(_ route: NotebookSettingsRoute?) {
        switch route {
        case .syncBackups: tab = .syncBackups
        case nil: break
        }
    }
}

/// Settings as its own window with tabs, like other Mac apps.
struct NotebookMacSettingsView: View {
    let workspace: NotebookWorkspace
    @Bindable private var selection = NotebookSettingsSelection.shared
    @AppStorage(NotebookReadwise.enabledKey) private var readwiseLabs = false
    @Environment(\.openWindow) private var openWindow
    @State private var exporting = false

    var body: some View {
        Group {
            if let replica = workspace.replica, replica.catalogSnapshot != nil {
                tabs(replica)
                    .notebookMarkdownExporter(
                        isPresented: $exporting, replica: replica,
                        beforeExport: { try await replica.flushOpenNotes() }
                    )
            } else {
                ContentUnavailableView(
                    "Notebook Unavailable", systemImage: "book.closed",
                    description: Text("Settings are available once the notebook is open.")
                )
                .frame(width: 520, height: 320)
            }
        }
        .mehAppearance()
    }

    private func tabs(_ replica: NotebookReplica) -> some View {
        TabView(selection: $selection.tab) {
            Tab("General", systemImage: "gearshape", value: .general) {
                NavigationStack {
                    Form {
                        Section {
                            Button {
                                selection.tab = .syncBackups
                            } label: {
                                NotebookSettingsCard(replica: replica, workspace: workspace)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("notebook-sync-backups-settings")
                        }
                        NotebookWritingSection(replica: replica, onOpenNote: openNote)
                        NotebookFeedbackSection(
                            log: workspace.syncEventLog, storage: workspace.syncStorage
                        )
                        Section {
                            NotebookSettingsSignature()
                                .listRowBackground(Color.clear)
                        }
                    }
                    .formStyle(.grouped)
                }
            }
            Tab("Appearance", systemImage: "paintpalette", value: .appearance) {
                Form { NotebookAppearanceSection() }
                    .formStyle(.grouped)
            }
            Tab("Sync & Backups", systemImage: "arrow.triangle.2.circlepath",
                value: .syncBackups) {
                NavigationStack {
                    NotebookSyncBackupsView(
                        replica: replica, workspace: workspace, exporting: $exporting,
                        beforeExport: { try await replica.flushOpenNotes() },
                        onOpenNote: openNote
                    )
                }
            }
            if readwiseLabs {
                Tab("Readwise", systemImage: "highlighter", value: .readwise) {
                    NavigationStack {
                        NotebookReadwiseView(readwise: workspace.readwise, onOpenNote: openNote)
                    }
                }
            }
            Tab("Labs", systemImage: "flask", value: .labs) {
                NotebookLabsView()
            }
        }
        .frame(width: 520, height: 600)
        .task { await workspace.reloadBackupInfo() }
    }

    private func openNote(_ id: UUID) {
        openWindow(id: "notebook", value: NotebookWindowValue(noteID: id))
    }
}
#endif

/// The notebook at a glance: how many notes, whether they are synced and
/// when they were last backed up. Opens Sync & Backups.
private struct NotebookSettingsCard: View {
    let replica: NotebookReplica
    let workspace: NotebookWorkspace

    var body: some View {
        TimelineView(.everyMinute) { context in
            let sync = NotebookSyncPresentation(workspace: workspace, now: context.date)
            let syncProblem = sync.indicator == .failed
            HStack(spacing: 14) {
                Group {
                    if syncProblem || workspace.backupError != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.title2)
                            .foregroundStyle(.orange)
                    } else {
                        MehFace(mood: sync.mood ?? .neutral, size: 15)
                            .allowsHitTesting(false)
                    }
                }
                .frame(width: 48, height: 48)
                .background(.quaternary.opacity(0.5), in: .circle)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sync & Backups")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(sync.title)
                        .foregroundStyle(syncProblem ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .accessibilityIdentifier("notebook-settings-card-sync")
                    backupStatus(now: context.date)
                        .accessibilityIdentifier("notebook-settings-card-backup")
                }
                .font(.subheadline)
                Spacer(minLength: 0)
                #if os(macOS)
                // A button on the Mac, so it needs its own disclosure hint.
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                #endif
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .accessibilityElement(children: .combine)
    }

    private var noteCount: Int {
        replica.placements.count { $0.item.kind == .note && !$0.isInTrash }
    }

    /// "today at 9:41", or "yesterday" and "3 days ago" for older backups.
    private func backupDate(_ date: Date, now: Date) -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) {
            let time = date.formatted(date: .omitted, time: .shortened)
            return String(localized: "today at \(time)")
        }
        return date.formatted(.relative(presentation: .named))
    }

    @ViewBuilder
    private func backupStatus(now: Date) -> some View {
        let notes = noteCount == 1 ? String(localized: "1 note")
            : String(localized: "\(noteCount) notes")
        Group {
            if workspace.backupError != nil {
                Text("\(notes) · Backup failed").foregroundStyle(.orange)
            } else if let lastBackup = workspace.lastBackup {
                Text("\(notes) · Backed up \(backupDate(lastBackup.createdAt, now: now))")
            } else if workspace.backupFrequency == .off {
                Text("\(notes) · Automatic backups off")
            } else {
                Text("\(notes) · Not backed up yet")
            }
        }
        .foregroundStyle(.secondary)
    }
}

/// Where new notes go and the notes that start or fill in others.
private struct NotebookWritingSection: View {
    let replica: NotebookReplica
    let onOpenNote: ((UUID) -> Void)?
    @State private var destinationError: String?
    @State private var updatingDefaultDestination = false

    var body: some View {
        Section("Writing") {
            Picker("New Notes Go To", selection: Binding(
                get: { replica.defaultNewNoteParentID },
                set: { setDefaultNewNoteParentID($0) }
            )) {
                Text("Top Level").tag(UUID?.none)
                ForEach(activeFolders, id: \.item.id) { placement in
                    Text(folderPath(for: placement))
                        .tag(Optional(placement.item.id))
                }
            }
            .disabled(updatingDefaultDestination)
            .accessibilityIdentifier("notebook-new-note-destination")
            .alert("Couldn’t Change Destination", isPresented: Binding(
                get: { destinationError != nil },
                set: { if !$0 { destinationError = nil } }
            )) {
                Button("OK", role: .cancel) { destinationError = nil }
            } message: {
                Text(destinationError ?? "")
            }
            NavigationLink {
                NotebookTemplatesSettingsView(
                    replica: replica, onOpenNote: onOpenNote
                )
            } label: {
                Text("Templates & Snippets")
            }
            .accessibilityIdentifier("notebook-templates-settings")
        }
    }

    private var activeFolders: [NotebookPlacement] {
        replica.placements
            .filter { $0.item.kind == .folder && !$0.isInTrash }
            .sorted {
                folderPath(for: $0).localizedStandardCompare(folderPath(for: $1))
                    == .orderedAscending
            }
    }

    private func folderPath(for placement: NotebookPlacement) -> String {
        let byID = Dictionary(uniqueKeysWithValues: replica.placements.map {
            ($0.item.id, $0)
        })
        var parts = [placement.displayName]
        var parentID = placement.parentID
        while let id = parentID, let parent = byID[id] {
            parts.insert(parent.displayName, at: 0)
            parentID = parent.parentID
        }
        return parts.joined(separator: " / ")
    }

    private func setDefaultNewNoteParentID(_ id: UUID?) {
        guard !updatingDefaultDestination else { return }
        updatingDefaultDestination = true
        Task { @MainActor in
            defer { updatingDefaultDestination = false }
            do {
                try await replica.setDefaultNewNoteParentID(id)
            } catch {
                destinationError = error.localizedDescription
            }
        }
    }
}

/// The face and version at the end of Settings. Tapping the face cycles its
/// moods, like everywhere else.
private struct NotebookSettingsSignature: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return "\(version) (\(build))"
    }

    var body: some View {
        VStack(spacing: 6) {
            MehFace(mood: .neutral, size: 22)
            Text(verbatim: "meh.md \(version)")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("notebook-settings-version")
    }
}

/// Experiments that are off until someone turns them on on this device.
private struct NotebookLabsView: View {
    @AppStorage(MarkdownTimeCalculator.enabledKey, store: NotebookEditorPreferences.store)
    private var timeCalculator = false
    @AppStorage(NotebookReadwise.enabledKey) private var readwise = false

    var body: some View {
        Form {
            Section {
                Text("Experiments that might still change.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            }
            Section {
                Toggle(isOn: $timeCalculator) {
                    Label("Time Calculator", systemImage: "plus.forwardslash.minus")
                }
                .accessibilityIdentifier("notebook-labs-time-calculator")
                NotebookTimeCalculatorSample()
            } footer: {
                Text("End a line with = to add up the times above it. Turn it on for a note in … › Editor Display.")
            }
            Section {
                Toggle(isOn: $readwise) {
                    Label("Readwise", systemImage: "highlighter")
                }
                .accessibilityIdentifier("notebook-labs-readwise")
            } footer: {
                Text("Keep your Readwise highlights as notes that stay up to date. Set it up in Settings › Readwise.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Labs")
    }
}

/// A short note that shows a sum, drawn like the editor draws it.
private struct NotebookTimeCalculatorSample: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "Flight 2h 55m")
            Text(verbatim: "Taxi 25m")
            HStack(spacing: 0) {
                Text(verbatim: "Travel day = ")
                Text(verbatim: "3h 20m").foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MehStyle.paperColor, in: .rect(cornerRadius: 10))
        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
        .accessibilityHidden(true)
    }
}

/// Lets people pick the two pens the app writes with, next to a small sample
/// of a note that shows both at once.
private struct NotebookAppearanceSection: View {
    @AppStorage(MehPalette.inkKey, store: NotebookEditorPreferences.store)
    private var ink = MehPalette.Ink.black
    @AppStorage(MehPalette.highlighterKey, store: NotebookEditorPreferences.store)
    private var highlighter = MehPalette.Highlighter.yellow
    @AppStorage(NotebookNavigationState.recentCountKey, store: NotebookEditorPreferences.store)
    private var recentCount = NotebookNavigationState.defaultRecentCount
    @AppStorage(NotebookNavigationState.filePreviewsKey, store: NotebookEditorPreferences.store)
    private var showsFilePreviews = false

    var body: some View {
        pens
    }

    private var recents: some View {
        let range = NotebookNavigationState.recentCountRange
        let count = min(max(recentCount, range.lowerBound), range.upperBound)
        return Stepper(
            value: Binding(get: { count }, set: { recentCount = $0 }),
            in: range
        ) {
            HStack {
                Text("Recent Notes")
                Spacer()
                Text(count, format: .number)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityValue(Text(count, format: .number))
        .accessibilityIdentifier("notebook-appearance-recent-count")
    }

    private var pens: some View {
        Section {
            NotebookAppearancePreview(
                palette: MehPalette(ink: ink, highlighter: highlighter)
            )
            NotebookPenPicker(
                title: "Ink", selection: $ink,
                color: { Color(uiPlatformColor: $0.platformColor) }, name: \.name
            )
            .accessibilityIdentifier("notebook-appearance-ink")
            NotebookPenPicker(
                title: "Highlighter", selection: $highlighter,
                color: { Color(uiPlatformColor: $0.platformColor) }, name: \.name
            )
            .accessibilityIdentifier("notebook-appearance-highlighter")
            #if os(iOS)
            NavigationLink {
                NotebookTextSizeSettings()
            } label: {
                Text("Font & Text Size")
            }
            .accessibilityIdentifier("notebook-appearance-text-size")
            #endif
            recents
            Toggle("Previews in Files", isOn: $showsFilePreviews)
                .accessibilityIdentifier("notebook-appearance-file-previews")
        } header: {
            Text("Appearance")
        } footer: {
            Text("Ink colors checkboxes, links and buttons. The highlighter marks highlights, folders and the New Note button. Recent Notes is how many notes Recents shows; pinned notes always show. Previews in Files shows a note's first words under its name.")
        }
    }
}

private struct NotebookAppearancePreview: View {
    let palette: MehPalette

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.square.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(palette.onInkColor, palette.inkColor)
                    Text("Measure the fence")
                }
                Text(sample)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.subheadline)
            Spacer(minLength: 0)
            Image(systemName: "plus")
                .font(.body.weight(.medium))
                .foregroundStyle(MehStyle.onHighlighterColor)
                .frame(width: 32, height: 32)
                .background(palette.highlighterColor, in: .circle)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MehStyle.paperColor, in: .rect(cornerRadius: 10))
        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
        .accessibilityHidden(true)
    }

    private var sample: AttributedString {
        var mark = AttributedString(localized: "blue paint")
        mark.backgroundColor = palette.markColor
        var link = AttributedString(localized: "Garden plan")
        link.foregroundColor = palette.inkColor
        link.underlineStyle = Text.LineStyle(pattern: .solid, color: palette.strokeColor)
        return AttributedString(localized: "Pick up the ") + mark
            + AttributedString(localized: " from ") + link
    }
}

/// A row of color swatches, like the list colors in Reminders.
private struct NotebookPenPicker<Pen: Hashable & CaseIterable>: View
where Pen.AllCases: RandomAccessCollection {
    let title: LocalizedStringResource
    @Binding var selection: Pen
    let color: (Pen) -> Color
    let name: KeyPath<Pen, LocalizedStringResource>

    var body: some View {
        LabeledContent {
            HStack(spacing: 0) {
                ForEach(Array(Pen.allCases), id: \.self) { pen in
                    Button { selection = pen } label: {
                        Circle()
                            .fill(color(pen))
                            .frame(width: 24, height: 24)
                            .padding(3)
                            .overlay {
                                if pen == selection {
                                    Circle().strokeBorder(.secondary, lineWidth: 2)
                                }
                            }
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(pen[keyPath: name]))
                    .accessibilityAddTraits(pen == selection ? .isSelected : [])
                }
            }
        } label: {
            Text(title)
        }
        .sensoryFeedback(.selection, trigger: selection)
    }
}

private extension Color {
    init(uiPlatformColor color: PlatformColor) {
        #if os(macOS)
        self.init(nsColor: color)
        #else
        self.init(uiColor: color)
        #endif
    }
}

#if os(iOS)
/// The editor's font and size, also in each note's menu.
private struct NotebookTextSizeSettings: View {
    @AppStorage("editor.fontSize", store: NotebookEditorPreferences.store)
    private var fontSize = 17.0
    @AppStorage("editor.fontFamily", store: NotebookEditorPreferences.store)
    private var fontFamilyRaw = EditorFontFamily.system.rawValue

    private var size: Int { Int(MarkdownPresentation.normalizedFontSize(fontSize)) }
    private var family: Binding<EditorFontFamily> {
        Binding(
            get: { EditorFontFamily(rawValue: fontFamilyRaw) ?? .system },
            set: { fontFamilyRaw = $0.rawValue }
        )
    }

    // The same settings as the note's Aa menu, as plain Settings rows.
    var body: some View {
        Form {
            Section {
                Picker("Font", selection: family) {
                    ForEach(EditorFontFamily.allCases) { family in
                        Text(family.title).tag(family)
                    }
                }
                .accessibilityIdentifier("editor-font-family")
                LabeledContent("Text Size") {
                    Text("\(size) pt").monospacedDigit()
                }
                Slider(
                    value: Binding(get: { Double(size) }, set: { fontSize = $0 }),
                    in: 12...28, step: 1
                ) {
                    Text("Text Size")
                } minimumValueLabel: {
                    Image(systemName: "textformat.size.smaller")
                } maximumValueLabel: {
                    Image(systemName: "textformat.size.larger")
                }
                .accessibilityValue("\(size) points")
                .accessibilityIdentifier("editor-font-size")
            }
            // The sheet covers the note, so show the choice here.
            Section("Preview") {
                Text("Four days, no plans before ten. Pack light.")
                    .font(Font(MarkdownPresentation.bodyFont(
                        for: family.wrappedValue, pointSize: CGFloat(size)
                    )))
                    .padding(.vertical, 4)
                    .accessibilityIdentifier("editor-font-preview")
            }
            Section {
                Button("Reset to Defaults") {
                    fontFamilyRaw = EditorFontFamily.system.rawValue
                    fontSize = 17
                }
                .disabled(size == 17 && family.wrappedValue == .system)
            }
        }
        .navigationTitle("Font & Text Size")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
