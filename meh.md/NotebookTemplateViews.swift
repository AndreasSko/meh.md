import NoteCore
import SwiftUI

struct NotebookTemplatesSettingsView: View {
    let replica: NotebookReplica
    var onOpenNote: ((UUID) -> Void)? = nil

    var body: some View {
        let folders = replica.templateSources.filter { $0.kind == .folder }
        let templates = replica.templates
        List {
            if folders.isEmpty && templates.isEmpty {
                ContentUnavailableView {
                    Label("No Templates Yet", systemImage: "doc.on.doc")
                } description: {
                    Text("Touch and hold a note or folder in Files, then choose Use as Template. On Mac, use its context menu.")
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
                    Text("Creating from a template copies its current Markdown into an independent new note.")
                }
            }
        }
        .navigationTitle("Templates")
        .accessibilityIdentifier("notebook-templates-overview")
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
                        Text("Use a note or folder as a template from its context menu in Files.")
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

    var body: some View {
        let source = replica.placements.first { $0.item.id == sourceID }
        let template = replica.templates.first { $0.id == sourceID }
        let isFolder = source?.item.kind == .folder
        Form {
            Section {
                if let source {
                    Label(source.displayName,
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
                    Text("The source note stays ordinary Markdown. New notes receive a copy of its current content.")
                }
            }
            NotebookTemplateDestinationSection(
                placements: replica.placements, destination: $destination,
                inheritedLabel: inheritedTemplateFolderID == nil
                    ? "Usual new-note destination" : "Template folder default"
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
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(saving || filenameValidationMessage != nil)
                    .accessibilityIdentifier("notebook-save-template-options")
            }
        }
        .task {
            guard !loaded else { return }
            let settings = replica.templateSettings(for: sourceID)
            destination = settings.destination
            customFilename = settings.filenamePattern != nil
            filenamePattern = settings.filenamePattern ?? "{{date}} — {{template}}"
            loaded = true
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

    private func save() {
        guard !saving else { return }
        saving = true
        Task { @MainActor in
            defer { saving = false }
            do {
                try await replica.setTemplateSettings(
                    NotebookTemplateSettings(
                        destination: destination,
                        filenamePattern: customFilename ? filenamePattern : nil
                    ), for: sourceID
                )
                dismiss()
            } catch { errorMessage = error.localizedDescription }
        }
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
        Section("New Note Destination") {
            Picker("Save in", selection: $destination) {
                Text(inheritedLabel).tag(NotebookTemplateDestination.inherit)
                Text("Root").tag(NotebookTemplateDestination.root)
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
            Toggle("Custom filename", isOn: $customFilename)
                .accessibilityIdentifier("notebook-template-custom-filename")
            if customFilename {
                TextField("{{date}} — {{template}}", text: $filenamePattern)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .accessibilityIdentifier("template-filename-pattern")
                Menu("Insert Variable") {
                    Button("Date") { filenamePattern += "{{date}}" }
                    Button("Time") { filenamePattern += "{{time}}" }
                    Button("Template name") { filenamePattern += "{{template}}" }
                }
            }
            if let preview = preview {
                LabeledContent("Preview", value: preview)
                    .font(.footnote)
                    .accessibilityIdentifier("notebook-template-filename-preview")
            }
            if let validationMessage {
                Text(validationMessage).foregroundStyle(.red)
                    .font(.footnote)
            }
        } header: {
            Text("New Note Filename")
        } footer: {
            if isFolder {
                Text("Without a custom filename, notes use the parent template folder’s default or the usual date-based name. Template name uses each source note’s name.")
            } else {
                Text("Without a custom filename, notes use their template folder’s default or the usual date-based name. Matching filenames receive a number.")
            }
        }
    }

    private var preview: String? {
        let pattern = customFilename ? filenamePattern : inheritedPattern
        return try? NotebookTemplateFilename.preview(
            pattern: pattern,
            templateName: templateName
        )
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
