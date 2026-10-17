import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The app icon's colors for drawing code that cannot read the asset catalog.
/// SwiftUI's `AccentColor` uses the same ink in light mode, but a mid gray in
/// dark mode: system controls put white glyphs on the accent, which would
/// vanish on near-white ink.
enum MehStyle {
    /// Near-black in light mode and near-white in dark mode, like the icon's
    /// lettering.
    static let ink = dynamic(
        light: (0.11, 0.11, 0.12, 1), dark: (0.93, 0.93, 0.92, 1)
    )
    /// Marks drawn on top of ink, such as a checkbox's checkmark.
    static let onInk = dynamic(light: (1, 1, 1, 1), dark: (0, 0, 0, 1))
    /// The page behind notes: a light paper gray, or a slightly lifted black.
    static let paper = dynamic(
        light: (0.969, 0.965, 0.953, 1), dark: (0.09, 0.09, 0.086, 1)
    )
    /// Marker yellow for `==highlights==`.
    static let highlighter = dynamic(
        light: (1, 0.85, 0.16, 0.5), dark: (1, 0.82, 0.1, 0.5)
    )
    /// A stronger stroke of the same marker for the spot a link or search
    /// result jumps to.
    static let destinationHighlighter = dynamic(
        light: (1, 0.85, 0.16, 0.75), dark: (1, 0.82, 0.1, 0.45)
    )

    #if os(macOS)
    static let inkColor = Color(nsColor: ink)
    static let onInkColor = Color(nsColor: onInk)
    static let paperColor = Color(nsColor: paper)
    #else
    static let inkColor = Color(uiColor: ink)
    static let onInkColor = Color(uiColor: onInk)
    static let paperColor = Color(uiColor: paper)
    #endif

    private typealias Components = (CGFloat, CGFloat, CGFloat, CGFloat)

    #if os(macOS)
    private static func dynamic(light: Components, dark: Components) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: c.3)
        }
    }
    #else
    private static func dynamic(light: Components, dark: Components) -> UIColor {
        UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: c.3)
        }
    }
    #endif
}
