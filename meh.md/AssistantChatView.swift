#if CHATGPT_POC && os(iOS)
import AssistantCore
import SwiftUI

struct AssistantChatView: View {
    @Bindable var assistant: AssistantController
    let openNote: (AssistantNoteReference) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var composerFocused: Bool
    @State private var showingHistory = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let errorMessage = assistant.errorMessage {
                    AssistantChatErrorBanner(
                        message: errorMessage,
                        onDismiss: assistant.clearError
                    )
                }
                if assistant.account != nil, assistant.models.isEmpty {
                    Button("Retry Models", action: assistant.retryModels)
                        .accessibilityIdentifier("assistant-retry-models")
                        .padding(.vertical, 8)
                }

                if assistant.messages.isEmpty {
                    AssistantChatEmptyState(isConnected: assistant.account != nil)
                } else {
                    AssistantMessageList(
                        messages: assistant.messages,
                        isSending: assistant.isSending,
                        openNote: openNote
                    )
                }

                AssistantChatComposer(
                    assistant: assistant, isFocused: $composerFocused
                )
            }
            .navigationTitle("ChatGPT")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", systemImage: "xmark") {
                        composerFocused = false
                        dismiss()
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("assistant-chat-close")
                }
                ToolbarItem(placement: .principal) {
                    AssistantModelMenu(assistant: assistant)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        Button("Chat History", systemImage: "clock.arrow.circlepath") {
                            composerFocused = false
                            showingHistory = true
                        }
                        .labelStyle(.iconOnly)
                        .accessibilityIdentifier("assistant-chat-history")
                        Button("New Chat", systemImage: "square.and.pencil") {
                            composerFocused = false
                            assistant.newThread()
                        }
                        .labelStyle(.iconOnly)
                        .accessibilityLabel("New Chat")
                        .accessibilityIdentifier("assistant-new-chat")
                    }
                }
            }
            .sheet(isPresented: $showingHistory) {
                AssistantThreadHistoryView(assistant: assistant) { threadID in
                    assistant.selectThread(threadID)
                    showingHistory = false
                }
                .presentationDetents([.medium, .large])
            }
        }
        .accessibilityIdentifier("assistant-chat")
    }
}

private struct AssistantModelMenu: View {
    @Bindable var assistant: AssistantController

    private var selectedModelName: String {
        guard let selectedModelID = assistant.selectedModelID else {
            return "Choose Model"
        }
        return assistant.models.first(where: { $0.id == selectedModelID })?
            .displayName ?? "Choose Model"
    }

    var body: some View {
        Menu {
            Section("This chat") {
                ForEach(assistant.models, id: \.id) { model in
                    Button {
                        assistant.selectedModelID = model.id
                    } label: {
                        if assistant.selectedModelID == model.id {
                            Label(model.displayName, systemImage: "checkmark")
                        } else {
                            Text(model.displayName)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selectedModelName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .contentShape(Rectangle())
            .frame(maxWidth: 150)
        }
        .accessibilityLabel("Model: \(selectedModelName)")
        .accessibilityIdentifier("assistant-model-picker")
        .disabled(assistant.models.isEmpty)
    }
}

private struct AssistantThreadHistoryView: View {
    @Bindable var assistant: AssistantController
    let selectThread: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(assistant.visibleThreads, id: \.id) { thread in
                Button {
                    selectThread(thread.id)
                } label: {
                    HStack {
                        Text(thread.title)
                            .foregroundStyle(.primary)
                        Spacer()
                        if thread.id == assistant.selectedThreadID {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .accessibilityLabel(thread.title)
            }
            .overlay {
                if assistant.visibleThreads.isEmpty {
                    ContentUnavailableView(
                        "No chats yet", systemImage: "clock.arrow.circlepath"
                    )
                }
            }
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .accessibilityIdentifier("assistant-thread-history")
    }
}

private struct AssistantChatEmptyState: View {
    let isConnected: Bool

    var body: some View {
        ContentUnavailableView {
            Label("Start a chat", systemImage: "sparkles")
        } description: {
            if isConnected {
                Text(
                    "Ask about this notebook or use keyboard dictation. The assistant "
                        + "can search, read, create, and update notes. Chat messages and "
                        + "note content it reads are sent to OpenAI.")
            } else {
                Text("Connect ChatGPT in Settings to start a chat.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct AssistantMessageList: View {
    let messages: [AssistantMessage]
    let isSending: Bool
    let openNote: (AssistantNoteReference) -> Void

    private var lastMessageID: UUID? { messages.last?.id }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(messages, id: \.id) { message in
                        AssistantMessageRow(
                            message: message,
                            isActiveReply: isSending && message.id == lastMessageID,
                            openNote: openNote
                        )
                        .id(message.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.immediately)
            .accessibilityIdentifier("assistant-message-list")
            .onChange(of: lastMessageID) { _, messageID in
                guard let messageID else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(messageID, anchor: .bottom)
                }
            }
        }
    }
}

private struct AssistantMessageRow: View {
    let message: AssistantMessage
    let isActiveReply: Bool
    let openNote: (AssistantNoteReference) -> Void

    private var isUser: Bool { message.role == .user }

    private struct NoteLink: Identifiable {
        let reference: AssistantNoteReference
        let callID: String
        var id: UUID { reference.noteID }
    }

    private var noteLinks: [NoteLink] {
        var seen = Set<UUID>()
        var links: [NoteLink] = []
        // The last tool result carries the most recent title for a note.
        for activity in message.toolActivities.reversed() {
            for reference in activity.noteReferences.reversed()
            where seen.insert(reference.noteID).inserted {
                links.append(NoteLink(reference: reference, callID: activity.callID))
            }
        }
        return Array(links.reversed())
    }

    private func activityDisplaySummary(_ activity: AssistantToolActivity) -> String {
        guard activity.phase == .started else { return activity.summary }
        switch activity.name {
        case "search_notes": return "Searching notes…"
        case "read_note": return "Reading note…"
        case "create_note": return "Creating note…"
        case "update_note": return "Updating note…"
        default: return "Working with your notebook…"
        }
    }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 40) }

            VStack(alignment: .leading, spacing: 6) {
                Group {
                    if let formatted = try? AttributedString(
                        markdown: message.text,
                        options: .init(
                            interpretedSyntax: .inlineOnlyPreservingWhitespace
                        )
                    ) {
                        Text(formatted)
                    } else {
                        Text(message.text)
                    }
                }
                .textSelection(.enabled)

                ForEach(message.toolActivities, id: \.callID) { activity in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            if activity.phase == .started {
                                ProgressView().controlSize(.mini)
                            } else if activity.phase == .failed {
                                Image(systemName: "exclamationmark.circle")
                                    .foregroundStyle(.red)
                            } else {
                                Image(systemName: "checkmark.circle")
                                    .foregroundStyle(.secondary)
                            }
                            Text(activityDisplaySummary(activity))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                ForEach(noteLinks) { link in
                    let reference = link.reference
                    Button {
                        openNote(reference)
                    } label: {
                        Label(reference.title, systemImage: "doc.text")
                            .font(.caption)
                            .lineLimit(1)
                            .frame(minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier(
                        "assistant-note-reference-\(link.callID)-\(reference.noteID.uuidString)"
                    )
                }

                if isActiveReply {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Thinking…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if message.status == .interrupted {
                    Text("Stopped")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if message.status == .failed {
                    Text("This reply could not be completed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                isUser ? Color.accentColor.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .frame(maxWidth: 560, alignment: isUser ? .trailing : .leading)

            if !isUser { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .accessibilityElement(children: .contain)
    }
}

private struct AssistantChatComposer: View {
    @Bindable var assistant: AssistantController
    var isFocused: FocusState<Bool>.Binding

    private var canSend: Bool {
        !assistant.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !assistant.isSending
            && !assistant.hasPendingToolOperation
            && assistant.account != nil
            && assistant.isNotebookBound
            && assistant.selectedModelID != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if assistant.hasPendingToolOperation, !assistant.isSending {
                HStack(spacing: 8) {
                    Text("Finishing note operation…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if assistant.canFinishFixtureOperation {
                        Button(
                            "Finish fixture operation",
                            action: assistant.finishFixtureOperation
                        )
                        .font(.caption)
                        .accessibilityIdentifier("assistant-fixture-finish-operation")
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message", text: $assistant.draft, axis: .vertical)
                    .focused(isFocused)
                    .lineLimit(1...5)
                    .textInputAutocapitalization(.sentences)
                    .submitLabel(.send)
                    .onSubmit {
                        if canSend { assistant.send() }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 22))
                    .accessibilityIdentifier("assistant-message-draft")

                if assistant.isSending {
                    Button("Stop", systemImage: "stop.fill", action: assistant.stop)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.bordered)
                        .tint(.secondary)
                        .accessibilityLabel("Stop response")
                        .accessibilityValue(
                            assistant.canFinishFixtureOperation
                                ? "Fixture write committed" : ""
                        )
                        .accessibilityIdentifier("assistant-stop")
                } else {
                    Button("Send", systemImage: "arrow.up", action: assistant.send)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.circle)
                        .foregroundStyle(canSend ? Color.white : Color.secondary)
                        .disabled(!canSend)
                        .accessibilityIdentifier("assistant-send")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.background)
    }
}

private struct AssistantChatErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            Button("Dismiss", systemImage: "xmark", action: onDismiss)
                .labelStyle(.iconOnly)
                .accessibilityLabel("Dismiss error")
        }
        .padding(12)
        .background(.red.opacity(0.08))
    }
}
#endif
