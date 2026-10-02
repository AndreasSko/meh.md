import Foundation

/// A native cell editor keeps its buffer in literal Markdown UTF-16 space.
enum MarkdownTableCellEditing {
    struct Target: Equatable {
        let tableRange: NSRange
        /// Header is zero; body rows start at one.
        let row: Int
        let column: Int
        let contentRange: NSRange
        let rowRange: NSRange
        fileprivate let insertionPrefix: String
    }

    static func target(text: String, selection: NSRange,
                       syntax: MarkdownSyntaxResult? = nil) -> Target? {
        let source = text as NSString
        guard valid(selection, length: source.length) else { return nil }
        for table in (syntax ?? MarkdownSyntax.parse(text)).tables {
            for (index, row) in ([table.header] + table.rows).enumerated() {
                guard selection.location >= row.range.location,
                      NSMaxRange(selection) <= contentEnd(row.range, source)
                else { continue }
                let column: Int
                if selection.length > 0 {
                    guard let found = row.cells.firstIndex(where: {
                        selection.location >= $0.location
                            && NSMaxRange(selection) <= NSMaxRange($0)
                    }) else { return nil }
                    column = found
                } else {
                    // Padding and separators belong to the preceding cell.
                    column = row.cells.indices.first(where: {
                        $0 == row.cells.count - 1
                            || selection.location < row.cells[$0 + 1].location
                    }) ?? 0
                }
                return target(text: text, table: table,
                              row: index, column: column)
            }
        }
        return nil
    }

    static func target(text: String, table: MarkdownTable,
                       row: Int, column: Int) -> Target? {
        let rows = [table.header] + table.rows
        let source = text as NSString
        guard rows.indices.contains(row),
              table.header.cells.indices.contains(column),
              valid(rows[row].range, length: source.length)
        else { return nil }
        let line = rows[row]
        if line.cells.indices.contains(column) {
            return Target(tableRange: table.range, row: row, column: column,
                          contentRange: line.cells[column], rowRange: line.range,
                          insertionPrefix: "")
        }
        var end = contentEnd(line.range, source)
        while end > line.range.location,
              [UInt16(32), 9].contains(source.character(at: end - 1)) {
            end -= 1
        }
        let finalPipe = end > line.range.location
            && source.character(at: end - 1) == 124
            && !escaped(end - 1, source)
        let prefix = String(repeating: " |", count: column - line.cells.count + 1)
            + " "
        return Target(tableRange: table.range, row: row, column: column,
                      contentRange: NSRange(location: finalPipe ? end - 1 : end,
                                            length: 0),
                      rowRange: line.range, insertionPrefix: prefix)
    }

    static func text(in text: String, target: Target) -> String {
        let source = text as NSString
        guard valid(target.contentRange, length: source.length) else { return "" }
        return source.substring(with: target.contentRange)
    }

    static func sourceSelection(_ local: NSRange, in target: Target) -> NSRange {
        let local = clamped(local, length: target.contentRange.length)
        return NSRange(location: target.contentRange.location + local.location,
                       length: local.length)
    }

    static func localSelection(_ source: NSRange, in target: Target) -> NSRange {
        let start = min(max(source.location, target.contentRange.location),
                        NSMaxRange(target.contentRange))
        let end = valid(source, length: Int.max)
            ? min(max(NSMaxRange(source), start), NSMaxRange(target.contentRange))
            : start
        return NSRange(location: start - target.contentRange.location,
                       length: end - start)
    }

    /// Retains whitespace typed in the active buffer while parser ranges trim it.
    static func retainingContentRange(_ range: NSRange, in target: Target,
                                     text: String) -> Target? {
        let source = text as NSString
        guard target.insertionPrefix.isEmpty,
              valid(range, length: source.length),
              let raw = rawCellRange(target, source: source),
              range.location >= raw.location,
              NSMaxRange(range) <= NSMaxRange(raw),
              target.contentRange.length == 0
                || range.location <= target.contentRange.location
                    && NSMaxRange(range) >= NSMaxRange(target.contentRange)
        else { return nil }
        return Target(tableRange: target.tableRange, row: target.row,
                      column: target.column, contentRange: range,
                      rowRange: target.rowRange, insertionPrefix: "")
    }

    /// `source` is the source after applying this local cell change.
    static func targetAfter(change: MarkdownEditingChange, priorTarget: Target,
                            source: String) -> Target? {
        guard let table = MarkdownSyntax.parse(source).tables.first(where: {
            $0.range.location == priorTarget.tableRange.location
        }), let target = self.target(text: source, table: table,
                                     row: priorTarget.row,
                                     column: priorTarget.column)
        else { return nil }
        let prefix = priorTarget.insertionPrefix.utf16.count
        let replacement = change.replacement as NSString
        // Preserve normalization padding in ordinary cells. A trailing space
        // after a backslash may also have been explicitly typed by the user.
        let suffix = prefix > 0 ? 1 : 0
        let length = replacement.length - prefix - suffix
        guard length >= 0 else { return nil }
        return retainingContentRange(
            NSRange(location: change.range.location + prefix, length: length),
            in: target, text: source
        )
    }

    /// Replaces the complete cell buffer while preserving surrounding bytes.
    /// Pasted line breaks become spaces; bare pipes become escaped pipes.
    static func change(text: String, target: Target, replacement: String,
                       selection: NSRange) -> MarkdownEditingChange? {
        let source = text as NSString
        guard valid(target.contentRange, length: source.length),
              let table = MarkdownSyntax.parse(text).tables.first(where: {
                  $0.range == target.tableRange
              }),
              let parsedTarget = self.target(text: text, table: table,
                                             row: target.row,
                                             column: target.column),
              parsedTarget == target || retainingContentRange(
                target.contentRange, in: parsedTarget, text: text
              ) == target else { return nil }
        let normalized = normalize(replacement, selection: selection)
        let prefix = target.insertionPrefix
        let end = NSMaxRange(target.contentRange)
        let normalizedSource = normalized.text as NSString
        let wouldEscapeSeparator = end < source.length
            && source.character(at: end) == 124
            && escaped(normalizedSource.length, normalizedSource)
        // Keep a final backslash from consuming an adjacent structural pipe.
        let suffix = !prefix.isEmpty || wouldEscapeSeparator ? " " : ""
        return MarkdownEditingChange(
            range: target.contentRange,
            replacement: prefix + normalized.text + suffix,
            selection: NSRange(location: target.contentRange.location
                                + prefix.utf16.count
                                + normalized.selection.location,
                               length: normalized.selection.length)
        )
    }

    /// Follows the active row through a UTF-16 source diff and reparses it.
    /// Structural edits touching the active row close the editor.
    static func rebased(_ target: Target, from oldText: String,
                        to newText: String) -> Target? {
        if oldText.utf8.elementsEqual(newText.utf8) { return target }
        let old = oldText as NSString
        let new = newText as NSString
        guard valid(target.rowRange, length: old.length) else { return nil }
        var prefix = 0
        while prefix < min(old.length, new.length),
              old.character(at: prefix) == new.character(at: prefix) {
            prefix += 1
        }
        var suffix = 0
        while suffix < min(old.length, new.length) - prefix,
              old.character(at: old.length - suffix - 1)
                == new.character(at: new.length - suffix - 1) {
            suffix += 1
        }
        let oldEnd = old.length - suffix
        let delta = new.length - old.length
        let cell = target.contentRange
        let withinContent = prefix >= cell.location && oldEnd <= NSMaxRange(cell)
        // A common-prefix/suffix diff can absorb unchanged cell padding when
        // an undo removes a suffix sharing spaces with that padding.
        let raw = rawCellRange(target, source: old)
        let withinCell = withinContent || raw.map {
            prefix >= $0.location && oldEnd <= NSMaxRange($0)
        } == true
        let beforeRow = !withinCell && oldEnd <= target.rowRange.location
        let afterRow = prefix >= NSMaxRange(target.rowRange)
        let beforeCell = oldEnd <= cell.location
        let afterCell = prefix >= NSMaxRange(cell)
        let elsewhereInRow = (beforeCell || afterCell)
            && prefix >= target.rowRange.location
            && oldEnd <= NSMaxRange(target.rowRange)
        guard withinCell || beforeRow || afterRow || elsewhereInRow
        else { return nil }
        let rowStart = target.rowRange.location + (beforeRow ? delta : 0)
        guard let oldTable = MarkdownSyntax.parse(oldText).tables.first(where: {
            $0.range == target.tableRange
        }), ([oldTable.header] + oldTable.rows).indices.contains(target.row)
        else { return nil }
        for table in MarkdownSyntax.parse(newText).tables {
            let rows = [table.header] + table.rows
            guard let row = rows.firstIndex(where: {
                $0.range.location == rowStart
            }) else { continue }
            guard table.header.cells.count == oldTable.header.cells.count,
                  rows[row].cells.count ==
                    ([oldTable.header] + oldTable.rows)[target.row].cells.count,
                  let next = self.target(text: newText, table: table,
                                         row: row, column: target.column)
            else { return nil }
            if withinCell && !target.insertionPrefix.isEmpty { return nil }
            if !target.insertionPrefix.isEmpty { return next }
            let mapped = NSRange(
                location: cell.location + (!withinCell && beforeCell ? delta : 0),
                length: max(0, cell.length + (withinCell ? delta : 0))
            )
            guard let retained = retainingContentRange(
                mapped, in: next, text: newText
            ) else {
                // If shared whitespace makes the retained edit boundaries
                // ambiguous, the parsed cell is still a safe active target.
                return withinCell && !withinContent ? next : nil
            }
            if elsewhereInRow && !withinCell,
               self.text(in: oldText, target: target)
                != self.text(in: newText, target: retained) { return nil }
            return retained
        }
        return nil
    }

    private static func normalize(_ text: String, selection: NSRange)
        -> (text: String, selection: NSRange) {
        let source = text as NSString
        let selection = clamped(selection, length: source.length)
        var output = ""
        var offsets = [Int](repeating: 0, count: source.length + 1)
        var index = 0
        var slashCount = 0
        while index < source.length {
            offsets[index] = output.utf16.count
            let value = source.character(at: index)
            if [UInt16(13), 10, 0x2028, 0x2029].contains(value) {
                output += " "
                if value == 13, index + 1 < source.length,
                   source.character(at: index + 1) == 10 {
                    index += 1
                    offsets[index] = output.utf16.count
                }
                slashCount = 0
            } else {
                if value == 124 && slashCount.isMultiple(of: 2) { output += "\\" }
                let count = (0xD800...0xDBFF).contains(value)
                    && index + 1 < source.length
                    && (0xDC00...0xDFFF).contains(source.character(at: index + 1))
                    ? 2 : 1
                output += source.substring(with: NSRange(location: index,
                                                        length: count))
                if count == 2 {
                    offsets[index + 1] = output.utf16.count - 1
                    index += 1
                }
                slashCount = value == 92 ? slashCount + 1 : 0
            }
            index += 1
        }
        offsets[source.length] = output.utf16.count
        let start = offsets[selection.location]
        return (output, NSRange(location: start,
                                length: offsets[NSMaxRange(selection)] - start))
    }

    private static func rawCellRange(_ target: Target, source: NSString)
        -> NSRange? {
        guard valid(target.rowRange, length: source.length) else { return nil }
        var start = target.rowRange.location
        var end = contentEnd(target.rowRange, source)
        while start < end,
              [UInt16(32), 9].contains(source.character(at: start)) { start += 1 }
        while end > start,
              [UInt16(32), 9].contains(source.character(at: end - 1)) { end -= 1 }
        var separators = (start..<end).filter {
            source.character(at: $0) == 124 && !escaped($0, source)
        }
        if separators.first == start {
            start += 1
            separators.removeFirst()
        } else {
            start = target.rowRange.location
        }
        if separators.last == end - 1 {
            end -= 1
            separators.removeLast()
        } else {
            end = contentEnd(target.rowRange, source)
        }
        let boundaries = separators + [end]
        guard boundaries.indices.contains(target.column) else { return nil }
        let left = target.column == 0 ? start : boundaries[target.column - 1] + 1
        return NSRange(location: left, length: boundaries[target.column] - left)
    }

    private static func contentEnd(_ range: NSRange, _ source: NSString) -> Int {
        var end = NSMaxRange(range)
        while end > range.location,
              [UInt16(10), 13].contains(source.character(at: end - 1)) { end -= 1 }
        return end
    }

    private static func escaped(_ location: Int, _ source: NSString) -> Bool {
        var count = 0
        var position = location
        while position > 0, source.character(at: position - 1) == 92 {
            count += 1
            position -= 1
        }
        return !count.isMultiple(of: 2)
    }

    private static func valid(_ range: NSRange, length: Int) -> Bool {
        range.location >= 0 && range.location <= length && range.length >= 0
            && range.length <= length - range.location
    }

    private static func clamped(_ range: NSRange, length: Int) -> NSRange {
        let start = min(max(0, range.location), length)
        return NSRange(location: start,
                       length: min(max(0, range.length), length - start))
    }
}
