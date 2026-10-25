import Foundation

/// The lines a historical text changed compared with an earlier text. History
/// marks them in the margin. Ranges and locations are UTF-16, like the
/// editor's, and refer to the newer text.
public struct NoteHistoryChanges: Equatable, Sendable {
    public struct Removal: Equatable, Sendable {
        /// The start of the line that now follows the removed lines, or the
        /// end of the text.
        public let location: Int
        public let text: String
    }

    /// Runs of added or edited lines, each without its final line break.
    /// An added blank line has an empty range.
    public let changed: [NSRange]
    /// Lines removed without as many lines written in their place.
    public let removed: [Removal]

    public static let none = NoteHistoryChanges(changed: [], removed: [])

    public var isEmpty: Bool { changed.isEmpty && removed.isEmpty }

    init(changed: [NSRange], removed: [Removal]) {
        self.changed = changed
        self.removed = removed
    }

    /// Above this many line pairs in the differing middle, a full diff could
    /// stall the preview. Such rewrites mark every middle line as changed.
    static let diffComparisonLimit = 4_000_000

    public init(from old: String, to new: String) {
        let oldLines = Self.lines(of: old)
        let newLines = Self.lines(of: new)
        var newStarts: [Int] = []
        newStarts.reserveCapacity(newLines.count + 1)
        var offset = 0
        for line in newLines {
            newStarts.append(offset)
            offset += line.utf16.count + 1
        }
        newStarts.append(new.utf16.count)

        // Most edits touch a few lines. Trimming the shared start and end
        // keeps the diff to the lines that actually differ.
        var prefix = 0
        while prefix < oldLines.count, prefix < newLines.count,
              oldLines[prefix] == newLines[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < oldLines.count - prefix,
              suffix < newLines.count - prefix,
              oldLines[oldLines.count - 1 - suffix]
                == newLines[newLines.count - 1 - suffix] {
            suffix += 1
        }
        let oldMiddle = oldLines[prefix ..< oldLines.count - suffix]
        let newMiddle = newLines[prefix ..< newLines.count - suffix]

        var removedLines = Set<Int>()
        var insertedLines = Set<Int>()
        if oldMiddle.isEmpty {
            insertedLines = Set(newMiddle.indices)
        } else if newMiddle.isEmpty {
            removedLines = Set(oldMiddle.indices)
        } else if oldMiddle.count * newMiddle.count > Self.diffComparisonLimit {
            removedLines = Set(oldMiddle.indices)
            insertedLines = Set(newMiddle.indices)
        } else {
            for change in Array(newMiddle).difference(from: Array(oldMiddle)) {
                switch change {
                case let .remove(index, _, _):
                    removedLines.insert(prefix + index)
                case let .insert(index, _, _):
                    insertedLines.insert(prefix + index)
                }
            }
        }

        var changed: [NSRange] = []
        var removed: [Removal] = []
        var oldIndex = prefix
        var newIndex = prefix
        let oldEnd = oldLines.count - suffix
        let newEnd = newLines.count - suffix
        while oldIndex < oldEnd || newIndex < newEnd {
            // A block is a run of removed and inserted lines between two
            // lines both texts share.
            let oldFirst = oldIndex
            let newFirst = newIndex
            while true {
                if oldIndex < oldEnd, removedLines.contains(oldIndex) {
                    oldIndex += 1
                } else if newIndex < newEnd, insertedLines.contains(newIndex) {
                    newIndex += 1
                } else {
                    break
                }
            }
            if oldIndex == oldFirst, newIndex == newFirst {
                oldIndex += 1
                newIndex += 1
                continue
            }
            if newIndex > newFirst {
                let last = newIndex - 1
                let end = newStarts[last] + newLines[last].utf16.count
                changed.append(NSRange(
                    location: newStarts[newFirst],
                    length: end - newStarts[newFirst]
                ))
            }
            // New lines in place of old ones are an edit; the changed mark
            // covers it. Only when lines went missing does the old text need
            // a ring of its own.
            if oldIndex - oldFirst > newIndex - newFirst {
                removed.append(Removal(
                    location: newStarts[newIndex],
                    text: oldLines[oldFirst ..< oldIndex].joined(separator: "\n")
                ))
            }
        }
        self.init(changed: changed, removed: removed)
    }

    /// Lines split at line feeds. A line before a CRLF break keeps its
    /// carriage return, so ranges and offsets still add up.
    private static func lines(of text: String) -> [Substring] {
        text.unicodeScalars
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(Substring.init)
    }
}
