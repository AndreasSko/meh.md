import XCTest

@testable import NativeEditor

#if os(iOS)
import UIKit

@MainActor
final class MarkdownHeadingGeometryTests: XCTestCase {
    private struct Fragment {
        let range: NSRange
        let frame: CGRect
        let lineRanges: [NSRange]
        let lineBounds: [CGRect]
        let lineOrigins: [CGPoint]
    }

    func testFirstHeadingMinimumPreservesNaturalTypography() throws {
        let sources = [
            "# Short heading\nTail",
            "# " + String(repeating: "A fictional heading with spaces ",
                           count: 5) + "\nTail",
            "# 星 🪐 Café `code` and **bold**\nTail",
        ]
        for size in [13.0, 17.0] {
            for family in [EditorFontFamily.system, .monospaced] {
                for state in 0..<3 {
                    for source in sources {
                        try compareGeometry(source, size: size, family: family,
                                            state: state)
                    }
                }
            }
        }
    }

    private func compareGeometry(_ source: String, size: Double,
                                 family: EditorFontFamily, state: Int) throws {
        let view = MarkdownTextView(usingTextLayoutManager: true)
        view.frame = CGRect(x: 0, y: 0, width: 402, height: 500)
        view.text = source
        let host = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host
        host.view.addSubview(view)
        window.makeKeyAndVisible()
        defer {
            view.resignFirstResponder()
            window.isHidden = true
        }
        XCTAssertTrue(view.becomeFirstResponder())
        view.selectedRange = NSRange(
            location: state == 2 ? 4 : view.textStorage.length, length: 0
        )
        MarkdownPresentation.configure(
            view, fontSize: size, fontFamily: family,
            mode: state == 0 ? .source : .livePreview
        )
        let sourceString = source as NSString
        let paragraph = sourceString.paragraphRange(
            for: NSRange(location: 0, length: 0)
        )
        let style = try XCTUnwrap(view.textStorage.attribute(
            .paragraphStyle, at: 0, effectiveRange: nil
        ) as? NSParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
        let minimum = style.minimumLineHeight
        XCTAssertGreaterThan(minimum, 0)

        // Restore the original implicit minimum, fully materialize both
        // layouts, and compare native baselines, wrapping and following text.
        style.minimumLineHeight = 0
        view.textStorage.addAttribute(.paragraphStyle, value: style,
                                     range: paragraph)
        let original = try fragments(in: view)
        let candidateStyle = style.mutableCopy() as! NSMutableParagraphStyle
        candidateStyle.minimumLineHeight = minimum
        view.textStorage.addAttribute(.paragraphStyle, value: candidateStyle,
                                     range: paragraph)
        let candidate = try fragments(in: view)
        XCTAssertEqual(candidate.count, original.count)
        let tolerance = 1 / window.screen.scale
        for (actual, expected) in zip(candidate, original) {
            XCTAssertEqual(actual.range, expected.range)
            assertRect(actual.frame, expected.frame, tolerance: tolerance)
            XCTAssertEqual(actual.lineRanges, expected.lineRanges)
            XCTAssertEqual(actual.lineBounds.count, expected.lineBounds.count)
            for (actualLine, expectedLine) in zip(actual.lineBounds,
                                                   expected.lineBounds) {
                assertRect(actualLine, expectedLine, tolerance: tolerance)
            }
            for (actualOrigin, expectedOrigin) in zip(actual.lineOrigins,
                                                       expected.lineOrigins) {
                XCTAssertEqual(actualOrigin.x, expectedOrigin.x,
                               accuracy: tolerance)
                XCTAssertEqual(actualOrigin.y, expectedOrigin.y,
                               accuracy: tolerance)
            }
        }
        XCTAssertEqual(view.text, source)
    }

    private func fragments(in view: MarkdownTextView) throws -> [Fragment] {
        view.layoutIfNeeded()
        let manager = try XCTUnwrap(view.textLayoutManager)
        let content = try XCTUnwrap(manager.textContentManager)
        manager.ensureLayout(for: content.documentRange)
        var result: [Fragment] = []
        manager.enumerateTextLayoutFragments(
            from: content.documentRange.location, options: [.ensuresLayout]
        ) { fragment in
            let start = content.offset(from: content.documentRange.location,
                                       to: fragment.rangeInElement.location)
            let end = content.offset(from: content.documentRange.location,
                                     to: fragment.rangeInElement.endLocation)
            result.append(Fragment(
                range: NSRange(location: start, length: end - start),
                frame: fragment.layoutFragmentFrame,
                lineRanges: fragment.textLineFragments.map(\.characterRange),
                lineBounds: fragment.textLineFragments.map(\.typographicBounds),
                lineOrigins: fragment.textLineFragments.map(\.glyphOrigin)
            ))
            return true
        }
        return result
    }

    private func assertRect(_ actual: CGRect, _ expected: CGRect,
                            tolerance: CGFloat,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: tolerance,
                       file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: tolerance,
                       file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: tolerance,
                       file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: tolerance,
                       file: file, line: line)
    }
}
#endif
