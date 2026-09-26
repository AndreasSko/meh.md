import Foundation

/// Source-only table operations. Every change is a single native text edit so
/// undo, selection, storage, and sync continue to use literal Markdown.
enum MarkdownTableEditing {
    private struct Position {
        let table: MarkdownTable
        let row: Int // Header is zero; body rows start at one.
        let column: Int
        let selection: NSRange
    }

    static func availableCommands(
        text: String,
        selection: NSRange,
        syntax: MarkdownSyntaxResult? = nil
    ) -> Set<MarkdownEditingCommand> {
        let source = text as NSString
        let selection = MarkdownEditingRules.tableSafeSelection(selection,
                                                                in: source)
        let parsed = syntax ?? MarkdownSyntax.parse(text)
        guard let position = position(
            selection, source: source, tables: parsed.tables
        ) else {
            return canInsert(at: selection, source: source, syntax: parsed)
                ? [.insertTable] : []
        }
        var commands: Set<MarkdownEditingCommand> = [
            .tableColumnBefore, .tableColumnAfter,
            .tableAlignLeft, .tableAlignCenter, .tableAlignRight,
            .tableNextCell, .tablePreviousCell,
        ]
        if position.row > 0 {
            commands.formUnion([.tableRowAbove, .tableRowBelow,
                                .tableDeleteRow])
        } else {
            commands.insert(.tableRowBelow)
        }
        if position.table.header.cells.count > 1 {
            commands.insert(.tableDeleteColumn)
        }
        return commands
    }

    static func currentAlignment(
        text: String,
        selection: NSRange,
        syntax: MarkdownSyntaxResult? = nil
    ) -> MarkdownTableAlignment? {
        let source = text as NSString
        let safeSelection = MarkdownEditingRules.tableSafeSelection(
            selection, in: source
        )
        let parsed = syntax ?? MarkdownSyntax.parse(text)
        guard let position = position(
            safeSelection, source: source, tables: parsed.tables
        ) else { return nil }
        return position.table.alignments[position.column]
    }

    static func change(
        for command: MarkdownEditingCommand,
        text: String,
        selection: NSRange
    ) -> MarkdownEditingChange? {
        let source = text as NSString
        let selection = MarkdownEditingRules.tableSafeSelection(selection,
                                                                in: source)
        let parsed = MarkdownSyntax.parse(text)
        if command == .insertTable {
            guard canInsert(at: selection, source: source, syntax: parsed) else {
                return nil
            }
            return insertTable(in: source, selection: selection)
        }
        guard let position = position(
            selection, source: source, tables: parsed.tables
        ) else { return nil }
        switch command {
        case .tableRowAbove:
            guard position.row > 0 else { return nil }
            return insertRow(before: position.row, at: position, source: source)
        case .tableRowBelow:
            return insertRow(before: position.row + 1,
                             at: position, source: source)
        case .tableColumnBefore:
            return changeColumn(at: position.column,
                                delete: false, position: position,
                                source: source)
        case .tableColumnAfter:
            return changeColumn(at: position.column + 1,
                                delete: false, position: position,
                                source: source)
        case .tableDeleteRow:
            guard position.row > 0 else { return nil }
            let row = position.table.rows[position.row - 1]
            return MarkdownEditingChange(
                range: row.range, replacement: "",
                selection: NSRange(location: row.range.location, length: 0)
            )
        case .tableDeleteColumn:
            guard position.table.header.cells.count > 1 else { return nil }
            return changeColumn(at: position.column,
                                delete: true, position: position,
                                source: source)
        case .tableAlignLeft, .tableAlignCenter, .tableAlignRight:
            return changeAlignment(command, at: position, source: source)
        case .tableNextCell, .tablePreviousCell:
            return navigate(command, position: position, source: source)
        default:
            return nil
        }
    }

    private static func position(
        _ selection: NSRange,
        source: NSString,
        tables: [MarkdownTable]
    ) -> Position? {
        for table in tables {
            let count = table.header.cells.count
            guard count > 0,
                  table.rows.allSatisfy({ $0.cells.count <= count }),
                  selection.location >= table.range.location,
                  NSMaxRange(selection) <= NSMaxRange(table.range),
                  (selection.location < NSMaxRange(table.range)
                    || table.range.location + table.range.length == source.length
                        && lineEnding(table.rows.last?.range
                            ?? table.delimiterRange, source: source).isEmpty)
                  else {
                continue
            }
            let rows = [table.header] + table.rows
            for (rowIndex, row) in rows.enumerated() {
                let lineEnd = contentEnd(row.range, source: source)
                guard selection.location >= row.range.location,
                      NSMaxRange(selection) <= lineEnd else { continue }
                if selection.length > 0 {
                    guard let column = row.cells.firstIndex(where: {
                        selection.location >= $0.location
                            && NSMaxRange(selection) <= NSMaxRange($0)
                    }) else { return nil }
                    return Position(table: table, row: rowIndex,
                                    column: column, selection: selection)
                }
                let caret = selection.location
                // Separators and whitespace belong to the preceding cell.
                let column = row.cells.enumerated().first(where: { index, cell in
                    index == row.cells.count - 1
                        || caret < row.cells[index + 1].location
                })?.offset ?? 0
                return Position(table: table, row: rowIndex,
                                column: min(column, count - 1),
                                selection: selection)
            }
        }
        return nil
    }

    private static func canInsert(
        at selection: NSRange,
        source: NSString,
        syntax: MarkdownSyntaxResult
    ) -> Bool {
        let insertionLine = MarkdownEditingRules.tableContentLine(
            containing: NSMaxRange(selection), in: source
        )
        let insertion = source.substring(with: insertionLine)
            .trimmingCharacters(in: .whitespaces).isEmpty
            ? insertionLine.location
            : lineBreakEnd(after: NSMaxRange(insertionLine),
                           source: source)
        guard !syntax.tables.contains(where: { table in
            if selection.length == 0 {
                return selection.location >= table.range.location
                    && selection.location < NSMaxRange(table.range)
                    || insertion > table.range.location
                        && insertion < NSMaxRange(table.range)
            }
            return NSIntersectionRange(selection, table.range).length > 0
                || insertion > table.range.location
                    && insertion < NSMaxRange(table.range)
        }) else { return false }
        return !syntax.spans.contains { span in
            guard span.role == .code else { return false }
            if selection.length == 0 {
                return selection.location >= span.range.location
                    && selection.location < NSMaxRange(span.range)
            }
            return NSIntersectionRange(selection, span.range).length > 0
        }
    }

    private static func insertTable(
        in source: NSString,
        selection: NSRange
    ) -> MarkdownEditingChange {
        let line = MarkdownEditingRules.tableContentLine(
            containing: NSMaxRange(selection), in: source
        )
        let isEmpty = source.substring(with: line)
            .trimmingCharacters(in: .whitespaces).isEmpty
        let insertion = isEmpty ? line.location
            : lineBreakEnd(after: NSMaxRange(line), source: source)
        let newline = source.range(of: "\r\n").location != NSNotFound
            ? "\r\n" : "\n"
        let before = source.substring(to: insertion)
        let after = source.substring(from: insertion)
        let prefix: String
        if before.isEmpty || before.hasSuffix(newline + newline) {
            prefix = ""
        } else if before.hasSuffix(newline) {
            prefix = newline
        } else {
            prefix = newline + newline
        }
        let body = "| Column 1 | Column 2 |" + newline
            + "| --- | --- |" + newline
            + "|  |  |" + newline
        let suffix = after.isEmpty || after.hasPrefix(newline)
            ? "" : newline
        let replacement = prefix + body + suffix
        let firstCell = (prefix + "| ").utf16.count + insertion
        return MarkdownEditingChange(
            range: NSRange(location: insertion, length: 0),
            replacement: replacement,
            selection: NSRange(location: firstCell,
                               length: "Column 1".utf16.count)
        )
    }

    private static func insertRow(
        before rowIndex: Int,
        at position: Position,
        source: NSString
    ) -> MarkdownEditingChange {
        let table = position.table
        let rows = [table.header] + table.rows
        let point = rowIndex < rows.count
            ? rows[rowIndex].range.location : NSMaxRange(table.range)
        let newline = lineEnding(table.header.range, source: source)
        let content = "| " + Array(
            repeating: "", count: table.header.cells.count
        ).joined(separator: " | ") + " |"
        let hasPreviousLineBreak = point > 0
            && (source.character(at: point - 1) == 10
                || source.character(at: point - 1) == 13)
        let prefix = hasPreviousLineBreak ? "" : newline
        let replacement = prefix + content + newline
        return MarkdownEditingChange(
            range: NSRange(location: point, length: 0),
            replacement: replacement,
            selection: NSRange(location: point + prefix.utf16.count + 3,
                               length: 0)
        )
    }

    private static func changeColumn(
        at column: Int,
        delete: Bool,
        position: Position,
        source: NSString
    ) -> MarkdownEditingChange? {
        let table = position.table
        let count = table.header.cells.count
        guard !delete || count > 1 else { return nil }
        var cells = ([table.header] + table.rows).map { row in
            row.cells.map { source.substring(with: $0) }
                + Array(repeating: "", count: count - row.cells.count)
        }
        var alignments = table.alignments
        if delete {
            for index in cells.indices { cells[index].remove(at: column) }
            alignments.remove(at: column)
        } else {
            for index in cells.indices { cells[index].insert("", at: column) }
            alignments.insert(.left, at: column)
        }
        return rebuiltTable(
            table, cells: cells, alignments: alignments,
            selectedRow: position.row,
            selectedColumn: delete ? min(column, count - 2) : column,
            source: source
        )
    }

    private static func changeAlignment(
        _ command: MarkdownEditingCommand,
        at position: Position,
        source: NSString
    ) -> MarkdownEditingChange? {
        let target: MarkdownTableAlignment
        switch command {
        case .tableAlignCenter: target = .center
        case .tableAlignRight: target = .right
        default: target = .left
        }
        let table = position.table
        guard table.alignments[position.column] != target else { return nil }
        let line = table.delimiterRange
        let old = source.substring(with: line)
        let ending = lineEnding(line, source: source)
        let content = old.hasSuffix(ending)
            ? String(old.dropLast(ending.count)) : old
        // Preserve the delimiter's existing width and outer-pipe style.
        let fields = splitPipes(content)
        guard fields.count == table.header.cells.count else { return nil }
        var changed = fields
        let dashCount = max(3, fields[position.column].filter { $0 == "-" }.count)
        let dashes = String(repeating: "-", count: dashCount)
        changed[position.column] = switch target {
        case .left: ":" + dashes
        case .center: ":" + dashes + ":"
        case .right: dashes + ":"
        }
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        let leadingPipe = trimmed.hasPrefix("|")
        let trailingPipe = trimmed.hasSuffix("|")
        let indentation = String(content.prefix(while: { $0 == " " }))
        let replacement = indentation + (leadingPipe ? "| " : "")
            + changed.joined(separator: " | ")
            + (trailingPipe ? " |" : "") + ending
        let displacement = position.row == 0 ? 0
            : replacement.utf16.count - line.length
        return MarkdownEditingChange(
            range: line, replacement: replacement,
            selection: NSRange(location: position.selection.location
                                + displacement,
                               length: position.selection.length)
        )
    }

    private static func navigate(
        _ command: MarkdownEditingCommand,
        position: Position,
        source: NSString
    ) -> MarkdownEditingChange? {
        let table = position.table
        let count = table.header.cells.count
        let rows = [table.header] + table.rows
        if command == .tablePreviousCell,
           position.row == 0, position.column == 0 {
            let tableStart = table.range.location
            let precedingCRLF = tableStart >= 2
                && source.character(at: tableStart - 2) == 13
                && source.character(at: tableStart - 1) == 10
            let before = max(0, tableStart - (precedingCRLF ? 2 : 1))
            return MarkdownEditingChange(
                range: NSRange(location: table.range.location, length: 0),
                replacement: "",
                selection: NSRange(location: before, length: 0)
            )
        }
        if command == .tableNextCell,
           position.row == rows.count - 1, position.column == count - 1 {
            return insertRow(before: rows.count, at: position, source: source)
        }
        let nextRow: Int
        let nextColumn: Int
        if command == .tablePreviousCell {
            nextRow = position.column == 0 ? position.row - 1 : position.row
            nextColumn = position.column == 0 ? count - 1
                : position.column - 1
        } else {
            nextRow = position.column == count - 1
                ? position.row + 1 : position.row
            nextColumn = position.column == count - 1
                ? 0 : position.column + 1
        }
        let row = rows[nextRow]
        guard nextColumn < row.cells.count else {
            return materializeMissingCells(
                in: row, through: nextColumn, source: source
            )
        }
        let point = row.cells[nextColumn].location
        return MarkdownEditingChange(
            range: NSRange(location: point, length: 0), replacement: "",
            selection: row.cells[nextColumn]
        )
    }

    private static func materializeMissingCells(
        in row: MarkdownTableRow,
        through column: Int,
        source: NSString
    ) -> MarkdownEditingChange {
        let cells = row.cells.map { source.substring(with: $0) }
            + Array(repeating: "", count: column + 1 - row.cells.count)
        var replacement = "| "
        var caret = 2
        for (index, cell) in cells.enumerated() {
            if index == column {
                caret = replacement.utf16.count + (cell.isEmpty ? 1 : 0)
            }
            replacement += cell
            replacement += index == cells.count - 1 ? " |" : " | "
        }
        replacement += lineEnding(row.range, source: source)
        return MarkdownEditingChange(
            range: row.range, replacement: replacement,
            selection: NSRange(location: row.range.location + caret,
                               length: 0)
        )
    }

    private static func rebuiltTable(
        _ table: MarkdownTable,
        cells: [[String]],
        alignments: [MarkdownTableAlignment],
        selectedRow: Int,
        selectedColumn: Int,
        source: NSString
    ) -> MarkdownEditingChange {
        let rows = [table.header] + table.rows
        var replacement = ""
        var selectedOffset = 0
        for (rowIndex, rowCells) in cells.enumerated() {
            replacement += "| "
            for (column, cell) in rowCells.enumerated() {
                if rowIndex == selectedRow && column == selectedColumn {
                    selectedOffset = replacement.utf16.count
                        + (cell.isEmpty ? 1 : 0)
                }
                replacement += cell
                replacement += column == rowCells.count - 1 ? " |" : " | "
            }
            replacement += lineEnding(rows[rowIndex].range, source: source)
            if rowIndex == 0 {
                replacement += "| "
                for (column, alignment) in alignments.enumerated() {
                    let marker = switch alignment {
                    case .left: ":---"
                    case .center: ":---:"
                    case .right: "---:"
                    }
                    replacement += marker
                    replacement += column == alignments.count - 1
                        ? " |" : " | "
                }
                replacement += lineEnding(table.delimiterRange,
                                          source: source)
            }
        }
        return MarkdownEditingChange(
            range: table.range, replacement: replacement,
            selection: NSRange(location: table.range.location
                                + selectedOffset, length: 0)
        )
    }

    private static func splitPipes(_ content: String) -> [String] {
        var value = content.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("|") { value.removeFirst() }
        if value.hasSuffix("|") { value.removeLast() }
        return value.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func contentEnd(
        _ range: NSRange, source: NSString
    ) -> Int {
        var end = NSMaxRange(range)
        while end > range.location {
            let c = source.character(at: end - 1)
            if c == 10 || c == 13 { end -= 1 } else { break }
        }
        return end
    }

    private static func lineEnding(
        _ range: NSRange, source: NSString
    ) -> String {
        let end = NSMaxRange(range)
        guard end > range.location else { return "" }
        if source.character(at: end - 1) == 10 {
            return end > range.location + 1
                && source.character(at: end - 2) == 13 ? "\r\n" : "\n"
        }
        return source.character(at: end - 1) == 13 ? "\r" : ""
    }

    private static func lineBreakEnd(
        after end: Int, source: NSString
    ) -> Int {
        guard end < source.length else { return end }
        if source.character(at: end) == 13,
           end + 1 < source.length,
           source.character(at: end + 1) == 10 {
            return end + 2
        }
        return end + 1
    }
}
