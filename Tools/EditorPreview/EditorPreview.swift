import SwiftUI

/// A disposable harness without notebook, persistence, or network integration.
@main
struct EditorPreviewApp: App {
    var body: some Scene {
        Window("Markdown appearance preview", id: "editor-preview") {
            EditorPreviewView()
        }
        .defaultSize(width: 980, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

private struct EditorPreviewView: View {
    private static let sample: String = {
        guard let url = Bundle.main.url(
            forResource: "editor-showcase", withExtension: "md"
        ), let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "# Sample unavailable\nRebuild the editor preview."
        }
        return text
    }()

    @State private var text = Self.sample
    @State private var appearance = PreviewAppearance.system
    @State private var narrowColumn = false
    @State private var fontSize = 17.0
    @State private var showingTextSize = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Markdown appearance").font(.headline)
                    Text("Source visible · Fictional sample · Edits are temporary")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Narrow", isOn: $narrowColumn)
                    .toggleStyle(.button)
                Picker("Appearance", selection: $appearance) {
                    ForEach(PreviewAppearance.allCases) { value in
                        Text(value.rawValue).tag(value)
                    }
                }
                .labelsHidden()
                .frame(width: 110)
                Button("Reset Sample") { text = Self.sample }
                Button {
                    showingTextSize = true
                } label: {
                    Label("Editor Options", systemImage: "ellipsis.circle")
                }
                .labelStyle(.iconOnly)
                .accessibilityIdentifier("editor-options")
                .popover(isPresented: $showingTextSize) {
                    EditorTextSizeControl(fontSize: $fontSize)
                }
            }
            .padding(16)
            Divider()
            MarkdownEditor(text: $text, fontSize: fontSize)
                .accessibilityIdentifier("editor-appearance-preview")
                .frame(maxWidth: narrowColumn ? 440 : .infinity)
                .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 420, minHeight: 420)
        .preferredColorScheme(appearance.colorScheme)
    }
}

private enum PreviewAppearance: String, CaseIterable, Identifiable {
    case system = "System", light = "Light", dark = "Dark"

    var id: String { rawValue }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
