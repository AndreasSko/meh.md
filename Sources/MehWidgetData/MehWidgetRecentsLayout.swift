import Foundation

/// How many notes a Recents widget shows, and how tall its rows are.
/// People pick a number of notes in Edit Widget. Each size shows at most
/// what still reads well, fewer when rows carry a preview line, and fewer
/// again when a large text size leaves no room.
public enum MehWidgetRecentsLayout {
    public enum Size: Sendable {
        case small, medium, large, extraLarge
    }

    public struct Plan: Equatable, Sendable {
        public let count: Int
        /// Smaller text, so more rows fit.
        public let isCompact: Bool
        public let rowHeight: Double
    }

    /// The most notes a size shows. Edit Widget offers the same choices for
    /// every size, so a small widget set to 12 shows 5.
    public static func limit(count: Int, previews: Bool, size: Size) -> Int {
        let most = switch (size, previews) {
        case (.small, false): 5
        case (.medium, false): 6
        case (.small, true), (.medium, true): 3
        case (.large, true), (.extraLarge, true): 8
        case (.large, false), (.extraLarge, false): 12
        }
        return min(max(count, 1), most)
    }

    /// Picks the text size and row height for up to `limit` notes. The rows
    /// share the widget's height. They use the regular text while it fits
    /// and the compact text after that. When neither fits, the plan drops
    /// notes.
    ///
    /// - Parameters:
    ///   - height: the height of the widget's content.
    ///   - regularText, compactText: the height of one row's text at the
    ///     current text size.
    public static func plan(
        limit: Int, columns: Int, height: Double,
        regularText: Double, compactText: Double
    ) -> Plan {
        let columns = max(columns, 1)
        for count in stride(from: max(limit, 1), to: 0, by: -1) {
            let perColumn = (count + columns - 1) / columns
            let room = height / Double(perColumn)
            if room >= regularText + 6 {
                return Plan(count: count, isCompact: false, rowHeight: room)
            }
            if room >= compactText + 4 {
                return Plan(count: count, isCompact: true, rowHeight: room)
            }
        }
        return Plan(count: 1, isCompact: true, rowHeight: height)
    }

    /// How many rows, counted from the bottom of a column, have text under
    /// the new note button in the bottom-right corner.
    ///
    /// - Parameters:
    ///   - gap: the empty space between the last row and the bottom.
    ///   - buttonTop: how far the button reaches up from the bottom.
    public static func rowsUnderButton(
        rows: Int, rowHeight: Double, text: Double, gap: Double,
        buttonTop: Double
    ) -> Int {
        (0..<max(rows, 0)).prefix { index in
            let center = gap + (Double(index) + 0.5) * rowHeight
            return center - text / 2 < buttonTop
        }.count
    }
}
