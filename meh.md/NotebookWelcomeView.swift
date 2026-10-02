import SwiftUI

struct NotebookWelcomeView: View {
    let usesSync: Bool
    let isReady: Bool
    let isLoading: Bool
    let failureMessage: String?
    let canRetry: Bool
    let choose: (NotebookWelcomeState.Choice) -> Void
    let skip: () -> Void
    let retry: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                NotebookWelcomeHeader()
                NotebookWelcomeFeatures(usesSync: usesSync)
                NotebookWelcomeActions(isReady: isReady, choose: choose)
                if !isReady {
                    NotebookWelcomeSetupStatus(
                        usesSync: usesSync, isLoading: isLoading,
                        failureMessage: failureMessage,
                        canRetry: canRetry, retry: retry
                    )
                }
                Button("Not now", action: skip)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
                    .accessibilityIdentifier("notebook-welcome-skip")
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 28)
            .frame(maxWidth: 440)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.top)
        .background(.background)
        .accessibilityIdentifier("notebook-welcome")
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 640)
        #endif
    }
}

private struct NotebookWelcomeHeader: View {
    var body: some View {
        VStack(spacing: 16) {
            Image("WelcomeSketch")
                .resizable()
                .scaledToFit()
                .frame(width: 240, height: 160)
                .accessibilityHidden(true)
            Text("Welcome to meh.md")
                .font(.largeTitle.weight(.bold))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text("Plain Markdown. A little less fuss.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

private struct NotebookWelcomeFeatures: View {
    let usesSync: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            NotebookWelcomeFeature(
                title: "Just Markdown", image: "doc.plaintext",
                detail: "Write with formatting. Keep the plain text."
            )
            if usesSync {
                NotebookWelcomeFeature(
                    title: "Saved here. Synced with iCloud.", image: "icloud",
                    detail: "After first setup, you can write offline."
                )
            } else {
                NotebookWelcomeFeature(
                    title: "Write offline", image: "internaldrive",
                    detail: "Your notebook is saved on this device."
                )
            }
            NotebookWelcomeFeature(
                title: "Yours to keep", image: "square.and.arrow.up",
                detail: "Import and export ordinary Markdown files."
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NotebookWelcomeFeature: View {
    let title: LocalizedStringResource
    let image: String
    let detail: LocalizedStringResource
    @ScaledMetric(relativeTo: .title3) private var symbolWidth: CGFloat = 26

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: image)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: symbolWidth)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct NotebookWelcomeActions: View {
    let isReady: Bool
    let choose: (NotebookWelcomeState.Choice) -> Void

    var body: some View {
        VStack(spacing: 12) {
            Button { choose(.newNote) } label: {
                Text("Start Writing")
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("notebook-welcome-write")
            Button { choose(.examples) } label: {
                Text("Explore Example Notes")
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("notebook-welcome-examples")
            Button { choose(.importNotes) } label: {
                Label("Import Markdown…", systemImage: "square.and.arrow.down")
                    .frame(minHeight: 36)
            }
            .accessibilityIdentifier("notebook-welcome-import")
        }
        .controlSize(.large)
        .disabled(!isReady)
    }
}

private struct NotebookWelcomeSetupStatus: View {
    let usesSync: Bool
    let isLoading: Bool
    let failureMessage: String?
    let canRetry: Bool
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            if let failureMessage {
                Text(failureMessage)
                    .foregroundStyle(.secondary)
                Button("Try Again", action: retry)
                    .disabled(!canRetry || isLoading)
                    .accessibilityIdentifier("notebook-welcome-retry")
            } else {
                ProgressView()
                if usesSync {
                    Text("Connecting to iCloud for the first time…")
                    Text("An iCloud account and a connection are needed for setup.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Opening your notebook…")
                }
            }
        }
        .font(.footnote)
        .multilineTextAlignment(.center)
        .accessibilityIdentifier("notebook-welcome-setup")
    }
}
