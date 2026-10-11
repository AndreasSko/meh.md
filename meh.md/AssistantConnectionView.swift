#if CHATGPT_POC && os(iOS)
import AssistantCore
import SwiftUI

struct AssistantConnectionView: View {
    @Bindable var assistant: AssistantController

    var body: some View {
        Form {
            Section {
                Label("Private preview", systemImage: "flask")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                Text(assistant.account == nil
                    ? "Connect your ChatGPT account to use its available models in meh.md."
                    : "Use models from your ChatGPT account in meh.md.")

                Text("ChatGPT usage comes from your plan allowance. OpenAI limits may apply.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("ChatGPT account") {
                if let account = assistant.account {
                    LabeledContent("Connected", value: account.displayName)
                    if let email = account.email, !email.isEmpty {
                        LabeledContent("Email", value: email)
                    }
                    Button("Disconnect", role: .destructive) {
                        assistant.disconnect()
                    }
                    .accessibilityIdentifier("assistant-disconnect")
                } else {
                    Button(action: assistant.connect) {
                        HStack(spacing: 12) {
                            if assistant.isConnecting {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "sparkle")
                            }
                            Text(assistant.isConnecting
                                ? "Connecting…"
                                : "Continue with ChatGPT")
                                .fontWeight(.semibold)
                            Spacer(minLength: 0)
                            if !assistant.isConnecting {
                                Image(systemName: "arrow.up.right")
                                    .font(.footnote.weight(.semibold))
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(assistant.isConnecting)
                    .accessibilityIdentifier("assistant-connect")
                    if assistant.isConnecting {
                        Button("Cancel", action: assistant.cancelSignIn)
                            .accessibilityIdentifier("assistant-cancel-connect")
                    }
                }

                if let errorMessage = assistant.errorMessage {
                    AssistantConnectionError(
                        message: errorMessage,
                        onDismiss: assistant.clearError
                    )
                }
                if assistant.account != nil, assistant.models.isEmpty {
                    Button("Retry Models", action: assistant.retryModels)
                        .accessibilityIdentifier("assistant-retry-models")
                }
            }

            if assistant.account != nil {
                Section("Default model") {
                    if assistant.models.isEmpty {
                        Text("No models are available yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("New chats use", selection: Binding(
                            get: {
                                assistant.defaultModelID ?? assistant.models.first?.id ?? ""
                            },
                            set: { assistant.setDefaultModel($0) }
                        )) {
                            ForEach(assistant.models, id: \.id) { model in
                                Text(model.displayName).tag(model.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("assistant-default-model-picker")
                        .accessibilityValue(assistant.defaultModelName ?? "No model selected")
                    }
                }
            }

            Section {
                Text("Chat messages and any note content the assistant reads are "
                    + "sent to OpenAI to generate responses.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Your data")
            }

            Section("Preview limitation") {
                Text("Safari may show a connection warning after login when returning to this app through its local callback.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("ChatGPT")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("assistant-connection")
    }
}

private struct AssistantConnectionError: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            Button("Dismiss", systemImage: "xmark", action: onDismiss)
                .labelStyle(.iconOnly)
                .accessibilityLabel("Dismiss error")
        }
    }
}
#endif
