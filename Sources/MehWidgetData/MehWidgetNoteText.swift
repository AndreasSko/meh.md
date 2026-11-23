import Foundation

/// The text sizes of a One Note widget, in points at the default system
/// text size. Small is not listed: it keeps the caption text the widget
/// used before, which follows the system text size on its own.
public enum MehWidgetNoteText {
    public static let medium = 15.0
    public static let large = 20.0

    /// The sizes Auto tries, largest first. It shows the note at the first
    /// size where all of it fits. After these it tries Small, and only cuts
    /// the note off when even Small doesn't fit it.
    public static func autoSizes(for size: MehWidgetRecentsLayout.Size) -> [Double] {
        let most: Double = switch size {
        case .small: 18
        case .medium: 22
        case .large, .extraLarge: 28
        }
        return steps.filter { $0 <= most }
    }

    /// Auto lays out the whole note at each size, so it skips that for
    /// notes longer than this and cuts them off in Small right away.
    public static let autoMostBlocks = 40

    /// How many blocks go into the first of two columns. The columns get
    /// about the same amount of text, so one long paragraph doesn't make
    /// one column much taller than the other.
    ///
    /// - Parameter lengths: the number of characters in each block.
    public static func firstColumnCount(lengths: [Int]) -> Int {
        guard lengths.count > 1 else { return lengths.count }
        // Each block also takes the space of a short line around it.
        let weights = lengths.map { $0 + 30 }
        let total = weights.reduce(0, +)
        var best = 1
        var bestDifference = Int.max
        var first = 0
        for count in 1 ..< weights.count {
            first += weights[count - 1]
            let difference = abs(first - (total - first))
            if difference <= bestDifference {
                best = count
                bestDifference = difference
            }
        }
        return best
    }

    private static let steps: [Double] = [28, 25, 22, 20, 18, 17, 16, 15, 14, 13, 12]
}
