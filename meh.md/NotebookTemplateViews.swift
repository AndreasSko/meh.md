import NoteCore
import SwiftUI

struct NotebookTemplatesSettingsView: View {
    let replica: NotebookReplica
    var onOpenNote: ((UUID) -> Void)? = nil

    var body: some View {
        let folders = replica.templateSources.filter { $0.kind == .folder }
        let templates = replica.templates
        let isEmpty = folders.isEmpty && templates.isEmpty
            && replica.snippetSources.isEmpty && replica.snippets.isEmpty
        List {
            if isEmpty {
                ContentUnavailableView {
                    Label("No Templates or Snippets Yet", systemImage: "doc.on.doc")
                } description: {
                    Text("In Files, touch and hold a note or folder to use it as a template or snippet. On Mac, use its context menu. Templates create new notes; snippets insert Markdown into the note you’re editing.")
                }
            } else {
                if folders.isEmpty && templates.isEmpty {
                    Section {
                        Text("No Templates Yet").foregroundStyle(.secondary)
                    } header: {
                        Text("Templates")
                    } footer: {
                        Text("A template starts new notes. In Files, open a note’s menu and choose Templates & Snippets › Use as Template.")
                    }
                }
                if !folders.isEmpty {
                    Section {
                        ForEach(folders) { folder in
                            NavigationLink {
                                NotebookTemplateOptionsView(
                                    replica: replica, sourceID: folder.id,
                                    onOpenNote: onOpenNote
                                )
                            } label: {
                                NotebookTemplateRow(
                                    name: folder.name, path: folder.path,
                                    systemImage: "folder"
                                )
                            }
                            .accessibilityIdentifier(
                                "notebook-template-folder-options-" + folder.id.uuidString
                            )
                        }
                    } header: {
                        Text("Template Folders")
                    } footer: {
                        Text("All notes in these folders and their subfolders are available as templates. Folder defaults can be overridden for each template.")
                    }
                }
                if !templates.isEmpty {
                    Section {
                        ForEach(templates) { template in
                            NavigationLink {
                                NotebookTemplateOptionsView(
                                    replica: replica, sourceID: template.id,
                                    onOpenNote: onOpenNote
                                )
                            } label: {
                                NotebookTemplateRow(
                                    name: template.name, path: template.path,
                                    systemImage: "doc.text"
                                )
                            }
                            .accessibilityIdentifier(
                                "notebook-template-options-" + template.id.uuidString
                            )
                        }
                    } header: {
                        Text("Templates")
                    } footer: {
                        Text("A new note starts as a copy of its template.")
                    }
                }
                NotebookSnippetOverviewSections(
                    replica: replica, onOpenNote: onOpenNote
                )
            }
        }
        .navigationTitle("Templates & Snippets")
        .accessibilityIdentifier("notebook-templates-overview")
    }
}

private struct NotebookSnippetOverviewSections: View {
    let replica: NotebookReplica
    let onOpenNote: ((UUID) -> Void)?

    var body: some View {
        let folders = replica.snippetSources.filter { $0.kind == .folder }
        let snippets = replica.snippets
        if !folders.isEmpty {
            Section {
                ForEach(folders) { folder in
                    NavigationLink {
                        NotebookSnippetSourceView(
                            replica: replica, sourceID: folder.id,
                            onOpenNote: onOpenNote
                        )
                    } label: {
                        NotebookTemplateRow(
                            name: folder.name, path: folder.path,
                            systemImage: "folder"
                        )
                    }
                    .accessibilityIdentifier(
                        "notebook-snippet-folder-overview-" + folder.id.uuidString
                    )
                }
            } header: {
                Text("Snippet Folders")
            } footer: {
                Text("All notes in these folders and their subfolders are available as snippets, including notes you add later.")
            }
        }
        Section {
            if snippets.isEmpty {
                Text("No Snippets Yet")
                    .foregroundStyle(.secondary)
            }
            ForEach(snippets) { snippet in
                NavigationLink {
                    NotebookSnippetSourceView(
                        replica: replica, sourceID: snippet.id,
                        onOpenNote: onOpenNote
                    )
                } label: {
                    NotebookTemplateRow(
                        name: snippet.name, path: snippet.path,
                        systemImage: "doc.text"
                    )
                }
                .accessibilityIdentifier(
                    "notebook-snippet-overview-" + snippet.id.uuidString
                )
            }
        } header: {
            Text("Snippets")
        } footer: {
            if snippets.isEmpty {
                Text("A snippet adds its text where you’re writing. In Files, open a note’s menu and choose Templates & Snippets › Use as Snippet.")
            } else {
                Text("Insert a snippet from the formatting bar. Open one here to edit it.")
            }
        }
    }
}

private struct NotebookSnippetSourceView: View {
    let replica: NotebookReplica
    let sourceID: UUID
    let onOpenNote: ((UUID) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var removing = false
    @State private var errorMessage: String?

    var body: some View {
        let source = replica.snippetSources.first { $0.id == sourceID }
        let snippet = replica.snippets.first { $0.id == sourceID }
        let isFolder = source?.kind == .folder
        Form {
            if let name = source?.name ?? snippet?.name,
               let path = source?.path ?? snippet?.path {
                NotebookSnippetSourceSection(
                    name: name, path: path, isFolder: isFolder,
                    sourceID: sourceID, onOpenNote: onOpenNote
                )
                if replica.isSnippetSource(sourceID) {
                    Section {
                        Button(role: .destructive, action: removeSource) {
                            if isFolder {
                                Text("Stop Using as Snippet Folder")
                            } else {
                                Text("Stop Using as Snippet")
                            }
                        }
                        .accessibilityIdentifier("notebook-remove-snippet-source")
                        if removing { ProgressView("Updating Snippets…") }
                    } footer: {
                        Text("The original note or folder and its contents are kept. Notes may remain available through other snippet folders or individual registrations.")
                    }
                } else {
                    Section {
                        Text("To stop using this snippet, move the note outside its snippet folders or stop using those folders as snippets.")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                ContentUnavailableView(
                    "Snippet Unavailable", systemImage: "doc.text",
                    description: Text("This source is no longer available as a snippet.")
                )
            }
            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                        .accessibilityIdentifier("notebook-snippet-source-error")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text(isFolder
            ? LocalizedStringResource("Snippet Folder")
            : LocalizedStringResource("Snippet")))
        .disabled(removing)
        .accessibilityIdentifier("notebook-snippet-source-detail")
    }

    private func removeSource() {
        guard !removing else { return }
        removing = true
        errorMessage = nil
        Task { @MainActor in
            defer { removing = false }
            do {
                try await replica.setSnippetSource(sourceID, enabled: false)
                dismiss()
            } catch { errorMessage = error.localizedDescription }
        }
    }
}

private struct NotebookSnippetSourceSection: View {
    let name: String
    let path: String
    let isFolder: Bool
    let sourceID: UUID
    let onOpenNote: ((UUID) -> Void)?

    var body: some View {
        Section {
            NotebookTemplateRow(
                name: name, path: path,
                systemImage: isFolder ? "folder" : "doc.text"
            )
            if let onOpenNote {
                Button {
                    onOpenNote(sourceID)
                } label: {
                    if isFolder {
                        Text("Show Folder in Files")
                    } else {
                        Text("Edit Snippet")
                    }
                }
                .accessibilityIdentifier("notebook-open-snippet-source")
            }
        } footer: {
            if isFolder {
                Text("Notes in this folder and its subfolders are available as snippets. Edit those Markdown notes in Files to change what is inserted.")
            } else {
                Text("Edit this Markdown note to change the snippet. Type {{ in the source for variables. Inserting copies its current content; previously inserted text stays unchanged.")
            }
        }
    }
}

struct NotebookTemplatePicker: View {
    let replica: NotebookReplica
    let onCreate: (UUID) async throws -> Void
    var onOpenNote: ((UUID) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var creatingTemplateID: UUID?
    @State private var errorMessage: String?

    private var creating: Bool { creatingTemplateID != nil }

    var body: some View {
        NavigationStack {
            List {
                if replica.templates.isEmpty {
                    ContentUnavailableView {
                        Label("No Templates Yet", systemImage: "doc.on.doc")
                    } description: {
                        Text("In Files, open a note’s menu and choose Templates & Snippets › Use as Template.")
                    } actions: {
                        NavigationLink("Manage Templates") {
                            NotebookTemplatesSettingsView(
                                replica: replica, onOpenNote: onOpenNote
                            )
                        }
                    }
                } else if matchingTemplates.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else {
                    ForEach(matchingTemplates) { template in
                        Button {
                            create(template.id)
                        } label: {
                            HStack {
                                NotebookTemplateRow(
                                    name: template.name, path: template.path,
                                    systemImage: "doc.text"
                                )
                                Spacer()
                                if creatingTemplateID == template.id {
                                    ProgressView()
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(
                            "notebook-template-choice-" + template.id.uuidString
                        )
                    }
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("notebook-template-creation-error")
                    }
                }
            }
            .disabled(creating)
            .searchable(text: $search, prompt: "Find a template")
            .navigationTitle("New from Template")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(creating)
                }
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        NotebookTemplatesSettingsView(
                            replica: replica, onOpenNote: onOpenNote
                        )
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Manage Templates")
                    .accessibilityIdentifier("notebook-manage-templates")
                    .disabled(creating)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 480, minHeight: 420, idealHeight: 540)
        #endif
        .interactiveDismissDisabled(creating)
        .accessibilityIdentifier("notebook-template-picker")
    }

    private var matchingTemplates: [NotebookTemplate] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return replica.templates.filter {
            query.isEmpty || $0.name.localizedStandardContains(query)
                || $0.path.localizedStandardContains(query)
        }
    }

    private func create(_ templateID: UUID) {
        guard !creating else { return }
        creatingTemplateID = templateID
        errorMessage = nil
        Task { @MainActor in
            defer { creatingTemplateID = nil }
            do {
                try await onCreate(templateID)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct NotebookTemplateRow: View {
    let name: String
    let path: String
    let systemImage: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(NotebookNoteName.title(from: name))
                    .foregroundStyle(.primary)
                Text(path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        } icon: {
            Image(systemName: systemImage).foregroundStyle(.tint)
        }
    }
}

private struct NotebookTemplateOptionsView: View {
    let replica: NotebookReplica
    let sourceID: UUID
    let onOpenNote: ((UUID) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var destination: NotebookTemplateDestination = .inherit
    @State private var customFilename = false
    @State private var filenamePattern = ""
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var loaded = false
    @State private var savedDraft: Draft?

    /// What the screen shows; it saves on its own, like the rest of Settings.
    private struct Draft: Hashable {
        let destination: NotebookTemplateDestination
        let filenamePattern: String?
    }

    private var draft: Draft {
        Draft(destination: destination,
              filenamePattern: customFilename ? filenamePattern : nil)
    }

    var body: some View {
        let source = replica.placements.first { $0.item.id == sourceID }
        let template = replica.templates.first { $0.id == sourceID }
        let isFolder = source?.item.kind == .folder
        Form {
            Section {
                if let source {
                    Label(isFolder ? source.displayName
                            : NotebookNoteName.title(from: source.displayName),
                          systemImage: isFolder ? "folder" : "doc.text")
                }
                if !isFolder, let onOpenNote {
                    Button("Edit Template") { onOpenNote(sourceID) }
                }
            } footer: {
                if isFolder {
                    Text("These defaults apply to templates in this folder and its subfolders.")
                } else if let parentID = template?.inheritedFromID,
                          let parent = replica.templateSources.first(where: {
                              $0.id == parentID
                          }) {
                    Text("Available through \(parent.name). Defaults come from that folder unless you override them here.")
                } else {
                    Text("New notes start as a copy of this note. To fill in the date or other details, type {{ in it.")
                }
            }
            NotebookTemplateDestinationSection(
                placements: replica.placements, destination: $destination,
                inheritedLabel: inheritedTemplateFolderID == nil
                    ? "Same as Other New Notes" : "Same as Template Folder"
            )
            NotebookTemplateFilenameSection(
                customFilename: $customFilename,
                filenamePattern: $filenamePattern,
                templateName: isFolder ? "Example.md"
                    : source?.displayName ?? "Template.md",
                inheritedPattern: inheritedFilenamePattern,
                isFolder: isFolder
            )
            if replica.isTemplateSource(sourceID) {
                Section {
                    Button(role: .destructive, action: removeSource) {
                        if isFolder {
                            Text("Stop Using as Template Folder")
                        } else if inheritedTemplateFolderID != nil {
                            Text("Stop Using as Individual Template")
                        } else {
                            Text("Remove from Templates")
                        }
                    }
                } footer: {
                    if inheritedTemplateFolderID != nil {
                        if isFolder {
                            Text("The folder and its contents are kept. Notes remain available through the parent template folder.")
                        } else {
                            Text("The note is kept and remains available through its template folder. Its template settings are kept.")
                        }
                    } else {
                        Text("The original note or folder and its contents are kept.")
                    }
                }
            } else if template?.inheritedFromID != nil {
                Section {
                    Text("To remove this template, move the note outside its template folders or stop using those folders as templates.")
                        .foregroundStyle(.secondary)
                }
            }
            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text(isFolder
            ? LocalizedStringResource("Template Folder")
            : LocalizedStringResource("Template Options")))
        .disabled(saving)
        .task {
            guard !loaded else { return }
            let settings = replica.templateSettings(for: sourceID)
            destination = settings.destination
            customFilename = settings.filenamePattern != nil
            filenamePattern = settings.filenamePattern ?? "{{date}} — {{template}}"
            savedDraft = draft
            loaded = true
        }
        // Typing a title waits a moment, so not every key writes the notebook.
        .task(id: draft) {
            guard loaded, draft != savedDraft else { return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await save(draft)
        }
        .onDisappear {
            let pending = draft
            guard loaded, pending != savedDraft else { return }
            Task { await save(pending) }
        }
    }

    private var inheritedFilenamePattern: String? {
        let byID = Dictionary(uniqueKeysWithValues: replica.placements.map {
            ($0.item.id, $0)
        })
        var next = byID[sourceID]?.parentID
        var visited: Set<UUID> = [sourceID]
        while let id = next, visited.insert(id).inserted,
              let parent = byID[id] {
            if replica.isTemplateSource(id),
               let pattern = replica.templateSettings(for: id).filenamePattern {
                return pattern
            }
            next = parent.parentID
        }
        return nil
    }

    private var inheritedTemplateFolderID: UUID? {
        let byID = Dictionary(uniqueKeysWithValues: replica.placements.map {
            ($0.item.id, $0)
        })
        var next = byID[sourceID]?.parentID
        var visited: Set<UUID> = [sourceID]
        while let id = next, visited.insert(id).inserted,
              let parent = byID[id] {
            if replica.isTemplateSource(id) { return id }
            next = parent.parentID
        }
        return nil
    }

    private var filenameValidationMessage: String? {
        guard customFilename else { return nil }
        do {
            _ = try NotebookTemplateFilename.preview(
                pattern: filenamePattern,
                templateName: replica.placements.first {
                    $0.item.id == sourceID
                }?.displayName ?? "Template.md"
            )
            return nil
        } catch { return error.localizedDescription }
    }

    private func save(_ draft: Draft) async {
        if draft.filenamePattern != nil, filenameValidationMessage != nil { return }
        do {
            try await replica.setTemplateSettings(
                NotebookTemplateSettings(
                    destination: draft.destination,
                    filenamePattern: draft.filenamePattern
                ), for: sourceID
            )
            savedDraft = draft
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription; return }
        // The draft can change back to what was saved before while this save
        // runs; the debounce then sees nothing new, so write it here.
        if self.draft != draft { await save(self.draft) }
    }

    private func removeSource() {
        guard !saving else { return }
        saving = true
        Task { @MainActor in
            defer { saving = false }
            do {
                try await replica.setTemplateSource(sourceID, enabled: false)
                dismiss()
            } catch { errorMessage = error.localizedDescription }
        }
    }
}

private struct NotebookTemplateDestinationSection: View {
    let placements: [NotebookPlacement]
    @Binding var destination: NotebookTemplateDestination
    let inheritedLabel: LocalizedStringResource

    var body: some View {
        Section("New Notes") {
            Picker("Save In", selection: $destination) {
                Text(inheritedLabel).tag(NotebookTemplateDestination.inherit)
                Text("Top Level").tag(NotebookTemplateDestination.root)
                ForEach(activeFolders, id: \.item.id) { folder in
                    Text(path(for: folder)).tag(
                        NotebookTemplateDestination.folder(folder.item.id)
                    )
                }
                if case .folder(let id) = destination,
                   !activeFolders.contains(where: { $0.item.id == id }) {
                    Text("Unavailable folder")
                        .tag(NotebookTemplateDestination.folder(id))
                }
            }
            .accessibilityIdentifier("template-destination")
        }
    }

    private var activeFolders: [NotebookPlacement] {
        placements.filter { $0.item.kind == .folder && !$0.isInTrash }
            .sorted { path(for: $0).localizedStandardCompare(path(for: $1))
                == .orderedAscending }
    }

    private func path(for folder: NotebookPlacement) -> String {
        let byID = Dictionary(uniqueKeysWithValues: placements.map {
            ($0.item.id, $0)
        })
        var parts = [folder.displayName]
        var parentID = folder.parentID
        var visited: Set<UUID> = [folder.item.id]
        while let id = parentID, visited.insert(id).inserted,
              let parent = byID[id] {
            parts.insert(parent.displayName, at: 0)
            parentID = parent.parentID
        }
        return parts.joined(separator: " / ")
    }
}

private struct NotebookTemplateFilenameSection: View {
    @Binding var customFilename: Bool
    @Binding var filenamePattern: String
    let templateName: String
    let inheritedPattern: String?
    let isFolder: Bool

    var body: some View {
        Section {
            Toggle("Custom Title", isOn: $customFilename)
                .accessibilityIdentifier("notebook-template-custom-filename")
            if customFilename {
                TextField("{{date}} — {{template}}", text: $filenamePattern)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .accessibilityIdentifier("template-filename-pattern")
                HStack(spacing: 8) {
                    Text("Add").foregroundStyle(.secondary)
                    variableButton("Date", token: "{{date}}")
                    variableButton("Time", token: "{{time}}")
                    variableButton("Template", token: "{{template}}")
                }
                .font(.subheadline)
            }
            if let preview = preview {
                LabeledContent("Example", value: preview)
                    .font(.footnote)
                    .accessibilityIdentifier("notebook-template-filename-preview")
            }
            if let validationMessage {
                Text(validationMessage).foregroundStyle(.red)
                    .font(.footnote)
            }
        } header: {
            Text("Title")
        } footer: {
            if isFolder {
                Text("Without a custom title, notes use the parent template folder’s title or today’s date. Template stands for each template’s own name.")
            } else {
                Text("Without a custom title, notes use their template folder’s title or today’s date. A title already in use gets a number.")
            }
        }
    }

    private func variableButton(_ title: LocalizedStringKey, token: String) -> some View {
        Button(title) {
            // Keep variables apart, so "{{date}}" and "{{template}}" don't run together.
            if let last = filenamePattern.last, !last.isWhitespace, !"-—–_".contains(last) {
                filenamePattern += " "
            }
            filenamePattern += token
        }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
    }

    private var preview: String? {
        let pattern = customFilename ? filenamePattern : inheritedPattern
        return (try? NotebookTemplateFilename.preview(
            pattern: pattern,
            templateName: templateName
        )).map { NotebookNoteName.title(from: $0) }
    }

    private var validationMessage: String? {
        guard customFilename else { return nil }
        do {
            _ = try NotebookTemplateFilename.preview(
                pattern: filenamePattern, templateName: templateName
            )
            return nil
        } catch { return error.localizedDescription }
    }
}
