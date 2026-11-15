import XCTest

@testable import NativeEditor

#if os(iOS)
import UIKit

@MainActor
final class MarkdownTableRowSpacingTests: XCTestCase {
    /// The hidden `| --- |` line sits between the header and the first row.
    /// It must not leave a visible gap between their drawn boxes.
    /// The note's last fragment also holds the empty line after the final
    /// line break, so a table that ends the note checks its last row too.
    func testHeaderMeetsFirstRow() throws {
        let table = "| Day | What |\n| --- | --- |\n| Thu | Tram |\n| Fri | Belém |\n"
        for (source, size) in [
            ("Before\n\n" + table + "\nAfter", 13.0),
            ("Before\n\n" + table + "\nAfter", 17.0),
            ("Before\n\n" + table + "\nAfter", 24.0),
            ("Before\n\n" + table, 17.0),
        ] {
            let view = MarkdownTextView(usingTextLayoutManager: true)
            view.frame = CGRect(x: 0, y: 0, width: 402, height: 600)
            view.text = source
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
            let host = UIViewController()
            window.rootViewController = host
            host.view.addSubview(view)
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            MarkdownPresentation.configure(
                view, fontSize: size, fontFamily: .system, mode: .livePreview
            )
            view.layoutIfNeeded()
            let manager = try XCTUnwrap(view.textLayoutManager)
            let content = try XCTUnwrap(manager.textContentManager)
            manager.ensureLayout(for: content.documentRange)
            let layout = try XCTUnwrap(
                MarkdownPresentation.syntaxCache(for: view).tableLayout
            )
            XCTAssertEqual(layout.rows.count, 3)

            var frames: [Int: NSTextLayoutFragment] = [:]
            manager.enumerateTextLayoutFragments(
                from: content.documentRange.location, options: [.ensuresLayout]
            ) { fragment in
                let start = content.offset(from: content.documentRange.location,
                                           to: fragment.rangeInElement.location)
                frames[start] = fragment
                return true
            }
            let header = layout.rows[0], first = layout.rows[1], second = layout.rows[2]
            let headerFrame = try XCTUnwrap(frames[header.range.location])
            let firstFrame = try XCTUnwrap(frames[first.range.location])
            let secondFrame = try XCTUnwrap(frames[second.range.location])
            let tolerance = 1 / window.screen.scale
            // Body rows already meet; the header must meet its row the same way.
            let headerTop = MarkdownTableLayout.rowMinY(in: headerFrame, row: header)
            let firstTop = MarkdownTableLayout.rowMinY(in: firstFrame, row: first)
            let secondTop = MarkdownTableLayout.rowMinY(in: secondFrame, row: second)
            XCTAssertEqual(firstTop + first.height, secondTop,
                           accuracy: tolerance, "body rows at \(size) pt")
            XCTAssertEqual(headerTop + header.height, firstTop,
                           accuracy: tolerance, "header at \(size) pt")
            // The gap before the table stays above the header box.
            XCTAssertGreaterThan(headerTop, headerFrame.layoutFragmentFrame.minY,
                                 "gap at \(size) pt")
        }
    }
}
#endif
