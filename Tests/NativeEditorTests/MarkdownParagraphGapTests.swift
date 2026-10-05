import XCTest

@testable import NativeEditor

#if os(iOS)
import UIKit

@MainActor
final class MarkdownParagraphGapTests: XCTestCase {
    func testMixedParagraphsKeepTheirOriginalDistancesAndMetrics() throws {
        let view = editor("Body\n# Heading\n- Item\n- [ ] Task\n> Quote\nTail")
        let styles = try paragraphStyles(in: view)
        // Original previous.after + current.before at each boundary.
        let gaps: [CGFloat] = [0, 16.8, 5.25, 3, 8.25, 4.5]
        XCTAssertEqual(styles.count, gaps.count)
        for (style, gap) in zip(styles, gaps) {
            XCTAssertEqual(style.paragraphSpacingBefore, gap, accuracy: 0.001)
        }
        for style in styles.dropLast() {
            XCTAssertEqual(style.paragraphSpacing, 0)
        }
        XCTAssertEqual(try XCTUnwrap(styles.last).paragraphSpacing,
                       6.3, accuracy: 0.001)
        XCTAssertEqual(styles[0].lineSpacing, 1.8, accuracy: 0.001)
        XCTAssertEqual(styles[1].lineSpacing, 0)
        XCTAssertGreaterThan(styles[2].headIndent, 0)
        XCTAssertEqual(styles[2].firstLineHeadIndent, 0)
        XCTAssertGreaterThan(styles[4].headIndent, 0)
        XCTAssertEqual(view.text,
                       "Body\n# Heading\n- Item\n- [ ] Task\n> Quote\nTail")
    }

    func testRefreshAndCaretChangesDoNotAccumulateParagraphGaps() throws {
        let view = editor("Body\n# Heading\n- Item\nTail")
        let expected = try paragraphStyles(in: view)
        for offset in [0, 8, 18, view.textStorage.length, 0] {
            view.selectedRange = NSRange(location: offset, length: 0)
            refresh(view)
            XCTAssertEqual(try paragraphStyles(in: view), expected)
        }
    }

    func testChangingPreviousRoleRefreshesFollowingParagraph() throws {
        let view = editor("Body\nPlain\nFollowing\nUnchanged")
        let original = try paragraphStyles(in: view)
        view.textStorage.replaceCharacters(
            in: NSRange(location: 5, length: 0), with: "# "
        )
        refresh(view)
        let updated = try paragraphStyles(in: view)
        XCTAssertNotEqual(updated[2], original[2])
        XCTAssertEqual(updated[2].paragraphSpacingBefore, 5.25,
                       accuracy: 0.001)
        XCTAssertEqual(updated[3], original[3])
        XCTAssertEqual(updated, try paragraphStyles(in: editor(view.text)))

        // Deleting the heading also changes the preceding gap of its neighbor.
        view.textStorage.replaceCharacters(
            in: (view.text as NSString).range(of: "# Plain\n"), with: ""
        )
        refresh(view)
        XCTAssertEqual(try paragraphStyles(in: view),
                       try paragraphStyles(in: editor(view.text)))
    }

    func testEmptyEndGapTransfersWhenTextIsInserted() throws {
        let fixtures: [(String, CGFloat)] = [
            ("Body\n", 6.3), ("- Item\n", 3), ("", 0),
        ]
        for (source, gap) in fixtures {
            let view = editor(source)
            view.selectedRange = NSRange(location: view.textStorage.length,
                                        length: 0)
            refresh(view)
            let style = try XCTUnwrap(view.typingAttributes[.paragraphStyle]
                as? NSParagraphStyle)
            XCTAssertEqual(style.paragraphSpacingBefore, 0)
            if !source.isEmpty {
                let previous = try XCTUnwrap(paragraphStyles(in: view).last)
                XCTAssertEqual(previous.paragraphSpacing
                    + style.paragraphSpacingBefore, gap, accuracy: 0.001)
            }
            view.insertText("New end")
            refresh(view)
            XCTAssertEqual(try paragraphStyles(in: view),
                           try paragraphStyles(in: editor(view.text)))
            view.insertText("\n")
            refresh(view)
            XCTAssertEqual(try paragraphStyles(in: view),
                           try paragraphStyles(in: editor(view.text)))
            for _ in 0..<8 {
                view.deleteBackward()
                refresh(view)
                XCTAssertEqual(try paragraphStyles(in: view),
                               try paragraphStyles(in: editor(view.text)))
            }
            XCTAssertEqual(view.text, source)
            let restored = try XCTUnwrap(view.typingAttributes[.paragraphStyle]
                as? NSParagraphStyle)
            XCTAssertEqual(restored.paragraphSpacingBefore, 0)
        }
    }

    func testRenderedTablesRetainTheirFixedRowMetrics() throws {
        let view = editor("Body\n| A | B |\n|---|---|\n| one | two |\n\nTail")
        let layout = try XCTUnwrap(view.markdownSyntaxCache.tableLayout)
        XCTAssertEqual(layout.rows.count, 2)
        for row in layout.rows {
            let style = try XCTUnwrap(view.textStorage.attribute(
                .paragraphStyle, at: row.range.location, effectiveRange: nil
            ) as? NSParagraphStyle)
            XCTAssertEqual(style.minimumLineHeight, row.height)
            XCTAssertEqual(style.maximumLineHeight, row.height)
            XCTAssertEqual(style.lineSpacing, 0)
            XCTAssertEqual(style.paragraphSpacing, 0)
        }
        let styles = try paragraphStyles(in: view)
        XCTAssertEqual(styles[1].paragraphSpacingBefore, 6.3, accuracy: 0.001)
        XCTAssertEqual(styles[4].paragraphSpacingBefore, 0)
        XCTAssertEqual(try XCTUnwrap(styles.last).paragraphSpacingBefore,
                       6.3, accuracy: 0.001)
    }

    func testTypingAfterTasksWithNativeParagraphSeparators() throws {
        for separator in ["\r", "\u{2029}"] {
            let view = editor("- [ ] Task" + separator + "More\nTail")
            view.selectedRange = NSRange(location: view.textStorage.length,
                                        length: 0)
            refresh(view)
            let style = try XCTUnwrap(view.typingAttributes[.paragraphStyle]
                as? NSParagraphStyle)
            let stored = try XCTUnwrap(paragraphStyles(in: view).last)
            XCTAssertEqual(style.paragraphSpacingBefore,
                           stored.paragraphSpacingBefore)
        }
    }

    func testRenderedTableGeometryMatchesOriginalGapOwnership() throws {
        let source = "Body\n| A | B |\n|---|---|\n| one | two |\n\nTail"
        let view = editor(source)
        let original = editor(source)
        for width: CGFloat in [402, 320] {
            for candidate in [view, original] {
                candidate.frame.size.width = width
                candidate.textContainer.size.width = width
                refresh(candidate)
            }
            let body = (source as NSString).paragraphRange(
                for: NSRange(location: 0, length: 0)
            )
            let bodyStyle = try XCTUnwrap(original.textStorage.attribute(
                .paragraphStyle, at: 0, effectiveRange: nil
            ) as? NSParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
            bodyStyle.paragraphSpacing = 6.3
            original.textStorage.addAttribute(.paragraphStyle,
                                             value: bodyStyle, range: body)
            let row = try XCTUnwrap(original.markdownSyntaxCache.tableLayout?
                .rows.first)
            let rowStyle = try XCTUnwrap(original.textStorage.attribute(
                .paragraphStyle, at: row.range.location, effectiveRange: nil
            ) as? NSParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
            rowStyle.paragraphSpacingBefore = 0
            original.textStorage.addAttribute(.paragraphStyle,
                                             value: rowStyle, range: row.range)
            var frames: [[CGRect]] = []
            for candidate in [view, original] {
                let manager = try XCTUnwrap(candidate.textLayoutManager)
                let content = try XCTUnwrap(manager.textContentManager)
                manager.ensureLayout(for: content.documentRange)
                candidate.updateMarkdownTableScrollOverlays()
                let overlay = try XCTUnwrap(candidate.markdownTableScrollOverlays
                    .first)
                frames.append(overlay.rowFrames.map {
                    $0.offsetBy(dx: overlay.frame.minX, dy: overlay.frame.minY)
                })
            }
            XCTAssertEqual(frames[0].count, frames[1].count)
            for (actual, expected) in zip(frames[0], frames[1]) {
                XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.01)
                XCTAssertEqual(actual.height, expected.height, accuracy: 0.01)
            }
            // The concealed Markdown delimiter has its own native extent.
            // Preserve the existing inter-row distance, including that gap.
            XCTAssertEqual(frames[0][1].minY - frames[0][0].maxY,
                           frames[1][1].minY - frames[1][0].maxY,
                           accuracy: 0.01)
        }
    }

    func testEmptyEndCaretKeepsNativePositionWhenTypingStarts() throws {
        let fixtures: [(String, CGFloat)] = [
            ("Body\n", 6.3), ("- Item\n", 3), ("- [ ] Task\n", 8.25),
        ]
        for (source, gap) in fixtures {
            let view = editor(source)
            // Compare with UIKit using the original trailing paragraph gap.
            // Native empty-line and first-glyph line metrics may differ;
            // redistributing a gap must not add movement beyond that.
            let native = UITextView(usingTextLayoutManager: true)
            native.frame = view.frame
            native.font = view.font
            let original = NSMutableAttributedString(
                attributedString: view.textStorage
            )
            let style = try XCTUnwrap(original.attribute(
                .paragraphStyle, at: 0, effectiveRange: nil
            ) as? NSParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
            style.paragraphSpacing = gap
            original.addAttribute(.paragraphStyle, value: style,
                                  range: NSRange(location: 0,
                                                 length: original.length))
            native.attributedText = original
            native.typingAttributes = view.typingAttributes
            let nativeMovement = try caretMovement(in: native) {}
            let movement = try caretMovement(in: view) { self.refresh(view) }
            XCTAssertEqual(movement, nativeMovement, accuracy: 1)
        }
    }

    private func caretMovement(in view: UITextView,
                               refresh: () -> Void) throws -> CGFloat {
        let host = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0,
                                            width: 402, height: 874))
        window.rootViewController = host
        host.view.addSubview(view)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        XCTAssertTrue(view.becomeFirstResponder())
        view.selectedRange = NSRange(location: view.textStorage.length,
                                    length: 0)
        refresh()
        view.layoutIfNeeded()
        let manager = try XCTUnwrap(view.textLayoutManager)
        let content = try XCTUnwrap(manager.textContentManager)
        manager.ensureLayout(for: content.documentRange)
        let before = view.caretRect(for: view.endOfDocument)
        view.insertText("x")
        refresh()
        view.layoutIfNeeded()
        manager.ensureLayout(for: content.documentRange)
        let after = view.caretRect(for: view.endOfDocument)
        XCTAssertGreaterThan(before.height, 0)
        return after.minY - before.minY
    }

    func testIncrementalSplitsAndMergesMatchFreshLayout() throws {
        for mode in [MarkdownEditorMode.source, .livePreview] {
            for initial in [
                "\n\nCafé 🪐\n- [ ] Item\nTail\n",
                "Body\r\n# Heading\r\n- Item\r\nTail",
                "Body\r# Heading\rTail",
                "Body\u{2029}Other\nTail",
            ] {
                let view = editor(initial, mode: mode)
                let insertion = (initial as NSString).range(of: "Tail").location
                view.textStorage.replaceCharacters(
                    in: NSRange(location: insertion, length: 0), with: "New\n"
                )
                refresh(view, mode: mode)
                XCTAssertEqual(try paragraphStyles(in: view),
                               try paragraphStyles(in: editor(view.text,
                                                             mode: mode)))
                view.textStorage.replaceCharacters(
                    in: NSRange(location: insertion - 1, length: 1), with: ""
                )
                refresh(view, mode: mode)
                XCTAssertEqual(try paragraphStyles(in: view),
                               try paragraphStyles(in: editor(view.text,
                                                             mode: mode)))
            }
        }
    }

    private func editor(_ source: String,
                        mode: MarkdownEditorMode = .livePreview)
        -> MarkdownTextView {
        let view = MarkdownTextView(usingTextLayoutManager: true)
        view.frame = CGRect(x: 0, y: 0, width: 402, height: 500)
        view.text = source
        MarkdownPresentation.configure(view, fontSize: 15,
                                       fontFamily: .monospaced,
                                       mode: mode)
        return view
    }

    private func refresh(_ view: MarkdownTextView,
                         mode: MarkdownEditorMode = .livePreview) {
        MarkdownPresentation.refresh(view, fontSize: 15,
                                     fontFamily: .monospaced,
                                     mode: mode)
    }

    private func paragraphStyles(in view: MarkdownTextView) throws
        -> [NSParagraphStyle] {
        let source = view.textStorage.string as NSString
        var styles: [NSParagraphStyle] = []
        var cursor = 0
        while cursor < source.length {
            let paragraph = source.paragraphRange(for: NSRange(
                location: cursor, length: 0
            ))
            styles.append(try XCTUnwrap(view.textStorage.attribute(
                .paragraphStyle, at: cursor, effectiveRange: nil
            ) as? NSParagraphStyle))
            cursor = NSMaxRange(paragraph)
        }
        return styles
    }
}
#endif
