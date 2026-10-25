import CoreGraphics
import Foundation
import NoteCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// History's margin marks: a highlighter line beside changed lines and a
/// small ring where lines were removed. Each layout fragment draws its own
/// marks, so they cost nothing outside the visible text.
enum MarkdownHistoryMarks {
    /// The marks' center, left of the text container's origin.
    static let offset: CGFloat = 7
    static let barWidth: CGFloat = 2.5
    static let ringDiameter: CGFloat = 7
    /// Rings are small; taps and clicks get a comfortable target around them.
    static let ringHitSize: CGFloat = 30
    /// The drawing surface must reach the marks left of the text.
    static let surfaceExtension: CGFloat = offset + ringDiameter

    struct Ring: Equatable {
        let removal: NoteHistoryChanges.Removal
        let center: CGPoint
    }

    struct Marks: Equatable {
        var bar: CGRect?
        var rings: [Ring] = []
        var isEmpty: Bool { bar == nil && rings.isEmpty }
    }

    /// Marks in text container coordinates for one fragment.
    static func marks(
        for changes: NoteHistoryChanges,
        fragmentRange: NSRange,
        lineBounds: CGRect,
        textLength: Int
    ) -> Marks {
        var marks = Marks()
        guard !changes.isEmpty else { return marks }
        let start = fragmentRange.location
        let end = NSMaxRange(fragmentRange)
        if changes.changed.contains(where: { range in
            guard range.length == 0 else {
                return NSIntersectionRange(range, fragmentRange).length > 0
            }
            // A line break added at the very end has no fragment of its own;
            // the last line carries its mark.
            return range.location == start || (start ..< end).contains(range.location)
                || (range.location == textLength && end == textLength)
        }) {
            marks.bar = CGRect(
                x: -offset - barWidth / 2, y: lineBounds.minY,
                width: barWidth, height: lineBounds.height
            )
        }
        for removal in changes.removed {
            if removal.location == start {
                marks.rings.append(Ring(
                    removal: removal,
                    center: CGPoint(x: -offset, y: lineBounds.minY - 1)
                ))
            } else if removal.location == textLength, end == textLength,
                      start < textLength {
                marks.rings.append(Ring(
                    removal: removal,
                    center: CGPoint(x: -offset, y: lineBounds.maxY + ringDiameter / 2 + 1)
                ))
            }
        }
        return marks
    }

    /// The fragment's text lines without its paragraph spacing, in container
    /// coordinates.
    static func lineBounds(of fragment: NSTextLayoutFragment) -> CGRect {
        let frame = fragment.layoutFragmentFrame
        let lines = fragment.textLineFragments.reduce(CGRect.null) {
            $0.union($1.typographicBounds)
        }
        guard !lines.isNull else { return frame }
        return lines.offsetBy(dx: frame.minX, dy: frame.minY)
    }

    static func draw(_ marks: Marks, offset: CGPoint, context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        if let bar = marks.bar {
            context.setFillColor(MehStyle.highlighterStroke.cgColor)
            let path = CGPath(
                roundedRect: bar.offsetBy(dx: offset.x, dy: offset.y),
                cornerWidth: barWidth / 2, cornerHeight: barWidth / 2,
                transform: nil
            )
            context.addPath(path)
            context.fillPath()
        }
        guard !marks.rings.isEmpty else { return }
        #if os(macOS)
        let ring = NSColor.secondaryLabelColor.cgColor
        #else
        let ring = UIColor.secondaryLabel.cgColor
        #endif
        context.setStrokeColor(ring)
        context.setLineWidth(1.5)
        for mark in marks.rings {
            let center = CGPoint(x: mark.center.x + offset.x, y: mark.center.y + offset.y)
            context.strokeEllipse(in: CGRect(
                x: center.x - ringDiameter / 2, y: center.y - ringDiameter / 2,
                width: ringDiameter, height: ringDiameter
            ))
        }
    }

    /// The removal ring under a point in text container coordinates, with
    /// its center in the same coordinates.
    static func ring(
        at point: CGPoint,
        changes: NoteHistoryChanges,
        layoutManager: NSTextLayoutManager,
        textLength: Int
    ) -> Ring? {
        guard !changes.removed.isEmpty, point.x < ringHitSize / 2 - offset else { return nil }
        // A ring sits between two fragments; check both around the point.
        for y in [point.y - ringHitSize / 2, point.y, point.y + ringHitSize / 2] {
            guard let fragment = layoutManager.textLayoutFragment(
                for: CGPoint(x: 0, y: max(0, y))
            ), let range = nsRange(of: fragment, in: layoutManager) else { continue }
            let marks = marks(
                for: changes, fragmentRange: range,
                lineBounds: lineBounds(of: fragment), textLength: textLength
            )
            if let ring = marks.rings.first(where: {
                abs($0.center.y - point.y) <= ringHitSize / 2
                    && abs($0.center.x - point.x) <= ringHitSize / 2
            }) {
                return ring
            }
        }
        return nil
    }

    #if os(macOS)
    /// AppKit draws the background in one pass, so walk only the fragments
    /// in the dirty area.
    static func draw(in textView: MarkdownTextView, dirtyRect: CGRect) {
        let changes = textView.markdownHistoryChanges
        guard !changes.isEmpty,
              let layoutManager = textView.textLayoutManager,
              let context = NSGraphicsContext.current?.cgContext else { return }
        let origin = textView.textContainerOrigin
        let length = textView.textStorage?.length ?? 0
        guard let first = layoutManager.textLayoutFragment(for: CGPoint(
            x: 0, y: max(0, dirtyRect.minY - origin.y - ringDiameter)
        )) else { return }
        layoutManager.enumerateTextLayoutFragments(
            from: first.rangeInElement.location, options: [.ensuresLayout]
        ) { fragment in
            if fragment.layoutFragmentFrame.minY + origin.y
                > dirtyRect.maxY + ringDiameter { return false }
            guard let range = nsRange(of: fragment, in: layoutManager) else { return true }
            let marks = marks(
                for: changes, fragmentRange: range,
                lineBounds: lineBounds(of: fragment), textLength: length
            )
            if !marks.isEmpty { draw(marks, offset: origin, context: context) }
            return true
        }
    }
    #else
    /// UIKit draws each fragment on its own; its surface already reaches the
    /// margin while changes are shown.
    static func draw(
        in fragment: NSTextLayoutFragment,
        textView: MarkdownTextView,
        at point: CGPoint,
        context: CGContext
    ) {
        let changes = textView.markdownHistoryChanges
        guard !changes.isEmpty,
              let layoutManager = fragment.textLayoutManager,
              let range = nsRange(of: fragment, in: layoutManager) else { return }
        let marks = marks(
            for: changes, fragmentRange: range,
            lineBounds: lineBounds(of: fragment),
            textLength: textView.textStorage.length
        )
        guard !marks.isEmpty else { return }
        let frame = fragment.layoutFragmentFrame
        draw(marks, offset: CGPoint(
            x: point.x - frame.minX, y: point.y - frame.minY
        ), context: context)
    }
    #endif

    static func nsRange(
        of fragment: NSTextLayoutFragment,
        in layoutManager: NSTextLayoutManager
    ) -> NSRange? {
        guard let contentManager = layoutManager.textContentManager else { return nil }
        let range = fragment.rangeInElement
        let start = contentManager.offset(
            from: contentManager.documentRange.location, to: range.location
        )
        let length = contentManager.offset(from: range.location, to: range.endLocation)
        return NSRange(location: start, length: length)
    }
}
