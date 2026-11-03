import MehWidgetData
import SwiftUI

/// The app's paper and pens, in the colors `MehStyle` uses. The widget
/// can't link the app's style code, so the few values it needs live here.
struct NotesWidgetPens {
    let paper: Color
    let card: Color
    let ink: Color
    let highlighter: Color
    let stroke: Color
    let mark: Color
    let onHighlighter = Color(red: 0.11, green: 0.11, blue: 0.12)

    init(snapshot: MehWidgetSnapshot?, colorScheme: ColorScheme) {
        let dark = colorScheme == .dark
        paper = dark
            ? Color(red: 0.09, green: 0.09, blue: 0.086)
            : Color(red: 0.969, green: 0.965, blue: 0.953)
        // The Recents card's system color: a lighter sheet on the paper.
        card = dark ? Color(red: 0.11, green: 0.11, blue: 0.118) : .white
        ink = switch (snapshot?.ink, dark) {
        case ("blue", false): Color(red: 0.14, green: 0.26, blue: 0.69)
        case ("blue", true): Color(red: 0.36, green: 0.48, blue: 0.92)
        case ("green", false): Color(red: 0.12, green: 0.48, blue: 0.28)
        case ("green", true): Color(red: 0.25, green: 0.63, blue: 0.40)
        case (_, false): Color(red: 0.11, green: 0.11, blue: 0.12)
        case (_, true): Color(red: 0.93, green: 0.93, blue: 0.92)
        }
        let solid: (Double, Double, Double)
        let lightStroke: (Double, Double, Double)
        switch snapshot?.highlighter {
        case "pink":
            solid = dark ? (0.88, 0.42, 0.62) : (1, 0.56, 0.76)
            lightStroke = (0.89, 0.3, 0.55)
        case "green":
            solid = dark ? (0.42, 0.74, 0.32) : (0.56, 0.88, 0.42)
            lightStroke = (0.3, 0.62, 0.2)
        case "blue":
            solid = dark ? (0.32, 0.62, 0.9) : (0.46, 0.78, 1)
            lightStroke = (0.2, 0.52, 0.9)
        default:
            solid = dark ? (0.89, 0.74, 0.13) : (1, 0.84, 0.2)
            lightStroke = (0.93, 0.65, 0)
        }
        highlighter = Color(red: solid.0, green: solid.1, blue: solid.2)
        mark = highlighter.opacity(0.5)
        let line = dark ? solid : lightStroke
        stroke = Color(red: line.0, green: line.1, blue: line.2)
    }

    /// One line of note text with its emphasis, highlights and links drawn
    /// like Live Preview. Nothing in it is tappable on its own.
    func inline(_ text: String) -> AttributedString {
        var result = AttributedString()
        for span in MehWidgetMarkdown.spans(in: text) {
            switch span {
            case .text(let source):
                var part = (try? AttributedString(
                    markdown: source,
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                )) ?? AttributedString(source)
                for run in part.runs where run.link != nil {
                    part[run.range].link = nil
                    part[run.range].underlineStyle = Text.LineStyle(color: stroke)
                }
                result += part
            case .highlight(let source):
                var part = AttributedString(source)
                part.backgroundColor = mark
                result += part
            case .link(let source):
                var part = AttributedString(source)
                part.underlineStyle = Text.LineStyle(color: stroke)
                result += part
            }
        }
        return result
    }
}

extension EnvironmentValues {
    @Entry var notesWidgetPens = NotesWidgetPens(snapshot: nil, colorScheme: .light)
}
