import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The two pens meh.md writes with, chosen under Settings > Appearance. Ink
/// colors checkboxes, links and buttons. The highlighter marks highlights and
/// the few things you act on, like the new-note button.
struct MehPalette: Equatable, Sendable {
    enum Ink: String, CaseIterable, Sendable {
        case black, blue, green
    }

    enum Highlighter: String, CaseIterable, Sendable {
        case yellow, pink, green, blue
    }

    static let inkKey = "appearance.ink"
    static let highlighterKey = "appearance.highlighter"

    var ink: Ink = .black
    var highlighter: Highlighter = .yellow
}

/// The app icon's colors for drawing code that cannot read the asset catalog
/// or the SwiftUI environment. SwiftUI views read `\.mehPalette` instead, so
/// they update when the palette changes.
enum MehStyle {
    /// The palette the editor draws with. The editor sets it from its
    /// `palette` before it styles text.
    static var palette = MehPalette()

    static var ink: PlatformColor { palette.ink.platformColor }
    /// Marks drawn on top of ink, such as a checkbox's checkmark.
    static var onInk: PlatformColor { palette.ink.onPlatformColor }
    /// The marker behind `==highlights==`.
    static var highlighter: PlatformColor { palette.highlighter.markPlatformColor }
    /// A stronger stroke of the same marker for the spot a link or search
    /// result jumps to.
    static var destinationHighlighter: PlatformColor {
        palette.highlighter.destinationPlatformColor
    }
    /// A deeper stroke of the marker for lines such as link underlines and
    /// the quote bar, so they still stand out on light paper.
    static var highlighterStroke: PlatformColor { palette.highlighter.strokePlatformColor }

    /// The page behind notes: a light paper gray, or a slightly lifted black.
    static let paper = dynamic(
        light: (0.969, 0.965, 0.953, 1), dark: (0.09, 0.09, 0.086, 1)
    )
    /// Glyphs on a solid highlighter, which stays light in both modes.
    static let onHighlighter = dynamic(
        light: (0.11, 0.11, 0.12, 1), dark: (0.11, 0.11, 0.12, 1)
    )

    #if os(macOS)
    static let paperColor = Color(nsColor: paper)
    static let onHighlighterColor = Color(nsColor: onHighlighter)
    #else
    static let paperColor = Color(uiColor: paper)
    static let onHighlighterColor = Color(uiColor: onHighlighter)
    #endif

    typealias Components = (CGFloat, CGFloat, CGFloat, CGFloat)

    #if os(macOS)
    static func dynamic(light: Components, dark: Components) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: c.3)
        }
    }
    #else
    static func dynamic(light: Components, dark: Components) -> UIColor {
        UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: c.3)
        }
    }
    #endif
}

extension MehPalette.Ink {
    private static let blackInk = MehStyle.dynamic(
        light: (0.11, 0.11, 0.12, 1), dark: (0.93, 0.93, 0.92, 1)
    )
    private static let blueInk = MehStyle.dynamic(
        light: (0.14, 0.26, 0.69, 1), dark: (0.36, 0.48, 0.92, 1)
    )
    private static let greenInk = MehStyle.dynamic(
        light: (0.12, 0.48, 0.28, 1), dark: (0.25, 0.63, 0.40, 1)
    )
    private static let onBlackInk = MehStyle.dynamic(
        light: (1, 1, 1, 1), dark: (0, 0, 0, 1)
    )
    private static let onColoredInk = MehStyle.dynamic(
        light: (1, 1, 1, 1), dark: (1, 1, 1, 1)
    )

    var platformColor: PlatformColor {
        switch self {
        case .black: Self.blackInk
        case .blue: Self.blueInk
        case .green: Self.greenInk
        }
    }

    var onPlatformColor: PlatformColor {
        self == .black ? Self.onBlackInk : Self.onColoredInk
    }

    var name: LocalizedStringResource {
        switch self {
        case .black: "Black"
        case .blue: "Royal Blue"
        case .green: "Forest Green"
        }
    }
}

extension MehPalette.Highlighter {
    private typealias Pair = (light: MehStyle.Components, dark: MehStyle.Components)

    private var components: Pair {
        switch self {
        case .yellow: ((1, 0.84, 0.2, 1), (0.89, 0.74, 0.13, 1))
        case .pink: ((1, 0.56, 0.76, 1), (0.88, 0.42, 0.62, 1))
        case .green: ((0.56, 0.88, 0.42, 1), (0.42, 0.74, 0.32, 1))
        case .blue: ((0.46, 0.78, 1, 1), (0.32, 0.62, 0.9, 1))
        }
    }

    private static let solid = Dictionary(uniqueKeysWithValues: allCases.map {
        ($0, MehStyle.dynamic(light: $0.components.light, dark: $0.components.dark))
    })
    /// Light mode needs a darker line than the fill: a thin stroke of pale
    /// yellow on paper is hard to see. Dark mode keeps the fill color.
    private var lightStroke: MehStyle.Components {
        switch self {
        case .yellow: (0.93, 0.65, 0, 1)
        case .pink: (0.89, 0.3, 0.55, 1)
        case .green: (0.3, 0.62, 0.2, 1)
        case .blue: (0.2, 0.52, 0.9, 1)
        }
    }

    private static let stroke = Dictionary(uniqueKeysWithValues: allCases.map {
        ($0, MehStyle.dynamic(light: $0.lightStroke, dark: $0.components.dark))
    })
    private static let mark = Dictionary(uniqueKeysWithValues: allCases.map {
        ($0, $0.withAlpha(light: 0.5, dark: 0.5))
    })
    private static let destination = Dictionary(uniqueKeysWithValues: allCases.map {
        ($0, $0.withAlpha(light: 0.75, dark: 0.45))
    })

    private func withAlpha(light: CGFloat, dark: CGFloat) -> PlatformColor {
        let c = components
        return MehStyle.dynamic(
            light: (c.light.0, c.light.1, c.light.2, light),
            dark: (c.dark.0, c.dark.1, c.dark.2, dark)
        )
    }

    var platformColor: PlatformColor { Self.solid[self]! }
    var strokePlatformColor: PlatformColor { Self.stroke[self]! }
    var markPlatformColor: PlatformColor { Self.mark[self]! }
    var destinationPlatformColor: PlatformColor { Self.destination[self]! }

    var name: LocalizedStringResource {
        switch self {
        case .yellow: "Yellow"
        case .pink: "Pink"
        case .green: "Green"
        case .blue: "Blue"
        }
    }
}

extension MehPalette {
    #if os(macOS)
    var inkColor: Color { Color(nsColor: ink.platformColor) }
    var onInkColor: Color { Color(nsColor: ink.onPlatformColor) }
    var highlighterColor: Color { Color(nsColor: highlighter.platformColor) }
    var strokeColor: Color { Color(nsColor: highlighter.strokePlatformColor) }
    var markColor: Color { Color(nsColor: highlighter.markPlatformColor) }
    #else
    var inkColor: Color { Color(uiColor: ink.platformColor) }
    var onInkColor: Color { Color(uiColor: ink.onPlatformColor) }
    var highlighterColor: Color { Color(uiColor: highlighter.platformColor) }
    var strokeColor: Color { Color(uiColor: highlighter.strokePlatformColor) }
    var markColor: Color { Color(uiColor: highlighter.markPlatformColor) }
    #endif

    /// The tint for system controls. Black ink keeps the `AccentColor`
    /// asset, which is a mid gray in dark mode: system controls put white
    /// glyphs on the accent, which would vanish on near-white ink. The other
    /// inks are dark enough for white glyphs in both modes.
    var accentColor: Color? { ink == .black ? nil : inkColor }
}

extension EnvironmentValues {
    @Entry var mehPalette = MehPalette()
}

/// Reads the chosen palette and hands it to every view below, including the
/// tint for system controls.
struct MehAppearance: ViewModifier {
    @AppStorage(MehPalette.inkKey, store: NotebookEditorPreferences.store)
    private var ink = MehPalette.Ink.black
    @AppStorage(MehPalette.highlighterKey, store: NotebookEditorPreferences.store)
    private var highlighter = MehPalette.Highlighter.yellow

    func body(content: Content) -> some View {
        let palette = MehPalette(ink: ink, highlighter: highlighter)
        content
            .environment(\.mehPalette, palette)
            .tint(palette.accentColor)
    }
}

extension View {
    func mehAppearance() -> some View { modifier(MehAppearance()) }
}
