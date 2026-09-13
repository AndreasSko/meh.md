import SwiftUI

struct EditorTextSizeControl: View {
    @Binding var fontSize: Double

    private var displayedSize: Double {
        Double(MarkdownPresentation.normalizedFontSize(fontSize))
    }

    private var sliderValue: Binding<Double> {
        Binding(get: { displayedSize }, set: { fontSize = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Text size").font(.headline)
                Spacer()
                Text("\(Int(displayedSize)) pt")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button {
                    fontSize = max(12, displayedSize - 1)
                } label: {
                    Image(systemName: "textformat.size.smaller")
                }
                .accessibilityLabel("Decrease text size")
                .disabled(displayedSize <= 12)
                Slider(value: sliderValue, in: 12...28, step: 1) {
                    Text("Text size")
                }
                .labelsHidden()
                .accessibilityIdentifier("editor-font-size")
                .accessibilityValue("\(Int(displayedSize)) points")
                Button {
                    fontSize = min(28, displayedSize + 1)
                } label: {
                    Image(systemName: "textformat.size.larger")
                }
                .accessibilityLabel("Increase text size")
                .disabled(displayedSize >= 28)
            }
            Button("Reset to Default") { fontSize = 17 }
                .disabled(displayedSize == 17)
        }
        .padding(16)
        .frame(width: 260)
    }
}
