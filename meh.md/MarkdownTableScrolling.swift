import Foundation

#if os(macOS)
import AppKit
#else
import UIKit
#endif
import ObjectiveC

nonisolated(unsafe) private var tableOverlayControllerKey: UInt8 = 0

/// The source remains in TextKit. These views contain only transparent scroll
/// content; horizontal movement changes the coordinates used to draw a table.
extension MarkdownTextView {
    private var markdownTableOverlayController: MarkdownTableOverlayController? {
        objc_getAssociatedObject(self, &tableOverlayControllerKey)
            as? MarkdownTableOverlayController
    }

    var markdownTableScrollOverlays: [MarkdownTableScrollOverlay] {
        markdownTableOverlayController?.overlays ?? []
    }

    var markdownTableDrawingOffsets: [NSRange: CGFloat] {
        var offsets = markdownSyntaxCache.tableHorizontalOffsets
        for overlay in markdownTableScrollOverlays {
            offsets[overlay.tableRange] = overlay.elasticHorizontalOffset
        }
        return offsets
    }

    func installMarkdownTableScrolling() {
        guard markdownTableOverlayController == nil else { return }
        objc_setAssociatedObject(
            self, &tableOverlayControllerKey,
            MarkdownTableOverlayController(textView: self),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    func updateMarkdownTableScrollOverlays() {
        installMarkdownTableScrolling()
        markdownTableOverlayController?.update()
    }

    /// Kept as a geometry query for callers that need to distinguish an
    /// overflow row from ordinary prose. Native scroll views handle input.
    func scrollableMarkdownTable(at point: CGPoint) -> NSRange? {
        markdownTableScrollOverlays.first {
            $0.frame.contains(point) && $0.contentWidth > $0.bounds.width + 0.5
        }?.tableRange
    }

    @discardableResult
    func setMarkdownTableHorizontalOffset(_ offset: CGFloat, for range: NSRange) -> Bool {
        guard markdownSyntaxCache.setTableHorizontalOffset(offset, for: range) else {
            return false
        }
        if let overlay = markdownTableScrollOverlays.first(where: {
            $0.tableRange == range
        }) {
            overlay.setNativeHorizontalOffset(
                markdownSyntaxCache.tableHorizontalOffsets[range, default: 0]
            )
        }
        invalidateMarkdownTableDrawing(for: range)
        return true
    }

    func invalidateMarkdownTableDrawing(for range: NSRange) {
        if let manager = textLayoutManager,
           let content = manager.textContentManager,
           let start = content.location(content.documentRange.location,
                                        offsetBy: range.location),
           let end = content.location(start, offsetBy: range.length),
           let textRange = NSTextRange(location: start, end: end) {
            manager.invalidateRenderingAttributes(for: textRange)
            manager.textViewportLayoutController.layoutViewport()
        }
#if os(macOS)
        needsDisplay = true
#else
        setNeedsDisplay()
#endif
    }
}

private struct MarkdownTableOverlayGeometry {
    let frame: CGRect
    let rowFrames: [CGRect]
    let rows: [MarkdownTableLayout.Row]
    let contentWidth: CGFloat
}

private struct MarkdownTableGeometryKey: Equatable {
    let source: String
    let rowRanges: [NSRange]
    let rowHeights: [CGFloat]
    let rowWidths: [CGFloat]
    let tableWidth: CGFloat
    let containerSize: CGSize
    let origin: CGPoint
    let fontSize: CGFloat
    let fontName: String
    let selection: NSRange
}

@MainActor
private final class MarkdownTableOverlayController: NSObject {
    private weak var textView: MarkdownTextView?
    private var byRange: [NSRange: MarkdownTableScrollOverlay] = [:]
    private var updating = false
    private var cachedGeometryKey: MarkdownTableGeometryKey?
    private var cachedGeometries: [NSRange: MarkdownTableOverlayGeometry] = [:]

    var overlays: [MarkdownTableScrollOverlay] {
        byRange.values.sorted { $0.tableRange.location < $1.tableRange.location }
    }

    init(textView: MarkdownTextView) {
        self.textView = textView
    }

    func update() {
        guard !updating, let textView else { return }
        updating = true
        defer { updating = false }
        let key = geometryKey(in: textView)
        let geometries: [NSRange: MarkdownTableOverlayGeometry]
        if let key, key == cachedGeometryKey {
            geometries = cachedGeometries
        } else {
            geometries = geometry(in: textView)
            cachedGeometryKey = key
            cachedGeometries = geometries
        }
        for range in Array(byRange.keys) where geometries[range] == nil {
            byRange.removeValue(forKey: range)?.removeFromSuperview()
        }
        for (range, geometry) in geometries {
            let overlay: MarkdownTableScrollOverlay
            if let existing = byRange[range] {
                overlay = existing
            } else {
                overlay = MarkdownTableScrollOverlay()
                overlay.tableRange = range
                overlay.markdownTextView = textView
                byRange[range] = overlay
                textView.addSubview(overlay)
            }
            overlay.configure(
                frame: geometry.frame,
                contentWidth: geometry.contentWidth,
                rows: geometry.rows,
                rowFrames: geometry.rowFrames,
                offset: textView.markdownSyntaxCache.tableHorizontalOffsets[
                    range, default: 0
                ]
            )
            overlay.updateMarkdownTableAccessibility()
        }
        textView.updateMarkdownTableAccessibilityNavigation()
    }

    private func geometryKey(in textView: MarkdownTextView) -> MarkdownTableGeometryKey? {
        guard let layout = textView.markdownSyntaxCache.tableLayout else { return nil }
#if os(macOS)
        guard let container = textView.textContainer else { return nil }
        let source = textView.string
        let origin = textView.textContainerOrigin
        let selection = textView.selectedRange()
#else
        let container = textView.textContainer
        let source = textView.text ?? ""
        let origin = CGPoint(x: textView.textContainerInset.left,
                             y: textView.textContainerInset.top)
        let selection = textView.selectedRange
#endif
        return MarkdownTableGeometryKey(
            source: source,
            rowRanges: layout.rows.map(\.range),
            rowHeights: layout.rows.map(\.height),
            rowWidths: layout.rows.map(\.contentWidth),
            tableWidth: layout.width,
            containerSize: container.size,
            origin: origin,
            fontSize: (textView.typingAttributes[.font] as? PlatformFont)?.pointSize ?? 0,
            fontName: (textView.typingAttributes[.font] as? PlatformFont)?.fontName ?? "",
            selection: selection
        )
    }

    private func geometry(
        in textView: MarkdownTextView
    ) -> [NSRange: MarkdownTableOverlayGeometry] {
        guard let layout = textView.markdownSyntaxCache.tableLayout,
              !layout.rows.isEmpty,
              let manager = textView.textLayoutManager,
              let content = manager.textContentManager else { return [:] }
#if os(macOS)
        guard let container = textView.textContainer else { return [:] }
        let origin = textView.textContainerOrigin
#else
        let container = textView.textContainer
        let origin = CGPoint(
            x: textView.textContainerInset.left,
            y: textView.textContainerInset.top
        )
#endif
        let x = origin.x + container.lineFragmentPadding
        let rowByLocation = Dictionary(
            uniqueKeysWithValues: layout.rows.map { ($0.range.location, $0) }
        )
        let lastRowEnd = layout.rows.map { NSMaxRange($0.range) }.max() ?? 0
        var framesByTable: [NSRange: [Int: CGRect]] = [:]
        manager.enumerateTextLayoutFragments(
            from: content.documentRange.location, options: [.ensuresLayout]
        ) { fragment in
            let location = content.offset(
                from: content.documentRange.location,
                to: fragment.rangeInElement.location
            )
            if let row = rowByLocation[location] {
                framesByTable[row.tableRange, default: [:]][location] = CGRect(
                    x: x,
                    y: origin.y + fragment.layoutFragmentFrame.minY,
                    width: layout.width,
                    height: row.height
                )
            }
            return location <= lastRowEnd
        }
        var result: [NSRange: MarkdownTableOverlayGeometry] = [:]
        for (range, fragmentFrames) in framesByTable {
            let rows = layout.rows.filter { $0.tableRange == range }
            guard let first = fragmentFrames.values.min(by: {
                $0.minY < $1.minY
            }), let last = fragmentFrames.values.max(by: {
                $0.maxY < $1.maxY
            }), let width = layout.contentWidth(for: range) else { continue }
            let frame = CGRect(
                x: x, y: first.minY, width: layout.width,
                height: max(1, last.maxY - first.minY)
            )
            result[range] = MarkdownTableOverlayGeometry(
                frame: frame,
                rowFrames: rows.map { row in
                    guard let fragment = fragmentFrames[row.range.location] else {
                        return .zero
                    }
                    return CGRect(
                        x: 0, y: fragment.minY - frame.minY,
                        width: width, height: fragment.height
                    )
                },
                rows: rows,
                contentWidth: width
            )
        }
        return result
    }
}

#if os(macOS)
final class MarkdownTableScrollOverlay: NSScrollView {
    var tableRange = NSRange(location: NSNotFound, length: 0)
    var tableRows: [MarkdownTableLayout.Row] = []
    var rowFrames: [CGRect] = []
    var contentWidth: CGFloat = 0
    weak var markdownTextView: MarkdownTextView?
    var elasticHorizontalOffset: CGFloat { contentView.bounds.minX }
    private var settingOffset = false

    init() {
        super.init(frame: .zero)
        drawsBackground = false
        hasVerticalScroller = false
        hasHorizontalScroller = true
        horizontalScrollElasticity = .allowed
        verticalScrollElasticity = .none
        let document = MarkdownTableScrollDocumentView()
        document.overlay = self
        documentView = document
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(didScroll),
            name: NSView.boundsDidChangeNotification, object: contentView
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func tile() {
        super.tile()
        documentView?.frame.size.height = max(1, contentView.bounds.height)
    }

    func configure(
        frame: CGRect, contentWidth: CGFloat,
        rows: [MarkdownTableLayout.Row], rowFrames: [CGRect], offset: CGFloat
    ) {
        let previousRange = tableRows.first?.tableRange
        let previousWidth = self.contentWidth
        let previousFrame = self.frame
        self.frame = frame
        self.contentWidth = contentWidth
        hasHorizontalScroller = contentWidth > frame.width + 0.5
        tableRows = rows
        self.rowFrames = rowFrames
        documentView?.frame = CGRect(
            x: 0, y: 0, width: max(frame.width, contentWidth),
            height: max(1, contentView.bounds.height)
        )
        let maximum = max(0, contentWidth - frame.width)
        let liveClamped = min(max(0, elasticHorizontalOffset), maximum)
        if previousRange != tableRange || previousWidth != contentWidth
            || previousFrame.width != frame.width
            || abs(liveClamped - offset) > 0.5 {
            setNativeHorizontalOffset(offset)
        }
    }

    func setNativeHorizontalOffset(_ offset: CGFloat) {
        guard abs(elasticHorizontalOffset - offset) > 0.5 else { return }
        settingOffset = true
        contentView.scroll(to: CGPoint(x: offset, y: 0))
        reflectScrolledClipView(contentView)
        settingOffset = false
    }

    @objc private func didScroll() {
        guard !settingOffset, let markdownTextView else { return }
        _ = markdownTextView.markdownSyntaxCache.setTableHorizontalOffset(
            elasticHorizontalOffset, for: tableRange
        )
        markdownTextView.invalidateMarkdownTableDrawing(for: tableRange)
    }

    override func scrollWheel(with event: NSEvent) {
        let shifted = event.modifierFlags.contains(.shift)
        if !shifted && abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
            markdownTextView?.enclosingScrollView?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    func revealMarkdownTableCellFrame(_ frame: CGRect) {
        let row = CGRect(
            x: self.frame.minX, y: self.frame.minY + frame.minY,
            width: bounds.width, height: frame.height
        )
        markdownTextView?.scrollToVisible(row)
        let current = elasticHorizontalOffset
        let target: CGFloat
        if frame.minX < current { target = frame.minX }
        else if frame.maxX > current + bounds.width {
            target = frame.maxX - bounds.width
        } else { return }
        setNativeHorizontalOffset(
            min(max(0, target), max(0, contentWidth - bounds.width))
        )
        _ = markdownTextView?.markdownSyntaxCache.setTableHorizontalOffset(
            elasticHorizontalOffset, for: tableRange
        )
        markdownTextView?.invalidateMarkdownTableDrawing(for: tableRange)
    }

    @discardableResult
    func scrollMarkdownTablePage(forward: Bool) -> Bool {
        let current = elasticHorizontalOffset
        let target = min(max(0, current + (forward ? 1 : -1)
            * bounds.width * 0.8), max(0, contentWidth - bounds.width))
        guard abs(target - current) > 0.5 else { return false }
        setNativeHorizontalOffset(target)
        _ = markdownTextView?.markdownSyntaxCache.setTableHorizontalOffset(
            target, for: tableRange
        )
        markdownTextView?.invalidateMarkdownTableDrawing(for: tableRange)
        return true
    }

    @discardableResult
    func revealMarkdownTableCell(row: Int, column: Int) -> Bool {
        guard let textView = markdownTextView, textView.isEditable,
              !textView.hasMarkedText(),
              let source = textView.markdownSyntaxCache.currentPresentation?
                .result.tables.first(where: { $0.range == tableRange }),
              tableRows.indices.contains(row),
              tableRows[row].cells.indices.contains(column) else { return false }
        let sourceRows = [source.header] + source.rows
        guard sourceRows.indices.contains(row) else { return false }
        let location = sourceRows[row].cells.indices.contains(column)
            ? sourceRows[row].cells[column].location
            : sourceRows[row].range.location
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(
            location: location, length: 0
        ))
        return true
    }

    fileprivate func revealCell(at point: CGPoint) {
        let row = rowFrames.firstIndex { $0.minY <= point.y && point.y < $0.maxY }
        guard let row, tableRows.indices.contains(row) else { return }
        let x = point.x
        var columnX: CGFloat = 0
        for (column, width) in tableRows[row].columnWidths.enumerated() {
            if x < columnX + width || column == tableRows[row].columnWidths.count - 1 {
                revealMarkdownTableCell(row: row, column: column)
                return
            }
            columnX += width
        }
    }
}

private final class MarkdownTableScrollDocumentView: NSView {
    weak var overlay: MarkdownTableScrollOverlay?
    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) {
        overlay?.revealCell(at: convert(event.locationInWindow, from: nil))
    }
}
#else
final class MarkdownTableScrollOverlay: UIScrollView, UIScrollViewDelegate {
    var tableRange = NSRange(location: NSNotFound, length: 0)
    var tableRows: [MarkdownTableLayout.Row] = []
    var rowFrames: [CGRect] = []
    var contentWidth: CGFloat = 0
    weak var markdownTextView: MarkdownTextView?
    var elasticHorizontalOffset: CGFloat { contentOffset.x }
    private var settingOffset = false
    private let transparentContentView = UIView(frame: .zero)

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        contentInsetAdjustmentBehavior = .never
        showsHorizontalScrollIndicator = true
        showsVerticalScrollIndicator = false
        alwaysBounceHorizontal = false
        alwaysBounceVertical = false
        isDirectionalLockEnabled = true
        delaysContentTouches = false
        delegate = self
        transparentContentView.backgroundColor = .clear
        transparentContentView.isOpaque = false
        addSubview(transparentContentView)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    var contentView: UIView { transparentContentView }

    func configure(
        frame: CGRect, contentWidth: CGFloat,
        rows: [MarkdownTableLayout.Row], rowFrames: [CGRect], offset: CGFloat
    ) {
        let previousRange = tableRows.first?.tableRange
        let previousWidth = self.contentWidth
        let previousFrame = self.frame
        self.frame = frame
        self.contentWidth = contentWidth
        tableRows = rows
        self.rowFrames = rowFrames
        contentSize = CGSize(width: max(frame.width, contentWidth), height: frame.height)
        contentView.frame = CGRect(origin: .zero, size: contentSize)
        let maximum = max(0, contentWidth - frame.width)
        let liveClamped = min(max(0, elasticHorizontalOffset), maximum)
        if previousRange != tableRange || previousWidth != contentWidth
            || previousFrame.width != frame.width
            || abs(liveClamped - offset) > 0.5 {
            setNativeHorizontalOffset(offset)
        }
    }

    func setNativeHorizontalOffset(_ offset: CGFloat) {
        guard abs(elasticHorizontalOffset - offset) > 0.5 else { return }
        settingOffset = true
        contentOffset = CGPoint(x: offset, y: 0)
        settingOffset = false
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !settingOffset, let markdownTextView else { return }
        _ = markdownTextView.markdownSyntaxCache.setTableHorizontalOffset(
            elasticHorizontalOffset, for: tableRange
        )
        markdownTextView.invalidateMarkdownTableDrawing(for: tableRange)
    }

    override func gestureRecognizerShouldBegin(
        _ gestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        if gestureRecognizer === panGestureRecognizer {
            let velocity = panGestureRecognizer.velocity(in: self)
            if abs(velocity.y) > abs(velocity.x) * 1.1 { return false }
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    func revealMarkdownTableCellFrame(_ frame: CGRect) {
        let row = CGRect(
            x: self.frame.minX, y: self.frame.minY + frame.minY,
            width: bounds.width, height: frame.height
        )
        markdownTextView?.scrollRectToVisible(row, animated: false)
        let current = elasticHorizontalOffset
        let target: CGFloat
        if frame.minX < current { target = frame.minX }
        else if frame.maxX > current + bounds.width {
            target = frame.maxX - bounds.width
        } else { return }
        setNativeHorizontalOffset(
            min(max(0, target), max(0, contentWidth - bounds.width))
        )
        _ = markdownTextView?.markdownSyntaxCache.setTableHorizontalOffset(
            elasticHorizontalOffset, for: tableRange
        )
        markdownTextView?.invalidateMarkdownTableDrawing(for: tableRange)
    }

    @discardableResult
    func scrollMarkdownTablePage(forward: Bool) -> Bool {
        let current = elasticHorizontalOffset
        let target = min(max(0, current + (forward ? 1 : -1)
            * bounds.width * 0.8), max(0, contentWidth - bounds.width))
        guard abs(target - current) > 0.5 else { return false }
        setNativeHorizontalOffset(target)
        _ = markdownTextView?.markdownSyntaxCache.setTableHorizontalOffset(
            target, for: tableRange
        )
        markdownTextView?.invalidateMarkdownTableDrawing(for: tableRange)
        UIAccessibility.post(notification: .pageScrolled, argument:
            forward ? String(localized: "Next columns") : String(localized: "Previous columns"))
        return true
    }

    @discardableResult
    func revealMarkdownTableCell(row: Int, column: Int) -> Bool {
        guard let textView = markdownTextView, textView.isEditable,
              textView.markedTextRange == nil,
              let source = textView.markdownSyntaxCache.currentPresentation?
                .result.tables.first(where: { $0.range == tableRange }),
              tableRows.indices.contains(row),
              tableRows[row].cells.indices.contains(column) else { return false }
        let sourceRows = [source.header] + source.rows
        guard sourceRows.indices.contains(row) else { return false }
        let location = sourceRows[row].cells.indices.contains(column)
            ? sourceRows[row].cells[column].location
            : sourceRows[row].range.location
        textView.becomeFirstResponder()
        textView.selectedRange = NSRange(
            location: location, length: 0
        )
        return true
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: contentView)
        let row = rowFrames.firstIndex { $0.minY <= point.y && point.y < $0.maxY }
        guard let row, tableRows.indices.contains(row) else { return }
        let x = point.x
        var columnX: CGFloat = 0
        for (column, width) in tableRows[row].columnWidths.enumerated() {
            if x < columnX + width || column == tableRows[row].columnWidths.count - 1 {
                revealMarkdownTableCell(row: row, column: column)
                return
            }
            columnX += width
        }
    }
}
#endif
