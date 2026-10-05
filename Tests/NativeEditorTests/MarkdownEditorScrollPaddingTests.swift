import XCTest

@testable import NativeEditor

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

@MainActor
final class MarkdownEditorScrollPaddingTests: XCTestCase {
    func testShortViewportUsesHalfHeightPadding() {
        XCTAssertEqual(
            MarkdownEditorScrollPadding.bottom(for: 80),
            40
        )
    }

    func testTallViewportLeavesFiniteSpaceBelowText() {
        XCTAssertEqual(
            MarkdownEditorScrollPadding.bottom(for: 600),
            300
        )
    }

    func testPaddingTracksViewportResize() {
        let compact = MarkdownEditorScrollPadding.bottom(for: 300)
        let expanded = MarkdownEditorScrollPadding.bottom(for: 700)

        XCTAssertEqual(expanded - compact, 200)
    }

#if os(macOS)
    func testMountedEditorScrollsLastLineNearMiddleWithFiniteExtent() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let scrollView = MarkdownEditorScrollView(frame: window.contentView!.bounds)
        scrollView.hasVerticalScroller = true
        scrollView.autoresizingMask = [.width, .height]
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        textView.string = (1...80).map { "Line \($0)" }.joined(separator: "\n")
        textView.font = .systemFont(ofSize: 17)
        textView.textContainerInset = NSSize(width: 22, height: 20)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        window.contentView = scrollView
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        window.contentView?.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
        try ensureTextKit2Layout(in: textView)

        XCTAssertEqual(textView.textContainerOrigin.y, 20)
        let firstHeight = textView.frame.height
        XCTAssertGreaterThan(firstHeight, scrollView.contentView.bounds.height)
        try assertLastLinePosition(in: scrollView, textView: textView)

        textView.insertText("\nAnother line", replacementRange: NSRange(
            location: (textView.string as NSString).length,
            length: 0
        ))
        try ensureTextKit2Layout(in: textView)
        scrollView.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(textView.frame.height, firstHeight)
        try assertLastLinePosition(in: scrollView, textView: textView)

        window.setContentSize(NSSize(width: 320, height: 600))
        window.contentView?.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
        try ensureTextKit2Layout(in: textView)

        XCTAssertEqual(textView.textContainerOrigin.y, 20)
        XCTAssertGreaterThan(textView.frame.height, firstHeight)
        try assertLastLinePosition(in: scrollView, textView: textView)
    }

    private func assertLastLinePosition(
        in scrollView: NSScrollView,
        textView: NSTextView
    ) throws {
        let maximumY = max(
            0,
            textView.frame.height - scrollView.contentView.bounds.height
        )
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: maximumY))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        let layoutManager = try XCTUnwrap(textView.textLayoutManager)
        let contentManager = try XCTUnwrap(layoutManager.textContentManager)
        var finalFragment: NSTextLayoutFragment?
        layoutManager.enumerateTextLayoutFragments(
            from: contentManager.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            finalFragment = fragment
            return true
        }
        let finalLineY = try XCTUnwrap(finalFragment).layoutFragmentFrame.minY
            + textView.textContainerOrigin.y
        let lineYInViewport = finalLineY
            - scrollView.contentView.bounds.minY

        XCTAssertEqual(
            lineYInViewport,
            scrollView.contentView.bounds.height / 2,
            accuracy: 40
        )
        XCTAssertLessThanOrEqual(
            scrollView.contentView.bounds.maxY,
            textView.frame.maxY + 0.5
        )
    }

    private func ensureTextKit2Layout(in textView: NSTextView) throws {
        let layoutManager = try XCTUnwrap(textView.textLayoutManager)
        layoutManager.ensureLayout(
            for: try XCTUnwrap(layoutManager.textContentManager).documentRange
        )
    }
#endif

#if os(iOS)
    func testPaddingTracksAccumulatedSmallResizes() {
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        textView.markdownBodyLineHeight = 20
        textView.frame = CGRect(x: 0, y: 0, width: 402, height: 488)
        textView.layoutIfNeeded()
        let initialPadding = textView.markdownScrollPastEndPadding

        for height: CGFloat in [490, 496, 504] {
            textView.frame.size.height = height
            textView.setNeedsLayout()
            textView.layoutIfNeeded()
            XCTAssertEqual(textView.markdownScrollPastEndPadding, initialPadding)
        }

        textView.frame.size.height = 510
        textView.setNeedsLayout()
        textView.layoutIfNeeded()
        XCTAssertEqual(textView.markdownScrollPastEndPadding, 510 / 2)
    }

    func testTopInsetUpdatePreservesSmallBottomResize() {
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        textView.markdownBodyLineHeight = 20
        textView.frame = CGRect(x: 0, y: 0, width: 402, height: 488)
        textView.layoutIfNeeded()
        let initialPadding = textView.markdownScrollPastEndPadding

        // A changed title inset must not also commit suppressed bottom jitter.
        textView.textContainerInset.top = 100
        textView.frame.size.height = 491.667
        textView.setNeedsLayout()
        textView.layoutIfNeeded()
        XCTAssertEqual(textView.textContainerInset.top, 18)
        XCTAssertEqual(textView.markdownScrollPastEndPadding, initialPadding)
    }

    func testBodyLineHeightChangeReevaluatesPaddingTolerance() {
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        textView.markdownBodyLineHeight = 20
        textView.frame = CGRect(x: 0, y: 0, width: 402, height: 488)
        textView.layoutIfNeeded()
        let initialPadding = textView.markdownScrollPastEndPadding
        textView.frame.size.height = 504
        textView.setNeedsLayout()
        textView.layoutIfNeeded()
        XCTAssertEqual(textView.markdownScrollPastEndPadding, initialPadding)

        textView.markdownBodyLineHeight = 10
        textView.layoutIfNeeded()
        XCTAssertEqual(textView.markdownScrollPastEndPadding, 504 / 2)
    }

    func testPaddingToleranceUsesConfiguredBodyFont() {
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        textView.text = "# A large heading\nOrdinary body text"
        textView.selectedRange = NSRange(location: 3, length: 0)

        for size: Double in [13, 28] {
            MarkdownPresentation.configure(
                textView, fontSize: size, fontFamily: .monospaced,
                mode: .livePreview
            )
            let bodyFont = MarkdownPresentation.bodyFont(
                for: .monospaced, pointSize: CGFloat(size)
            )
            XCTAssertEqual(textView.markdownBodyLineHeight, bodyFont.lineHeight)
        }
    }

    func testSmallViewportResizeKeepsNearEndCaretPosition() async throws {
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        let host = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host
        host.view.addSubview(textView)
        textView.frame = CGRect(x: 0, y: 116, width: 402, height: 488)
        textView.contentInsetAdjustmentBehavior = .never

        let precedingLines = (1...504).map { index in
            switch index % 8 {
            case 0: return "## Section \(index)"
            case 1: return "- [ ] Fictional task \(index)"
            case 2: return "- A short item \(index)"
            default:
                return "Paragraph \(index) contains **bold** and ordinary text."
            }
        }
        let target = "Gesture target close to the end"
        let followingLines = (1...8).map { "Final paragraph \($0)" }
        let source = (precedingLines + [target] + followingLines)
            .joined(separator: "\n")
        textView.text = source
        let targetRange = (source as NSString).range(of: target)
        let selection = NSRange(location: NSMaxRange(targetRange), length: 0)
        textView.selectedRange = selection
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        MarkdownPresentation.configure(
            textView, fontSize: 13, fontFamily: .monospaced,
            mode: .livePreview
        )
        host.view.layoutIfNeeded()

        // Reach only the target viewport. Full-document ensureLayout would
        // conceal failures caused by TextKit's estimated document extent.
        textView.scrollRangeToVisible(selection)
        textView.layoutIfNeeded()
        let position = try XCTUnwrap(textView.position(
            from: textView.beginningOfDocument, offset: selection.location
        ))
        // Estimated layout can settle after scrolling. Center using the
        // actual window coordinates, with a bounded correction for setup.
        for _ in 0..<3 {
            let caret = textView.textInputView.convert(
                textView.caretRect(for: position), to: window
            )
            let viewport = textView.convert(textView.bounds, to: window)
            textView.setContentOffset(
                CGPoint(x: textView.contentOffset.x,
                        y: textView.contentOffset.y + caret.midY - viewport.midY),
                animated: false
            )
            textView.layoutIfNeeded()
            await Task.yield()
        }
        let beforeY = textView.textInputView.convert(
            textView.caretRect(for: position), to: window
        ).minY
        XCTAssertGreaterThan(beforeY, textView.frame.minY + 100)
        XCTAssertLessThan(beforeY, textView.frame.maxY - 100)

        // A canceled Home gesture briefly changed the measured editor
        // height by this amount while leaving the keyboard and caret intact.
        for height: CGFloat in [491.667, 488, 491.667, 488] {
            textView.frame.size.height = height
            textView.setNeedsLayout()
            textView.layoutIfNeeded()
            await Task.yield()
            textView.layoutIfNeeded()
            if height == 488 {
                let afterY = textView.textInputView.convert(
                    textView.caretRect(for: position), to: window
                ).minY
                XCTAssertEqual(afterY, beforeY, accuracy: 1)
                XCTAssertEqual(textView.selectedRange, selection)
                XCTAssertEqual(textView.text, source)
            }
        }
    }

    func testKeyboardResizeKeepsPaddingOutOfCaretViewport() {
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        textView.font = .systemFont(ofSize: 17)
        textView.text = (1...200).map { "Line \($0) of the note" }
            .joined(separator: "\n")
        let selection = NSRange(location: 900, length: 0)
        textView.selectedRange = selection

        // Model keyboard appearance and dismissal without depending on
        // the simulator's hardware-keyboard setting.
        for height: CGFloat in [706, 343, 706] {
            textView.frame = CGRect(x: 0, y: 0, width: 390, height: height)
            textView.setNeedsLayout()
            textView.layoutIfNeeded()
            textView.scrollRangeToVisible(selection)

            // UIKit treats scroll insets as obscured space when revealing
            // the caret. Document whitespace must not consume that space.
            XCTAssertEqual(textView.contentInset.bottom, 0)
            XCTAssertEqual(textView.adjustedContentInset.bottom, 0)
            XCTAssertEqual(textView.textContainerInset.bottom, 18)
            XCTAssertEqual(textView.selectedRange, selection)
            let caret = textView.caretRect(for: textView.selectedTextRange!.start)
            XCTAssertGreaterThanOrEqual(caret.minY, textView.bounds.minY - 1)
            XCTAssertLessThanOrEqual(caret.maxY, textView.bounds.maxY + 1)
        }
    }

    func testScrollPastEndSurvivesKeyboardResize() {
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        textView.font = .systemFont(ofSize: 17)
        textView.text = (1...200).map { "Line \($0) of the note" }
            .joined(separator: "\n")

        for height: CGFloat in [706, 343, 706] {
            textView.frame = CGRect(x: 0, y: 0, width: 390, height: height)
            textView.setNeedsLayout()
            textView.layoutIfNeeded()
            if let manager = textView.textLayoutManager,
               let content = manager.textContentManager {
                manager.ensureLayout(for: content.documentRange)
            }
            textView.scrollRangeToVisible(
                NSRange(location: textView.text.utf16.count, length: 0)
            )
            textView.setContentOffset(
                CGPoint(x: 0, y: textView.contentSize.height - height),
                animated: false
            )
            let caret = textView.caretRect(for: textView.endOfDocument)
            let spaceBelowText = textView.bounds.maxY - caret.maxY
            XCTAssertGreaterThanOrEqual(spaceBelowText, height / 2)
            XCTAssertLessThan(spaceBelowText, height)
        }
    }

    func testRotatingLongEditorKeepsLastLineReachable() throws {
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        let host = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        host.view.addSubview(textView)
        textView.frame = host.view.bounds
        textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        textView.font = .systemFont(ofSize: 17)
        textView.text = (1...600).map {
            "Line \($0) has enough text to wrap differently after rotation."
        }.joined(separator: "\n")
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        host.view.layoutIfNeeded()
        let end = NSRange(location: textView.text.utf16.count, length: 0)
        textView.scrollRangeToVisible(end)

        window.frame.size = CGSize(width: 844, height: 390)
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        window.frame.size = CGSize(width: 390, height: 844)
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()

        let insets = textView.adjustedContentInset
        let maximumY = textView.contentSize.height - textView.bounds.height
            + insets.bottom
        textView.setContentOffset(
            CGPoint(x: 0, y: max(-insets.top, maximumY)),
            animated: false
        )
        let caret = textView.caretRect(for: textView.endOfDocument)

        XCTAssertLessThanOrEqual(caret.maxY, textView.bounds.maxY + 1)
        XCTAssertGreaterThanOrEqual(caret.minY, textView.bounds.minY - 1)
        XCTAssertEqual(
            textView.textContainerInset.bottom,
            18
        )
    }

    func testRepeatedLayoutAndResizeDoNotAccumulateEndSpace() throws {
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        let host = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host
        host.view.addSubview(textView)
        textView.frame = CGRect(x: 0, y: 0, width: 402, height: 488)
        textView.font = .systemFont(ofSize: 17)
        textView.text = (1...80).map { "Fictional journal entry \($0)" }
            .joined(separator: "\n")
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let manager = try XCTUnwrap(textView.textLayoutManager)
        let content = try XCTUnwrap(manager.textContentManager)
        // This test checks extent arithmetic after geometry is known, not
        // estimated-layout scrolling (covered by the gesture and UI tests).
        manager.ensureLayout(for: content.documentRange)
        textView.setNeedsLayout()
        textView.layoutIfNeeded()
        let naturalHeight = textView.contentSize.height
            - textView.markdownScrollPastEndPadding

        for height: CGFloat in [488, 488, 706, 343, 488, 488] {
            textView.frame.size.height = height
            for _ in 0..<3 {
                textView.setNeedsLayout()
                textView.layoutIfNeeded()
                XCTAssertEqual(textView.textContainerInset.bottom, 18)
                XCTAssertEqual(
                    textView.contentSize.height - textView.markdownScrollPastEndPadding,
                    naturalHeight, accuracy: 1,
                    "Repeated layout must add optional end space exactly once"
                )
            }
        }
    }
#endif
}
