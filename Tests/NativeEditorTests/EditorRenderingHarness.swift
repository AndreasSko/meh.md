import NoteCore
import SwiftUI
import XCTest

@testable import NativeEditor

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// The app's editor in a window of its own, with the few actions the
/// rendering checks need. It only observes geometry TextKit already laid
/// out, so it does not repair what a check is meant to catch.
@MainActor
final class EditorRenderingHarness {
    struct Options {
        var size = CGSize(width: 420, height: 700)
        var fontFamily = EditorFontFamily.system
        var isDark = false
        var mode = MarkdownEditorMode.livePreview
        var historyChanges = NoteHistoryChanges.none
        var timeCalculator = false
        var palette = MehPalette()
    }

    private final class Storage {
        var text: String
        init(_ text: String) { self.text = text }
    }

    private let storage: Storage
    private(set) var options: Options
    let textView: MarkdownTextView
#if os(macOS)
    private let window: NSWindow
    private let host: NSHostingView<MarkdownEditor>
#else
    private let window: UIWindow
    private let host: UIHostingController<MarkdownEditor>
#endif

    var text: String { storage.text }

    init(source: String, options: Options = Options()) throws {
        storage = Storage(source)
        self.options = options
#if os(macOS)
        _ = NSApplication.shared
        window = UnconstrainedWindow(
            contentRect: NSRect(origin: .zero, size: options.size),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: options.isDark ? .darkAqua : .aqua)
        host = NSHostingView(rootView: Self.editor(storage, options))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        textView = try XCTUnwrap(Self.find(in: host), "No editor text view")
        window.makeFirstResponder(textView)
#else
        window = UIWindow(frame: CGRect(origin: .zero, size: options.size))
        window.overrideUserInterfaceStyle = options.isDark ? .dark : .light
        host = UIHostingController(rootView: Self.editor(storage, options))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        textView = try XCTUnwrap(Self.find(in: host.view), "No editor text view")
#endif
        settle()
    }

    func tearDown() {
#if os(macOS)
        window.orderOut(nil)
#else
        window.isHidden = true
#endif
    }

    private static func editor(_ storage: Storage, _ options: Options) -> MarkdownEditor {
        MarkdownEditor(
            text: Binding(get: { storage.text }, set: { storage.text = $0 }),
            fontFamily: options.fontFamily,
            mode: options.mode,
            palette: options.palette,
            historyChanges: options.historyChanges,
            timeCalculator: options.timeCalculator
        )
    }

    /// Shows the editor with other options, as SwiftUI would on a change.
    func update(_ change: (inout Options) -> Void) {
        change(&options)
        host.rootView = Self.editor(storage, options)
        settle()
    }

    /// The lines the screen drew while `body` ran. Each line keeps its last
    /// drawing until the screen asks it to draw anew.
    func linesDrawn(during body: () -> Void) -> Set<ObjectIdentifier> {
        settle()
        var someLine: NSTextLayoutFragment?
        layoutManager.enumerateTextLayoutFragments(
            from: layoutManager.documentRange.location
        ) { someLine = $0; return false }
        guard let someLine, let method = class_getInstanceMethod(
            Swift.type(of: someLine), #selector(NSTextLayoutFragment.draw(at:in:))
        ) else { return [] }
        typealias Draw = @convention(c) (NSTextLayoutFragment, Selector, CGPoint, CGContext) -> Void
        let original = method_getImplementation(method)
        let drawOriginal = unsafeBitCast(original, to: Draw.self)
        let drawn = DrawnLines()
        let counting: @convention(block) (NSTextLayoutFragment, CGPoint, CGContext) -> Void = {
            drawn.lines.insert(ObjectIdentifier($0))
            drawOriginal($0, #selector(NSTextLayoutFragment.draw(at:in:)), $1, $2)
        }
        method_setImplementation(method, imp_implementationWithBlock(counting))
        defer { method_setImplementation(method, original) }
        body()
        settle()
        return drawn.lines
    }

    /// The lines on screen.
    var visibleLines: Set<ObjectIdentifier> {
        var lines = Set<ObjectIdentifier>()
        let origin = containerOrigin
        layoutManager.enumerateTextLayoutFragments(
            from: layoutManager.textViewportLayoutController.viewportRange?.location
                ?? layoutManager.documentRange.location
        ) { fragment in
            let frame = fragment.layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y)
            if frame.minY > visibleRect.maxY { return false }
            if frame.maxY > visibleRect.minY { lines.insert(ObjectIdentifier(fragment)) }
            return true
        }
        return lines
    }

    /// The line that holds `location`.
    func line(at location: Int) -> ObjectIdentifier? {
        guard let manager = layoutManager.textContentManager,
              let position = manager.location(manager.documentRange.location, offsetBy: location),
              let fragment = layoutManager.textLayoutFragment(for: position)
        else { return nil }
        return ObjectIdentifier(fragment)
    }

    /// Replaces source text, as typing over a selection would.
    func replace(_ range: NSRange, with replacement: String) {
#if os(macOS)
        textView.setSelectedRange(range)
        textView.insertText(replacement, replacementRange: range)
#else
        textView.selectedRange = range
        textView.insertText(replacement)
#endif
        settle()
    }

    private final class DrawnLines: @unchecked Sendable {
        var lines = Set<ObjectIdentifier>()
    }

    // MARK: Geometry, in the text view's coordinates

    var layoutManager: NSTextLayoutManager { textView.textLayoutManager! }

    var visibleRect: CGRect {
#if os(macOS)
        textView.visibleRect
#else
        CGRect(origin: textView.contentOffset, size: textView.bounds.size)
#endif
    }

    var containerOrigin: CGPoint {
#if os(macOS)
        textView.textContainerOrigin
#else
        CGPoint(x: textView.textContainerInset.left, y: textView.textContainerInset.top)
#endif
    }

    /// Where lines start and end horizontally.
    var textColumn: ClosedRange<CGFloat> {
        let container = layoutManager.textContainer!
        let left = containerOrigin.x + container.lineFragmentPadding
        return left...(left + container.size.width - 2 * container.lineFragmentPadding)
    }

    /// The source range TextKit has laid out for the viewport.
    var viewportRange: NSRange? {
        guard let viewport = layoutManager.textViewportLayoutController.viewportRange,
              let manager = layoutManager.textContentManager else { return nil }
        let start = manager.offset(from: manager.documentRange.location, to: viewport.location)
        let end = manager.offset(from: manager.documentRange.location, to: viewport.endLocation)
        return NSRange(location: start, length: end - start)
    }

    /// The line around one character, if the viewport has laid it out.
    func lineRect(at location: Int) -> CGRect? {
        guard let viewport = viewportRange,
              NSLocationInRange(location, viewport),
              let manager = layoutManager.textContentManager,
              let start = manager.location(manager.documentRange.location, offsetBy: location),
              let end = manager.location(start, offsetBy: 1),
              let range = NSTextRange(location: start, end: end) else { return nil }
        var rect: CGRect?
        layoutManager.enumerateTextSegments(
            in: range, type: .standard, options: [.rangeNotRequired]
        ) { _, frame, _, _ in
            rect = frame
            return false
        }
        return rect.map { $0.offsetBy(dx: containerOrigin.x, dy: containerOrigin.y) }
    }

    // MARK: Actions

    /// Lets the window lay out and draw, as the app's run loop would.
    func settle() {
        var previous: (CGRect, NSRange?)?
        for attempt in 0..<40 {
#if os(macOS)
            window.layoutIfNeeded()
            window.displayIfNeeded()
#else
            window.layoutIfNeeded()
#endif
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            let current = (visibleRect, viewportRange)
            if attempt >= 2, let previous, previous.0 == current.0, previous.1 == current.1 {
                return
            }
            previous = current
        }
        XCTFail("The layout did not settle")
    }

    func scroll(toY y: CGFloat) {
#if os(macOS)
        let clip = textView.enclosingScrollView!.contentView
        let maximum = max(0, textView.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(max(0, y), maximum)))
        textView.enclosingScrollView!.reflectScrolledClipView(clip)
#else
        let maximum = max(
            -textView.adjustedContentInset.top,
            textView.contentSize.height + textView.adjustedContentInset.bottom
                - textView.bounds.height
        )
        textView.setContentOffset(
            CGPoint(x: textView.contentOffset.x,
                    y: min(max(-textView.adjustedContentInset.top, y), maximum)),
            animated: false
        )
#endif
        settle()
    }

    func scroll(by delta: CGFloat) {
        scroll(toY: visibleRect.minY + delta)
    }

    /// Scrolls to the end, as far as TextKit's estimates allow, until the
    /// last line is laid out; then types there.
    func type(atEnd addition: String) {
        let end = (text as NSString).length
        for _ in 0..<20 {
            scroll(toY: .greatestFiniteMagnitude)
            if let viewport = viewportRange, NSMaxRange(viewport) >= end { break }
        }
#if os(macOS)
        textView.setSelectedRange(NSRange(location: end, length: 0))
        textView.insertText(addition, replacementRange: textView.selectedRange())
#else
        textView.selectedRange = NSRange(location: end, length: 0)
        textView.insertText(addition)
#endif
        settle()
    }

    func resize(width: CGFloat) {
        options.size.width = width
#if os(macOS)
        window.setContentSize(options.size)
#else
        window.frame.size = options.size
#endif
        settle()
    }

    // MARK: Drawing

    /// The visible part of the editor as it draws itself: the view's own
    /// background drawing, then each laid-out line through its fragment.
    func render(scale: CGFloat) -> EditorRenderingImage {
        let visible = visibleRect
        let context = Self.canvas(for: visible, scale: scale)
        var paper = CGColor(gray: 1, alpha: 1)
        withAppearance { paper = MehStyle.paper.cgColor }
        context.setFillColor(paper)
        context.fill(visible)
#if os(macOS)
        withCurrent(context) { textView.drawBackground(in: visible) }
#endif
        withCurrent(context) { drawFragments(in: visible, context: context) }
        return EditorRenderingImage(
            image: context.makeImage()!, origin: visible.origin, scale: scale, paper: paper
        )
    }

    /// Only the line around one character, on a clear background, as the
    /// line draws into its own layer on screen.
    func renderLine(at location: Int, scale: CGFloat) throws -> EditorRenderingImage {
        let visible = visibleRect
        let context = Self.canvas(for: visible, scale: scale)
        let manager = try XCTUnwrap(layoutManager.textContentManager)
        let start = try XCTUnwrap(
            manager.location(manager.documentRange.location, offsetBy: location)
        )
        let fragment = try XCTUnwrap(layoutManager.textLayoutFragment(for: start))
        withCurrent(context) { draw(fragment, in: context) }
        return EditorRenderingImage(
            image: context.makeImage()!, origin: visible.origin, scale: scale,
            paper: CGColor(gray: 0, alpha: 0)
        )
    }

    /// A flipped bitmap in view coordinates, covering `visible`.
    private static func canvas(for visible: CGRect, scale: CGFloat) -> CGContext {
        let width = Int((visible.width * scale).rounded())
        let height = Int((visible.height * scale).rounded())
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -visible.minX, y: -visible.minY)
        return context
    }

    private func withCurrent(_ context: CGContext, _ body: () -> Void) {
#if os(macOS)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        withAppearance(body)
        NSGraphicsContext.restoreGraphicsState()
#else
        UIGraphicsPushContext(context)
        withAppearance(body)
        UIGraphicsPopContext()
#endif
    }

    /// Lines in the last render that drew without the editor's own line
    /// fragment, and so without their decorations.
    private(set) var plainLines = 0

    private func drawFragments(in visible: CGRect, context: CGContext) {
        plainLines = 0
        guard let manager = layoutManager.textContentManager else { return }
        let origin = containerOrigin
        let start = layoutManager.textViewportLayoutController.viewportRange?.location
            ?? manager.documentRange.location
        layoutManager.enumerateTextLayoutFragments(from: start) { fragment in
            let frame = fragment.layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y)
            if frame.minY > visible.maxY { return false }
            if String(describing: Swift.type(of: fragment)) != "MarkdownTextLayoutFragment" {
                plainLines += 1
            }
            draw(fragment, in: context)
            return true
        }
    }

    private func draw(_ fragment: NSTextLayoutFragment, in context: CGContext) {
        let frame = fragment.layoutFragmentFrame.offsetBy(
            dx: containerOrigin.x, dy: containerOrigin.y
        )
        // Each line may only draw inside the surface it reports, as on
        // screen, so a surface too small for its marks shows up here.
        context.saveGState()
        context.clip(to: fragment.renderingSurfaceBounds.offsetBy(dx: frame.minX, dy: frame.minY))
        fragment.draw(at: frame.origin, in: context)
        context.restoreGState()
    }

    private func withAppearance(_ body: () -> Void) {
#if os(macOS)
        textView.effectiveAppearance.performAsCurrentDrawingAppearance(body)
#else
        textView.traitCollection.performAsCurrent(body)
#endif
    }

#if os(macOS)
    private static func find(in view: NSView) -> MarkdownTextView? {
        if let textView = view as? MarkdownTextView { return textView }
        return view.subviews.lazy.compactMap { find(in: $0) }.first
    }
#else
    private static func find(in view: UIView) -> MarkdownTextView? {
        if let textView = view as? MarkdownTextView { return textView }
        return view.subviews.lazy.compactMap { find(in: $0) }.first
    }
#endif
}

#if os(macOS)
/// Keeps the size a test asks for. AppKit shrinks a window to fit its
/// screen, and CI runners have small screens.
private final class UnconstrainedWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
#endif
