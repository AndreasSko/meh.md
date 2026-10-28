import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// How long a line of note text may get on wide screens. Very long lines are
/// hard to read, so wider editors center the text and grow their margins.
enum EditorLineWidth: String, CaseIterable, Identifiable {
    case standard
    case wide
    case full

    static let key = "editor.lineWidth"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: "Standard"
        case .wide: "Wide"
        case .full: "Full"
        }
    }

    private var characters: CGFloat? {
        switch self {
        case .standard: 72
        case .wide: 100
        case .full: nil
        }
    }

    /// Measured in the body font, so the limit follows font and text size.
    func maxTextWidth(fontSize: Double, fontFamily: EditorFontFamily) -> CGFloat? {
        guard let characters else { return nil }
        let font = MarkdownPresentation.bodyFont(
            for: fontFamily,
            pointSize: MarkdownPresentation.normalizedFontSize(fontSize)
        )
        let alphabet = "abcdefghijklmnopqrstuvwxyz" as NSString
        let average = alphabet.size(withAttributes: [.font: font]).width / 26
        return (characters * average).rounded()
    }
}

enum EditorTextMargin {
    #if os(macOS)
    static let compact: CGFloat = 26
    #else
    static let compact: CGFloat = 20
    #endif
    static let regular: CGFloat = 32

    /// The space from the editor's edge to the text on each side. Compact
    /// widths keep fixed margins and ignore the line width setting.
    static func horizontal(width: CGFloat, maxTextWidth: CGFloat?,
                           isCompact: Bool) -> CGFloat {
        guard !isCompact else { return compact }
        let minimum = width < 500 ? compact : regular
        guard let maxTextWidth else { return minimum }
        return max(minimum, ((width - maxTextWidth) / 2).rounded(.down))
    }
}
