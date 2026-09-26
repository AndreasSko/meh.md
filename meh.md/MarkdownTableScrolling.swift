import Foundation

#if os(macOS)
import AppKit
#else
import UIKit
import ObjectiveC
#endif

extension MarkdownTextView {
    /// Hit testing uses the same source row and native fragment geometry as
    /// drawing. Horizontal scrolling never changes native selection or text.
    func scrollableMarkdownTable(at point: CGPoint) -> NSRange? {
        guard let layout = markdownSyntaxCache.tableLayout,
              let manager = textLayoutManager,
              let content = manager.textContentManager else { return nil }
#if os(macOS)
        guard let container = textContainer else { return nil }
        let origin = textContainerOrigin
#else
        let container = textContainer
        let origin = CGPoint(x: textContainerInset.left, y: textContainerInset.top)
#endif
        let left = origin.x + container.lineFragmentPadding
        guard point.x >= left, point.x <= left + layout.width else { return nil }
        let localY = point.y - origin.y
        var hit: NSRange?
        manager.enumerateTextLayoutFragments(
            from: manager.textViewportLayoutController.viewportRange?.location,
            options: [.ensuresLayout]
        ) { fragment in
            if fragment.layoutFragmentFrame.minY > localY { return false }
            let location = content.offset(
                from: content.documentRange.location,
                to: fragment.rangeInElement.location
            )
            if let row = layout.rows.first(where: { $0.range.location == location }),
               localY >= fragment.layoutFragmentFrame.minY,
               localY < fragment.layoutFragmentFrame.minY + row.height,
               row.contentWidth > layout.width + 0.5 {
                hit = row.tableRange
                return false
            }
            return true
        }
        return hit
    }

    @discardableResult
    func setMarkdownTableHorizontalOffset(_ offset: CGFloat, for range: NSRange) -> Bool {
        guard markdownSyntaxCache.setTableHorizontalOffset(offset, for: range) else {
            return false
        }
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
        return true
    }

#if os(macOS)
    func scrollMarkdownTable(with event: NSEvent) -> Bool {
        let shifted = event.modifierFlags.contains(.shift)
        let x = shifted && abs(event.scrollingDeltaX) < 0.01
            ? event.scrollingDeltaY : event.scrollingDeltaX
        guard abs(x) > 0,
              shifted || abs(x) > abs(event.scrollingDeltaY),
              let range = scrollableMarkdownTable(
                at: convert(event.locationInWindow, from: nil)
              ) else { return false }
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
        let previous = markdownSyntaxCache.tableHorizontalOffsets[range, default: 0]
        _ = setMarkdownTableHorizontalOffset(previous - x * scale, for: range)
        return true
    }
#else
    func installMarkdownTableScrolling() {
        guard objc_getAssociatedObject(self, &tablePanControllerKey) == nil else { return }
        let controller = MarkdownTablePanController(textView: self)
        objc_setAssociatedObject(
            self, &tablePanControllerKey, controller, .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }
#endif
}

#if os(iOS)
nonisolated(unsafe) private var tablePanControllerKey: UInt8 = 0

/// Fail promptly for vertical pans so the note keeps its ordinary scrolling.
@MainActor
private final class MarkdownTablePanController: NSObject, UIGestureRecognizerDelegate {
    private weak var textView: MarkdownTextView?
    private var table: NSRange?
    private var initialOffset: CGFloat = 0

    init(textView: MarkdownTextView) {
        self.textView = textView
        super.init()
        let pan = UIPanGestureRecognizer(target: self, action: #selector(scrollTable(_:)))
        pan.maximumNumberOfTouches = 1
        pan.allowedScrollTypesMask = .all
        pan.delegate = self
        textView.addGestureRecognizer(pan)
        textView.panGestureRecognizer.require(toFail: pan)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
              let textView, textView.markedTextRange == nil else { return false }
        let velocity = pan.velocity(in: textView)
        guard abs(velocity.x) > abs(velocity.y) * 1.2 else { return false }
        let point = pan.location(in: textView)
        let translation = pan.translation(in: textView)
        guard let range = textView.scrollableMarkdownTable(
            at: CGPoint(x: point.x - translation.x, y: point.y - translation.y)
        ) else { return false }
        table = range
        initialOffset = textView.markdownSyntaxCache.tableHorizontalOffsets[range, default: 0]
        return true
    }

    @objc private func scrollTable(_ pan: UIPanGestureRecognizer) {
        guard let textView, let table else { return }
        if pan.state == .began || pan.state == .changed || pan.state == .ended {
            _ = textView.setMarkdownTableHorizontalOffset(
                initialOffset - pan.translation(in: textView).x, for: table
            )
        }
        if pan.state == .ended || pan.state == .cancelled || pan.state == .failed {
            self.table = nil
        }
    }
}
#endif
