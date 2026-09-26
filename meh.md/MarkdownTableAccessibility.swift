import Foundation
import ObjectiveC

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Accessible cells use the same text and geometry as the rendered table.
/// Reading and scrolling never move the native editor's insertion point.
nonisolated struct MarkdownAccessibleTableCell: Equatable, Sendable {
    let row: Int
    let column: Int
    let text: String
    let header: String
    let frame: CGRect

    var label: String {
        if row == 0 { return text.isEmpty ? String(localized: "Empty header") : text }
        let value = text.isEmpty ? String(localized: "Empty cell") : text
        return header.isEmpty ? value : "\(header): \(value)"
    }

    @MainActor static func make(rows: [MarkdownTableLayout.Row], frames: [CGRect]) -> [Self] {
        guard let header = rows.first else { return [] }
        return rows.enumerated().flatMap { rowIndex, row in
            guard rowIndex < frames.count else { return [Self]() }
            var x: CGFloat = 0
            return row.cells.enumerated().map { column, cell in
                let width = row.columnWidths[column]
                defer { x += width }
                return Self(row: rowIndex, column: column, text: cell.string,
                            header: header.cells[column].string,
                            frame: CGRect(x: x, y: frames[rowIndex].minY,
                                          width: width, height: frames[rowIndex].height))
            }
        }
    }
}

nonisolated(unsafe) private var tableAccessibilityKey: UInt8 = 0

#if os(macOS)
// AppKit invokes accessibility callbacks on the main thread. Bridge its
// nonisolated Objective-C overrides to the editor's main-actor state.
@MainActor private final class MarkdownTableAXContext {
    weak var overlay: MarkdownTableScrollOverlay?
    init(_ overlay: MarkdownTableScrollOverlay) { self.overlay = overlay }
}

nonisolated private final class MarkdownTableAXCell: NSAccessibilityElement {
    let context: MarkdownTableAXContext
    let cell: MarkdownAccessibleTableCell

    @MainActor init(cell: MarkdownAccessibleTableCell, overlay: MarkdownTableScrollOverlay) {
        self.cell = cell
        self.context = MarkdownTableAXContext(overlay)
        super.init()
        setAccessibilityRole(.cell)
        setAccessibilityLabel(cell.label)
        setAccessibilityValue(cell.text)
        setAccessibilityRowIndexRange(NSRange(location: cell.row, length: 1))
        setAccessibilityColumnIndexRange(NSRange(location: cell.column, length: 1))
        setAccessibilityHelp(String(localized: "Edit this cell in Markdown"))
    }

    override func accessibilityFrame() -> NSRect {
        let context = context
        let cell = cell
        return MainActor.assumeIsolated {
            guard let document = context.overlay?.documentView, let window = document.window else { return .zero }
            return window.convertToScreen(document.convert(cell.frame, to: nil))
        }
    }

    override func accessibilityPerformPress() -> Bool {
        let context = context
        let cell = cell
        return MainActor.assumeIsolated {
            guard let overlay = context.overlay else { return false }
            return overlay.revealMarkdownTableCell(row: cell.row, column: cell.column)
        }
    }

    override func setAccessibilityFocused(_ focused: Bool) {
        super.setAccessibilityFocused(focused)
        if focused {
            let context = context
            let cell = cell
            MainActor.assumeIsolated { context.overlay?.revealMarkdownTableCellFrame(cell.frame) }
        }
    }
}

/// Container frames follow native scrolling instead of caching screen points.
nonisolated private final class MarkdownTableAXRegion: NSAccessibilityElement {
    let frameProvider: @MainActor @Sendable () -> CGRect

    @MainActor init(overlay: MarkdownTableScrollOverlay, frame: CGRect? = nil) {
        frameProvider = { [weak overlay] in
            guard let overlay else { return .zero }
            guard let frame else { return overlay.accessibilityFrame() }
            guard let document = overlay.documentView, let window = document.window else { return .zero }
            return window.convertToScreen(document.convert(frame, to: nil))
        }
        super.init()
    }

    override func accessibilityFrame() -> CGRect {
        let provider = frameProvider
        return MainActor.assumeIsolated { provider() }
    }
}

private final class MarkdownTableAXState: NSObject {
    let model: [MarkdownAccessibleTableCell]
    let table: MarkdownTableAXRegion
    let cells: [MarkdownTableAXCell]

    init(overlay: MarkdownTableScrollOverlay, model: [MarkdownAccessibleTableCell]) {
        self.model = model
        table = MarkdownTableAXRegion(overlay: overlay)
        cells = model.map { MarkdownTableAXCell(cell: $0, overlay: overlay) }
        super.init()
        table.setAccessibilityRole(.table)
        table.setAccessibilityLabel(String(localized: "Table"))
        table.setAccessibilityParent(overlay)
        let rowElements = overlay.tableRows.indices.map { row in
            let element = MarkdownTableAXRegion(overlay: overlay, frame: overlay.rowFrames[row])
            element.setAccessibilityRole(.row)
            element.setAccessibilityIndex(row)
            element.setAccessibilityParent(table)
            let children = cells.filter { $0.cell.row == row }
            children.forEach { $0.setAccessibilityParent(element) }
            element.setAccessibilityChildren(children)
            return element
        }
        let columns = (overlay.tableRows.first?.cells.indices ?? 0..<0).map { column in
            let columnCells = model.filter { $0.column == column }
            let frame = columnCells.reduce(CGRect.null) { $0.union($1.frame) }
            let element = MarkdownTableAXRegion(overlay: overlay, frame: frame)
            element.setAccessibilityRole(.column)
            element.setAccessibilityIndex(column)
            element.setAccessibilityParent(table)
            element.setAccessibilityChildren(cells.filter { $0.cell.column == column })
            return element
        }
        let headers = cells.filter { $0.cell.row == 0 }
        for cell in cells where cell.cell.row > 0 {
            cell.setAccessibilityColumnHeaderUIElements([headers[cell.cell.column]])
        }
        table.setAccessibilityRows(rowElements)
        table.setAccessibilityColumns(columns)
        table.setAccessibilityColumnHeaderUIElements(headers)
        table.setAccessibilityChildren(rowElements)
        table.setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: String(localized: "Next columns")) { [weak overlay] in
                overlay?.scrollMarkdownTablePage(forward: true) ?? false
            },
            NSAccessibilityCustomAction(name: String(localized: "Previous columns")) { [weak overlay] in
                overlay?.scrollMarkdownTablePage(forward: false) ?? false
            },
        ])
    }
}

extension MarkdownTableScrollOverlay {
    func updateMarkdownTableAccessibility() {
        let model = MarkdownAccessibleTableCell.make(rows: tableRows, frames: rowFrames)
        let previous = objc_getAssociatedObject(self, &tableAccessibilityKey) as? MarkdownTableAXState
        let state: MarkdownTableAXState
        if let previous, previous.model == model { state = previous }
        else {
            state = MarkdownTableAXState(overlay: self, model: model)
            objc_setAssociatedObject(self, &tableAccessibilityKey, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        documentView?.setAccessibilityElement(false)
        documentView?.setAccessibilityChildren([state.table])
    }
}

extension MarkdownTextView {
    func updateMarkdownTableAccessibilityNavigation() {}
}
#else
private final class MarkdownTableAXCell: UIAccessibilityElement, UIAccessibilityContainerDataTableCell {
    weak var overlay: MarkdownTableScrollOverlay?
    let cell: MarkdownAccessibleTableCell

    init(cell: MarkdownAccessibleTableCell, container: MarkdownTableAXContainer,
         overlay: MarkdownTableScrollOverlay) {
        self.cell = cell
        self.overlay = overlay
        super.init(accessibilityContainer: container)
        accessibilityLabel = cell.label
        accessibilityIdentifier = "markdown-table-cell-\(cell.row)-\(cell.column)"
        accessibilityTraits = cell.row == 0 ? [.staticText, .header] : .staticText
        accessibilityHint = String(localized: "Double-tap to edit this cell in Markdown")
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: String(localized: "Next columns")) { [weak overlay] _ in
                overlay?.scrollMarkdownTablePage(forward: true) ?? false
            },
            UIAccessibilityCustomAction(name: String(localized: "Previous columns")) { [weak overlay] _ in
                overlay?.scrollMarkdownTablePage(forward: false) ?? false
            },
        ]
    }

    override var accessibilityFrame: CGRect {
        get {
            guard let content = overlay?.contentView else { return .zero }
            return UIAccessibility.convertToScreenCoordinates(cell.frame, in: content)
        }
        set {}
    }

    func accessibilityRowRange() -> NSRange { NSRange(location: cell.row, length: 1) }
    func accessibilityColumnRange() -> NSRange { NSRange(location: cell.column, length: 1) }

    override func accessibilityActivate() -> Bool {
        guard let overlay else { return false }
        guard overlay.revealMarkdownTableCell(row: cell.row, column: cell.column) else { return false }
        if let textView = overlay.markdownTextView {
            UIAccessibility.post(notification: .layoutChanged, argument: textView)
        }
        return true
    }

    override func accessibilityElementDidBecomeFocused() {
        overlay?.revealMarkdownTableCellFrame(cell.frame)
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        guard direction == .left || direction == .right else { return false }
        return overlay?.scrollMarkdownTablePage(forward: direction == .left) ?? false
    }
}

private final class MarkdownTableAXContainer: UIAccessibilityElement, UIAccessibilityContainerDataTable {
    weak var overlay: MarkdownTableScrollOverlay?
    var cells: [MarkdownTableAXCell] = []
    let model: [MarkdownAccessibleTableCell]

    init(overlay: MarkdownTableScrollOverlay, model: [MarkdownAccessibleTableCell]) {
        self.overlay = overlay
        self.model = model
        super.init(accessibilityContainer: overlay)
        isAccessibilityElement = false
        accessibilityContainerType = .dataTable
        accessibilityLabel = String(localized: "Table")
        cells = model.map { MarkdownTableAXCell(cell: $0, container: self, overlay: overlay) }
        accessibilityElements = cells
    }

    func accessibilityRowCount() -> Int { overlay?.tableRows.count ?? 0 }
    func accessibilityColumnCount() -> Int { overlay?.tableRows.first?.cells.count ?? 0 }
    func accessibilityDataTableCellElement(forRow row: Int, column: Int) -> (any UIAccessibilityContainerDataTableCell)? {
        cells.first { $0.cell.row == row && $0.cell.column == column }
    }
    func accessibilityHeaderElements(forColumn column: Int) -> [any UIAccessibilityContainerDataTableCell]? {
        cells.filter { $0.cell.row == 0 && $0.cell.column == column }
    }
}

extension MarkdownTableScrollOverlay {
    fileprivate var tableAccessibility: MarkdownTableAXContainer? {
        objc_getAssociatedObject(self, &tableAccessibilityKey) as? MarkdownTableAXContainer
    }

    func updateMarkdownTableAccessibility() {
        let model = MarkdownAccessibleTableCell.make(rows: tableRows, frames: rowFrames)
        guard tableAccessibility?.model != model else { return }
        let table = MarkdownTableAXContainer(overlay: self, model: model)
        objc_setAssociatedObject(self, &tableAccessibilityKey, table, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        isAccessibilityElement = false
        accessibilityElements = [table]
    }
}

nonisolated(unsafe) private var tableAccessibilityNavigationKey: UInt8 = 0

private final class MarkdownTableAXNavigationState: NSObject {
    let identifiers: [ObjectIdentifier]
    init(_ identifiers: [ObjectIdentifier]) { self.identifiers = identifiers }
}

extension MarkdownTextView {
    /// UITextView remains the native accessible editor. The rotor and actions
    /// offer structured table reading without replacing its editing behavior.
    func updateMarkdownTableAccessibilityNavigation() {
        let overlays = markdownTableScrollOverlays
        let identifiers = overlays.map(ObjectIdentifier.init)
        let previous = objc_getAssociatedObject(self, &tableAccessibilityNavigationKey)
            as? MarkdownTableAXNavigationState
        guard previous?.identifiers != identifiers else { return }
        objc_setAssociatedObject(self, &tableAccessibilityNavigationKey,
            MarkdownTableAXNavigationState(identifiers), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        accessibilityCustomActions = overlays.enumerated().map { index, overlay in
            UIAccessibilityCustomAction(name: String(localized: "Read table \(index + 1)")) { [weak overlay] _ in
                guard let cell = overlay?.tableAccessibility?.cells.first else { return false }
                overlay?.revealMarkdownTableCellFrame(cell.cell.frame)
                UIAccessibility.post(notification: .layoutChanged, argument: cell)
                return true
            }
        }
        guard !overlays.isEmpty else {
            accessibilityCustomRotors = nil
            return
        }
        accessibilityCustomRotors = [UIAccessibilityCustomRotor(name: String(localized: "Table cells")) { [weak self] predicate in
            guard let self else { return nil }
            let cells = self.markdownTableScrollOverlays.flatMap { $0.tableAccessibility?.cells ?? [] }
            let current = predicate.currentItem.targetElement as? MarkdownTableAXCell
            let index = current.flatMap { item in cells.firstIndex { $0 === item } }
            let next = predicate.searchDirection == .next
                ? (index.map { $0 + 1 } ?? 0) : (index.map { $0 - 1 } ?? cells.count - 1)
            guard cells.indices.contains(next) else { return nil }
            let cell = cells[next]
            cell.overlay?.revealMarkdownTableCellFrame(cell.cell.frame)
            return UIAccessibilityCustomRotorItemResult(targetElement: cell, targetRange: nil)
        }]
    }
}
#endif
