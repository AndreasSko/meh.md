import NoteCore
import SwiftUI

/// Turns stored rules into what the editor runs.
enum NotebookTextRuleLoader {
    static func compiled(_ rule: NotebookTextRule) -> Result<MarkdownCompiledTextRule, MarkdownTextRuleError> {
        MarkdownTextRuleCompiler.compile(MarkdownTextRuleLibrary.source(for: rule.source))
    }

    /// The rules that run in a note, highest in the list first.
    static func configurations(
        rules: [NotebookTextRule], noteIDs: [UUID: Set<UUID>], note: UUID
    ) -> [MarkdownTextRuleConfiguration] {
        rules.compactMap { rule in
            guard rule.isEnabled,
                  rule.appliesToAllNotes || noteIDs[rule.id]?.contains(note) == true,
                  case .success(let compiled) = compiled(rule) else { return nil }
            return MarkdownTextRuleConfiguration(id: rule.id, rule: compiled, options: rule.options)
        }
    }

    static func name(of rule: NotebookTextRule) -> String {
        if case .link(let link) = rule.source, !link.name.isEmpty { return link.name }
        if case .success(let compiled) = compiled(rule) { return compiled.manifest.name }
        return String(localized: "Text Rule")
    }

    /// A note's title as rules see it: its name without `.md`.
    static func title(of name: String) -> String {
        name.lowercased().hasSuffix(".md") ? String(name.dropLast(3)) : name
    }

    static let guideURL = URL(string: "https://github.com/AndreasSko/meh.md/blob/main/docs/text-rules.md")!
    static let examplesURL = URL(string: "https://github.com/AndreasSko/meh.md/blob/main/docs/text-rules.md#example-scripts")!

    static let newScript = """
        // Links "#42" to example.com/issues/42.
        // Guide: https://github.com/AndreasSko/meh.md/blob/main/docs/text-rules.md
        rule({
          api: 1,
          name: "Issue Links",
          example: "Issue #42 is fixed, see #43.",
          linksTo: ["https://example.com/"],
          block(block) {
            const decorations = [];
            for (const match of block.text.matchAll(/#(\\d+)/g)) {
              decorations.push({
                kind: "link",
                start: match.index,
                end: match.index + match[0].length,
                url: "https://example.com/issues/" + match[1],
              });
            }
            return { decorations };
          },
        });

        """
}

/// The Labs entry: the switch, and the rules once it is on.
struct NotebookTextRulesLabsSection: View {
    let replica: NotebookReplica
    @AppStorage(MarkdownTextRules.enabledKey, store: NotebookEditorPreferences.store)
    private var isOn = false

    var body: some View {
        Section {
            Toggle(isOn: $isOn) {
                Label("Text Rules", systemImage: "wand.and.sparkles")
            }
            .accessibilityIdentifier("notebook-labs-text-rules")
            if isOn {
                NavigationLink {
                    NotebookTextRulesView(replica: replica)
                } label: {
                    HStack {
                        Text("Rules")
                        Spacer()
                        Text(replica.textRules.filter(\.isEnabled).count, format: .number)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("notebook-text-rules")
            }
        } footer: {
            Text("Find patterns in your notes, like Bible references, and show them as links or extra details. You add the rules yourself. Your text stays as written. Works in Live Preview.")
        }
    }
}

/// Every rule in the notebook, in the order they win when they overlap.
struct NotebookTextRulesView: View {
    let replica: NotebookReplica
    @State private var error: String?
    @State private var newScript: NotebookTextRule?
    @State private var newLink: NotebookTextRule?

    var body: some View {
        Form {
            if replica.textRules.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text("No Rules")
                    } icon: {
                        MehFace(mood: .neutral, size: 34)
                    }
                } description: {
                    #if os(macOS)
                    Text("A rule finds text in your notes and shows it as a link or with extra details. Click + to add a link rule, or paste a script.")
                    #else
                    Text("A rule finds text in your notes and shows it as a link or with extra details. Tap + to add a link rule, or paste a script.")
                    #endif
                } actions: {
                    VStack(alignment: .leading, spacing: 12) {
                        Link(destination: NotebookTextRuleLoader.examplesURL) {
                            Label("Example Scripts", systemImage: "arrow.up.forward.square")
                        }
                        Link(destination: NotebookTextRuleLoader.guideURL) {
                            Label("Text Rules Guide", systemImage: "arrow.up.forward.square")
                        }
                    }
                    .labelStyle(.titleAndIcon)
                }
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(replica.textRules) { rule in
                        NavigationLink {
                            NotebookTextRuleDetailView(replica: replica, ruleID: rule.id)
                        } label: {
                            NotebookTextRuleRow(rule: rule)
                        }
                        .accessibilityIdentifier("notebook-text-rule-row")
                    }
                    .onMove { from, to in
                        var ids = replica.textRules.map(\.id)
                        ids.move(fromOffsets: from, toOffset: to)
                        perform { try await replica.reorderTextRules(ids) }
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { replica.textRules[$0].id }
                        perform { for id in ids { try await replica.deleteTextRule(id) } }
                    }
                } footer: {
                    if replica.textRules.count > 1 {
                        Text("Where two rules mark the same text, the one higher in the list wins.")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Text Rules")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("New Link Rule…", systemImage: "link") {
                        newLink = NotebookTextRule(source: .link(rule: NotebookTextLinkRule(
                            name: "", find: "", isRegularExpression: false, url: "")))
                    }
                    Button("New Script…", systemImage: "curlybraces") {
                        newScript = NotebookTextRule(source: .script(source: ""))
                    }
                } label: {
                    Label("Add Rule", systemImage: "plus")
                }
                .accessibilityIdentifier("notebook-text-rules-add")
            }
            #if os(iOS)
            if !replica.textRules.isEmpty {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
            #endif
        }
        .sheet(item: $newScript) { rule in
            NotebookTextRuleScriptEditor(replica: replica, rule: rule, isNew: true)
        }
        .sheet(item: $newLink) { rule in
            NotebookTextLinkRuleEditor(replica: replica, rule: rule, isNew: true)
        }
        .alert("Couldn’t Change Rules", isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) {
            Button("OK", role: .cancel) { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private func perform(_ action: @escaping () async throws -> Void) {
        Task {
            do { try await action() } catch { self.error = error.localizedDescription }
        }
    }
}

private struct NotebookTextRuleRow: View {
    let rule: NotebookTextRule

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(NotebookTextRuleLoader.name(of: rule))
                .foregroundStyle(rule.isEnabled ? .primary : .secondary)
            Text(summary)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var summary: LocalizedStringKey {
        if case .failure = NotebookTextRuleLoader.compiled(rule) { return "Needs a Fix" }
        if !rule.isEnabled { return "Off" }
        return rule.appliesToAllNotes ? "All Notes" : "Chosen Notes"
    }
}

/// One rule: on or off, where it runs, its options, and a place to try it.
struct NotebookTextRuleDetailView: View {
    let replica: NotebookReplica
    let ruleID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var sample = ""
    @State private var editing: EditRequest?

    /// What the editor sheet shows, and whether saving adds a rule. Chosen
    /// when the button is tapped, so a deletion meanwhile can't change it.
    private struct EditRequest: Identifiable {
        let rule: NotebookTextRule
        let isNew: Bool
        var id: UUID { rule.id }
    }
    @State private var error: String?
    @State private var confirmingDelete = false
    @State private var runtimeProblem: MarkdownTextRuleError?

    private var rule: NotebookTextRule? { replica.textRules.first { $0.id == ruleID } }

    var body: some View {
        Form {
            if let rule {
                content(rule)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(rule.map(NotebookTextRuleLoader.name(of:)) ?? "")
        .sheet(item: $editing) { request in
            switch request.rule.source {
            case .link:
                NotebookTextLinkRuleEditor(replica: replica, rule: request.rule, isNew: request.isNew)
            default:
                NotebookTextRuleScriptEditor(replica: replica, rule: request.rule, isNew: request.isNew)
            }
        }
        .alert("Couldn’t Change the Rule", isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) {
            Button("OK", role: .cancel) { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    @ViewBuilder
    private func content(_ rule: NotebookTextRule) -> some View {
        let compiled = NotebookTextRuleLoader.compiled(rule)
        if case .success(let compiled) = compiled, !compiled.manifest.description.isEmpty {
            Section {
                Text(compiled.manifest.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            }
        }
        Section {
            Toggle("Use Rule", isOn: binding(rule, \.isEnabled))
                .accessibilityIdentifier("notebook-text-rule-enabled")
            Picker("Runs In", selection: binding(rule, \.appliesToAllNotes)) {
                Text("All Notes").tag(true)
                Text("Chosen Notes").tag(false)
            }
            .accessibilityIdentifier("notebook-text-rule-scope")
        } footer: {
            if !rule.appliesToAllNotes {
                Text("Turn it on for a note in … › Editor Display.")
            }
        }
        switch compiled {
        case .failure(let problem):
            Section("Needs a Fix") {
                Label(problem.localizedDescription, systemImage: "exclamationmark.triangle")
                    .font(.callout.monospaced())
                    .foregroundStyle(.red)
            }
        case .success(let compiled):
            if !compiled.manifest.options.isEmpty {
                Section("Options") {
                    ForEach(compiled.manifest.options, id: \.key) { option in
                        optionRow(option, rule: rule)
                    }
                }
            }
            Section {
                MarkdownEditor(
                    text: $sample, mode: .livePreview,
                    textRules: [MarkdownTextRuleConfiguration(
                        id: rule.id, rule: compiled, options: rule.options)],
                    onTextRuleProblems: { runtimeProblem = $0[rule.id] },
                    showsFormattingBar: false
                )
                // A new preview starts without problems; it reports any it finds.
                .onAppear {
                    runtimeProblem = nil
                    if sample.isEmpty { sample = compiled.manifest.example }
                }
                .overlay(alignment: .topLeading) { NotebookTextRuleSamplePlaceholder(sample: sample) }
                // Turning the rule on again retries a rule that stopped.
                .id(rule.isEnabled)
                .frame(height: 150)
                .listRowInsets(EdgeInsets())
                .accessibilityLabel("Sample text")
                .accessibilityIdentifier("notebook-text-rule-sample")
            } header: {
                Text("Try It")
            } footer: {
                if let runtimeProblem {
                    Label(runtimeProblem.localizedDescription, systemImage: "exclamationmark.triangle")
                        .font(.footnote.monospaced())
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("notebook-text-rule-problem")
                } else {
                    Text("Type here to see what the rule shows. This text isn’t saved.")
                }
            }
            if !compiled.manifest.linksTo.isEmpty {
                Section {
                    ForEach(compiled.manifest.linksTo, id: \.value) { prefix in
                        Text(verbatim: prefix.value)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    }
                } header: {
                    Text("Links Go To")
                } footer: {
                    Text("Links from this rule can only go here.")
                }
            }
        }
        Section {
            switch rule.source {
            case .script:
                Button("Edit Script", systemImage: "curlybraces") {
                    editing = EditRequest(rule: rule, isNew: false)
                }
                    .accessibilityIdentifier("notebook-text-rule-edit")
            case .link:
                Button("Edit Rule", systemImage: "pencil") {
                    editing = EditRequest(rule: rule, isNew: false)
                }
                    .accessibilityIdentifier("notebook-text-rule-edit")
            }
            Link(destination: NotebookTextRuleLoader.guideURL) {
                Label("Text Rules Guide", systemImage: "arrow.up.forward.square")
            }
        }
        Section {
            Button("Delete Rule", role: .destructive) { confirmingDelete = true }
                .confirmationDialog(
                    "Delete “\(NotebookTextRuleLoader.name(of: rule))”?",
                    isPresented: $confirmingDelete, titleVisibility: .visible
                ) {
                    Button("Delete Rule", role: .destructive) {
                        perform {
                            try await replica.deleteTextRule(rule.id)
                            dismiss()
                        }
                    }
                }
        }
    }

    @ViewBuilder
    private func optionRow(_ option: MarkdownTextRuleManifest.Option, rule: NotebookTextRule) -> some View {
        switch option.kind {
        case .choice(let choices):
            Picker(option.title, selection: Binding(
                get: {
                    if case .text(let value) = option.value(in: rule.options) { return value }
                    return choices.first?.value ?? ""
                },
                set: { setOption(option.key, .text($0), in: rule) }
            )) {
                ForEach(choices, id: \.value) { Text($0.title).tag($0.value) }
            }
        case .toggle:
            Toggle(option.title, isOn: Binding(
                get: {
                    if case .toggle(let value) = option.value(in: rule.options) { return value }
                    return false
                },
                set: { setOption(option.key, .toggle($0), in: rule) }
            ))
        case .text:
            TextField(option.title, text: Binding(
                get: {
                    if case .text(let value) = option.value(in: rule.options) { return value }
                    return ""
                },
                set: { setOption(option.key, .text($0), in: rule) }
            ))
        }
    }

    private func binding<Value>(
        _ shown: NotebookTextRule, _ keyPath: WritableKeyPath<NotebookTextRule, Value>
    ) -> Binding<Value> {
        Binding(
            get: { (rule ?? shown)[keyPath: keyPath] },
            set: { value in
                if var turnedOn = rule, keyPath == \NotebookTextRule.isEnabled,
                   value as? Bool == true {
                    turnedOn.isEnabled = true
                    // Turning a rule on again gives one that stopped another try.
                    if case .success(let compiled) = NotebookTextRuleLoader.compiled(turnedOn) {
                        MarkdownTextRuleHealth.clear(compiled.identity)
                    }
                }
                perform { try await replica.updateTextRule(ruleID) { $0[keyPath: keyPath] = value } }
            })
    }

    private func setOption(_ key: String, _ value: NotebookTextRule.OptionValue, in rule: NotebookTextRule) {
        perform { try await replica.updateTextRule(ruleID) { $0.options[key] = value } }
    }

    private func perform(_ action: @escaping () async throws -> Void) {
        Task {
            do { try await action() } catch { self.error = error.localizedDescription }
        }
    }
}

/// The simple form: what to find, and where it links.
struct NotebookTextLinkRuleEditor: View {
    let replica: NotebookReplica
    let rule: NotebookTextRule
    /// Off: editing a rule in the list, which may be deleted meanwhile.
    let isNew: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var link = NotebookTextLinkRule(name: "", find: "", isRegularExpression: false, url: "")
    @State private var sample = "Ticket ABC-123 is done."
    @State private var error: String?
    @State private var confirmingDiscard = false

    private var stored: NotebookTextLinkRule? {
        if case .link(let stored) = rule.source { return stored }
        return nil
    }

    private var hasChanges: Bool {
        link != (stored ?? NotebookTextLinkRule(name: "", find: "", isRegularExpression: false, url: ""))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $link.name, prompt: Text("Tickets"))
                        .accessibilityIdentifier("notebook-link-rule-name")
                }
                Section {
                    TextField("Find", text: $link.find, prompt: Text("Text to find"))
                        .monospaced()
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("notebook-link-rule-find")
                    Toggle("Regular Expression", isOn: $link.isRegularExpression)
                    TextField("Link To", text: $link.url,
                              prompt: Text(verbatim: "https://tracker.example.com/$0"))
                        .monospaced()
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("notebook-link-rule-url")
                    #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                    #endif
                } footer: {
                    if link.isRegularExpression {
                        Text("$0 in the link is replaced by the text found, and $1 to $9 by the expression’s groups, as in [A-Z]+-(\\d+).")
                    } else {
                        Text("$0 in the link is replaced by the text found.")
                    }
                }
                switch compiled {
                case .success(let compiled):
                    Section {
                        MarkdownEditor(text: $sample, mode: .livePreview,
                                       textRules: [MarkdownTextRuleConfiguration(id: rule.id, rule: compiled)],
                                       showsFormattingBar: false)
                            .overlay(alignment: .topLeading) {
                                NotebookTextRuleSamplePlaceholder(sample: sample)
                            }
                            .frame(height: 110)
                            .listRowInsets(EdgeInsets())
                            .accessibilityLabel("Sample text")
                    } header: {
                        Text("Try It")
                    }
                case .failure(let problem):
                    Section {
                        if link.find.isEmpty || link.url.isEmpty {
                            Text("Fill in what to find and where it links to save the rule.")
                                .foregroundStyle(.secondary)
                        } else {
                            Label(problem.message, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(link.name.isEmpty ? "Link Rule" : link.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if hasChanges { confirmingDiscard = true } else { dismiss() }
                    }
                    .confirmationDialog("Discard your changes?", isPresented: $confirmingDiscard) {
                        Button("Discard Changes", role: .destructive) { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(link.find.isEmpty || link.url.isEmpty || compiled.isFailure)
                        .accessibilityIdentifier("notebook-link-rule-save")
                }
            }
            .alert("Couldn’t Save the Rule", isPresented: Binding(
                get: { error != nil }, set: { if !$0 { error = nil } }
            )) {
                Button("OK", role: .cancel) { error = nil }
            } message: {
                Text(error ?? "")
            }
        }
        .interactiveDismissDisabled(hasChanges)
        .onAppear {
            if let stored { link = stored }
        }
    }

    private var compiled: Result<MarkdownCompiledTextRule, MarkdownTextRuleError> {
        MarkdownTextRuleCompiler.compile(MarkdownTextRuleLibrary.linkScript(for: link))
    }

    private func save() {
        let source = NotebookTextRule.Source.link(rule: link)
        Task {
            do {
                try await replica.saveTextRuleSource(source, of: rule, isNew: isNew)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// A script, with what it shows right below while typing.
struct NotebookTextRuleScriptEditor: View {
    let replica: NotebookReplica
    let rule: NotebookTextRule
    /// Off: editing a rule in the list, which may be deleted meanwhile.
    let isNew: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var source = ""
    @State private var sample = ""
    /// On once someone typed their own sample, which then stays.
    @State private var sampleIsOwn = false
    @State private var showLine: Int?
    @State private var runtimeProblem: MarkdownTextRuleError?
    @State private var error: String?
    @State private var confirmingDiscard = false

    private var stored: String {
        if case .script(let stored) = rule.source { return stored }
        return ""
    }

    private var hasChanges: Bool { source != stored }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                NotebookCodeEditor(text: $source, showLine: $showLine)
                    .overlay(alignment: .topLeading) {
                        if source.isEmpty {
                            Text("Paste a script here.")
                                .font(.callout.monospaced())
                                .foregroundStyle(.tertiary)
                                .padding(NotebookCodeEditor.placeholderInsets)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .accessibilityLabel("Script")
                    .accessibilityIdentifier("notebook-text-rule-script")
                Divider()
                status
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if case .success(let compiled) = compiled {
                    Text("Try It")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(MehStyle.paperColor)
                    MarkdownEditor(text: $sample, mode: .livePreview,
                                   textRules: [MarkdownTextRuleConfiguration(
                                       id: rule.id, rule: compiled, options: rule.options)],
                                   onTextRuleProblems: { runtimeProblem = $0[rule.id] },
                                   showsFormattingBar: false)
                        // A script that compiles again gets a new preview,
                        // which reports its own problems.
                        .onAppear { runtimeProblem = nil }
                        .overlay(alignment: .topLeading) { NotebookTextRuleSamplePlaceholder(sample: sample) }
                        .frame(height: 130)
                        .background(MehStyle.paperColor)
                        .accessibilityLabel("Sample text")
                        .accessibilityIdentifier("notebook-text-rule-sample")
                }
            }
            .navigationTitle(name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if hasChanges { confirmingDiscard = true } else { dismiss() }
                    }
                    .confirmationDialog("Discard your changes?", isPresented: $confirmingDiscard) {
                        Button("Discard Changes", role: .destructive) { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(compiled.isFailure)
                        .accessibilityIdentifier("notebook-text-rule-save")
                }
            }
            .alert("Couldn’t Save the Rule", isPresented: Binding(
                get: { error != nil }, set: { if !$0 { error = nil } }
            )) {
                Button("OK", role: .cancel) { error = nil }
            } message: {
                Text(error ?? "")
            }
        }
        .interactiveDismissDisabled(hasChanges)
        .onAppear {
            source = stored
            if case .success(let compiled) = MarkdownTextRuleCompiler.compile(stored) {
                sample = compiled.manifest.example
            }
        }
        // Try It shows the script's own example until someone types there.
        .onChange(of: example) { _, example in
            if let example, !sampleIsOwn { sample = example }
        }
        .onChange(of: sample) { _, sample in
            if let example, sample != example { sampleIsOwn = true }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 520)
        #endif
    }

    private var compiled: Result<MarkdownCompiledTextRule, MarkdownTextRuleError> {
        MarkdownTextRuleCompiler.compile(source)
    }

    private var name: String {
        if case .success(let compiled) = compiled { return compiled.manifest.name }
        return isNew ? String(localized: "New Script") : String(localized: "Script")
    }

    private var example: String? {
        if case .success(let compiled) = compiled { return compiled.manifest.example }
        return nil
    }

    @ViewBuilder
    private var status: some View {
        switch compiled {
        case .success:
            if let runtimeProblem {
                problemLabel(runtimeProblem)
            } else {
                Label("Ready. Try it below.", systemImage: "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .failure where source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            // Nothing written yet isn't a mistake.
            Text("Paste a script, or start from [a template](meh-template:).")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .environment(\.openURL, OpenURLAction { _ in
                    source = NotebookTextRuleLoader.newScript
                    return .handled
                })
                .accessibilityIdentifier("notebook-text-rule-start")
        case .failure(let problem):
            problemLabel(problem)
        }
    }

    /// A problem; one with a line selects that line when tapped.
    @ViewBuilder
    private func problemLabel(_ problem: MarkdownTextRuleError) -> some View {
        let label = Label(problem.localizedDescription, systemImage: "exclamationmark.triangle")
            .font(.footnote.monospaced())
            .foregroundStyle(.red)
            .multilineTextAlignment(.leading)
        if let line = problem.line {
            Button { showLine = line } label: { label }
                .buttonStyle(.plain)
                .accessibilityHint("Selects the line in the script.")
                .accessibilityIdentifier("notebook-text-rule-problem")
        } else {
            label.accessibilityIdentifier("notebook-text-rule-problem")
        }
    }

    private func save() {
        if case .success(let compiled) = compiled { MarkdownTextRuleHealth.clear(compiled.identity) }
        let source = NotebookTextRule.Source.script(source: source)
        Task {
            do {
                try await replica.saveTextRuleSource(source, of: rule, isNew: isNew)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

private extension Result {
    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}

private extension NotebookReplica {
    /// Adds a new rule, or changes only the source of an existing one, so
    /// a deleted rule isn't brought back and other changes are kept.
    func saveTextRuleSource(
        _ source: NotebookTextRule.Source, of rule: NotebookTextRule, isNew: Bool
    ) async throws {
        if isNew {
            var added = rule
            added.source = source
            if case .success(let compiled) = MarkdownTextRuleCompiler.compile(
                MarkdownTextRuleLibrary.source(for: source)) {
                added.appliesToAllNotes = !compiled.manifest.startsInChosenNotes
            }
            try await addTextRule(added)
        } else {
            try await updateTextRule(rule.id) { $0.source = source }
        }
    }
}

/// Plain text for code: no smart quotes or dashes, no corrections, which
/// would quietly break a script.
#if os(iOS)
private struct NotebookCodeEditor: UIViewRepresentable {
    @Binding var text: String
    /// A line to select, counted from 1, like an error's line.
    @Binding var showLine: Int?

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = .monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular)
        view.adjustsFontForContentSizeCategory = true
        view.autocapitalizationType = .none
        view.autocorrectionType = .no
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.keyboardType = .asciiCapable
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        view.delegate = context.coordinator
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
        if let line = showLine {
            let range = Self.range(ofLine: line, in: view.text as NSString)
            view.becomeFirstResponder()
            view.selectedRange = range
            view.scrollRangeToVisible(range)
            DispatchQueue.main.async { showLine = nil }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, UITextViewDelegate {
        let text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textViewDidChange(_ view: UITextView) { text.wrappedValue = view.text }
    }
}
#else
private struct NotebookCodeEditor: NSViewRepresentable {
    @Binding var text: String
    /// A line to select, counted from 1, like an error's line.
    @Binding var showLine: Int?

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let view = scrollView.documentView as? NSTextView else { return scrollView }
        view.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        view.isRichText = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 8, height: 10)
        view.delegate = context.coordinator
        view.string = text
        scrollView.drawsBackground = false
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let view = scrollView.documentView as? NSTextView else { return }
        if view.string != text { view.string = text }
        if let line = showLine {
            let range = Self.range(ofLine: line, in: view.string as NSString)
            view.window?.makeFirstResponder(view)
            view.setSelectedRange(range)
            view.scrollRangeToVisible(range)
            DispatchQueue.main.async { showLine = nil }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textDidChange(_ notification: Notification) {
            if let view = notification.object as? NSTextView { text.wrappedValue = view.string }
        }
    }
}
#endif

extension NotebookCodeEditor {
    /// Where the first character sits, for a placeholder in an empty editor.
    #if os(iOS)
    static let placeholderInsets = EdgeInsets(top: 12, leading: 17, bottom: 0, trailing: 16)
    #else
    static let placeholderInsets = EdgeInsets(top: 10, leading: 13, bottom: 0, trailing: 16)
    #endif

    /// The range of a line, counted from 1, without its line break.
    static func range(ofLine line: Int, in text: NSString) -> NSRange {
        var start = 0
        var current = 1
        while current < line, start < text.length {
            let next = text.lineRange(for: NSRange(location: start, length: 0))
            start = NSMaxRange(next)
            current += 1
        }
        var range = text.lineRange(for: NSRange(location: min(start, text.length), length: 0))
        while range.length > 0,
              [10, 13, 0x85, 0x2028, 0x2029].contains(text.character(at: NSMaxRange(range) - 1)) {
            range.length -= 1
        }
        return range
    }
}

/// The hint in an empty Try It box.
private struct NotebookTextRuleSamplePlaceholder: View {
    let sample: String

    var body: some View {
        if sample.isEmpty {
            Text("Type something the rule should find.")
                .foregroundStyle(.tertiary)
                #if os(iOS)
                .padding(EdgeInsets(top: 18, leading: 20, bottom: 0, trailing: 16))
                #else
                .padding(EdgeInsets(top: 20, leading: 27, bottom: 0, trailing: 16))
                #endif
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
