import XCTest

@testable import NativeEditor

#if os(macOS)
import AppKit

@MainActor
final class EditorLineWidthTests: XCTestCase {
    func testResizingKeepsTextCenteredAtTheLineWidth() throws {
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        textView.textContainerInset = NSSize(width: 22, height: 20)
        textView.textContainer?.lineFragmentPadding = 4
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.string = "A short note."
        textView.setFrameSize(NSSize(width: 400, height: 400))
        let maxTextWidth = EditorLineWidth.standard.maxTextWidth(
            fontSize: 17, fontFamily: .system
        )
        textView.markdownMaxTextWidth = maxTextWidth

        // Short notes keep their height, so no later resize repairs the inset.
        for width: CGFloat in [500, 700, 1400, 600, 400] {
            textView.setFrameSize(NSSize(width: width, height: 400))
            let margin = EditorTextMargin.horizontal(
                width: width, maxTextWidth: maxTextWidth
            )
            XCTAssertEqual(textView.textContainerInset.width, margin - 4,
                           "inset at \(width)")
            let container = try XCTUnwrap(textView.textContainer)
            XCTAssertEqual(container.size.width, width - 2 * (margin - 4),
                           accuracy: 0.5, "container at \(width)")
        }
    }
}
#endif
