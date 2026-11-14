import Foundation
import XCTest

@testable import NativeEditor

#if os(iOS)
import UIKit

@MainActor
final class MarkdownLinkPointerTests: XCTestCase {
    func testPassiveLinkPointerFollowsNavigationAndEditingAvailability() throws {
        for link in ["[[Target.md|label]]", "[label](Target.md)", "[[label]]"] {
            let source = link + "\n\nOutside"
            let fixture = makeTextView(source: source)
            defer { fixture.window.isHidden = true }
            let view = fixture.view
            let navigation = MarkdownEditorNavigation()
            view.markdownLinkNavigation = navigation
            let point = try labelPoints("label", in: view)[0]
            XCTAssertNil(view.noteLinkPointerRegion(at: point))

            // The notebook attaches activation after the native view appears.
            navigation.openLink = { _ in }
            let region = try XCTUnwrap(view.noteLinkPointerRegion(at: point))
            XCTAssertTrue(region.rect.contains(point))
            let interaction = try XCTUnwrap(view.interactions.compactMap {
                $0 as? UIPointerInteraction
            }.first { $0.delegate === view })
            XCTAssertNotNil(view.pointerInteraction(interaction, styleFor: region))
            XCTAssertNil(view.noteLinkPointerRegion(at: point, modifiers: .shift))
            XCTAssertNil(view.noteLinkPointerRegion(at: CGPoint(x: view.bounds.maxX - 1,
                                                               y: point.y)))

            XCTAssertTrue(view.becomeFirstResponder())
            XCTAssertNil(view.noteLinkPointerRegion(at: point))
            XCTAssertNil(view.pointerInteraction(interaction, styleFor: region))
            XCTAssertTrue(view.resignFirstResponder())
            XCTAssertNotNil(view.noteLinkPointerRegion(at: point))

            MarkdownPresentation.configure(view, mode: .source)
            view.layoutIfNeeded()
            XCTAssertNil(view.noteLinkPointerRegion(at: try labelPoints("label", in: view)[0]))
            MarkdownPresentation.configure(view, mode: .livePreview)
            view.layoutIfNeeded()
            navigation.openLink = nil
            XCTAssertNil(view.noteLinkPointerRegion(at: try labelPoints("label", in: view)[0]))
        }
    }

    func testLinkHighlightKeepsTheNoteVisible() throws {
        let fixture = makeTextView(source: "Intro\n\n[[Target.md|label]]\n\nOutside")
        defer { fixture.window.isHidden = true }
        let view = fixture.view
        let navigation = MarkdownEditorNavigation()
        navigation.openLink = { _ in }
        view.markdownLinkNavigation = navigation
        let region = try XCTUnwrap(view.noteLinkPointerRegion(
            at: try labelPoints("label", in: view)[0]))
        // Previewing the editor itself made the whole note disappear while
        // the pointer rested on the link.
        let preview = view.noteLinkPointerPreview(for: region.rect)
        XCTAssertFalse(preview.view === view)
        XCTAssertFalse(view.isDescendant(of: preview.view))
        XCTAssertEqual(preview.size.width, region.rect.width, accuracy: 0.5)
        XCTAssertEqual(preview.size.height, region.rect.height, accuracy: 0.5)
        XCTAssertTrue(preview.target.container === view)
        XCTAssertEqual(preview.target.center.x, region.rect.midX, accuracy: 0.5)
        XCTAssertEqual(preview.target.center.y, region.rect.midY, accuracy: 0.5)
    }

    func testLayoutRefreshesLinkRegionsOnlyWhenTheyCanMove() throws {
        let source = "Intro\n\n[[Target.md|label]]\n\nOutside"
        let fixture = makeTextView(source: source)
        defer { fixture.window.isHidden = true }
        let view = fixture.view
        let navigation = MarkdownEditorNavigation()
        navigation.openLink = { _ in }
        view.markdownLinkNavigation = navigation
        view.layoutIfNeeded()

        // Showing the highlight adds its preview to the editor. Refreshing
        // the regions on that layout restarted the highlight endlessly.
        var refreshes = view.markdownLinkPointerRefreshes
        for _ in 0..<3 {
            let preview = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 20))
            view.addSubview(preview)
            view.layoutIfNeeded()
            preview.removeFromSuperview()
            view.layoutIfNeeded()
        }
        XCTAssertEqual(view.markdownLinkPointerRefreshes, refreshes)

        view.frame.size.width -= 40
        view.layoutIfNeeded()
        XCTAssertGreaterThan(view.markdownLinkPointerRefreshes, refreshes)

        // Synced text of the same length can still move the link.
        refreshes = view.markdownLinkPointerRefreshes
        view.textStorage.replaceCharacters(
            in: NSRange(location: 0, length: (source as NSString).length),
            with: "Intra\n\n[[Target.md|label]]\n\nOutside")
        XCTAssertGreaterThan(view.markdownLinkPointerRefreshes, refreshes)
    }

    func testTextWidthChangeRefreshesLinkRegionsWithoutResizing() throws {
        let fixture = makeTextView(
            source: "Intro\n\n[[Target.md|label]]\n\nOutside", width: 1024)
        defer { fixture.window.isHidden = true }
        let view = fixture.view
        let navigation = MarkdownEditorNavigation()
        navigation.openLink = { _ in }
        view.markdownLinkNavigation = navigation
        view.markdownMaxTextWidth = 800
        view.layoutIfNeeded()

        let bounds = view.bounds
        let contentSize = view.contentSize
        let insets = view.textContainerInset
        let point = try labelPoints("label", in: view)[0]
        let refreshes = view.markdownLinkPointerRefreshes

        view.markdownMaxTextWidth = 600
        view.layoutIfNeeded()

        XCTAssertEqual(view.bounds, bounds)
        XCTAssertEqual(view.contentSize, contentSize)
        XCTAssertNotEqual(view.textContainerInset, insets)
        let movedPoint = try labelPoints("label", in: view)[0]
        XCTAssertNotEqual(movedPoint.x, point.x)
        XCTAssertNotNil(view.noteLinkPointerRegion(at: movedPoint))
        XCTAssertGreaterThan(view.markdownLinkPointerRefreshes, refreshes)

        let settledRefreshes = view.markdownLinkPointerRefreshes
        view.setNeedsLayout()
        view.layoutIfNeeded()
        XCTAssertEqual(view.markdownLinkPointerRefreshes, settledRefreshes)
    }

    func testWrappedLabelsUseSeparatePointerRegionsWithoutBlankLineTargets() throws {
        let label = "A fictional observatory project with a long label across several lines"
        let fixture = makeTextView(source: "[\(label)](Target.md)\n\nOutside", width: 160)
        defer { fixture.window.isHidden = true }
        let navigation = MarkdownEditorNavigation()
        navigation.openLink = { _ in }
        fixture.view.markdownLinkNavigation = navigation
        let points = try labelPoints(label, in: fixture.view)
        XCTAssertGreaterThan(points.count, 1)
        var regions: [CGRect] = []
        for point in points {
            regions.append(try XCTUnwrap(fixture.view.noteLinkPointerRegion(at: point)).rect)
        }
        XCTAssertEqual(Set(regions.map(\.midY)).count, regions.count)
        for region in regions {
            XCTAssertNil(fixture.view.noteLinkPointerRegion(at: CGPoint(
                x: fixture.view.bounds.maxX - 1, y: region.midY)))
        }
    }

    func testEmbedsAndCodeDoNotAdvertiseLinkActivation() throws {
        let fixture = makeTextView(source: "![[Embedded]]\n`[[Code]]`\n\nOutside")
        defer { fixture.window.isHidden = true }
        let navigation = MarkdownEditorNavigation()
        navigation.openLink = { _ in }
        fixture.view.markdownLinkNavigation = navigation
        for label in ["Embedded", "Code"] {
            for point in try labelPoints(label, in: fixture.view) {
                XCTAssertNil(fixture.view.noteLinkPointerRegion(at: point))
            }
        }
    }

    private func labelPoints(_ label: String, in view: MarkdownTextView) throws -> [CGPoint] {
        let labelRange = (view.text as NSString).range(of: label)
        let start = try XCTUnwrap(view.position(from: view.beginningOfDocument,
                                              offset: labelRange.location))
        let end = try XCTUnwrap(view.position(from: start, offset: labelRange.length))
        let range = try XCTUnwrap(view.textRange(from: start, to: end))
        let rects = view.selectionRects(for: range).map(\.rect).filter {
            $0.width > 1 && $0.height > 0
        }
        XCTAssertFalse(rects.isEmpty)
        return rects.map { CGPoint(x: $0.midX, y: $0.midY) }
    }

    private func makeTextView(source: String, width: CGFloat = 360)
        -> (view: MarkdownTextView, window: UIWindow) {
        let view = MarkdownTextView(usingTextLayoutManager: true)
        view.frame = CGRect(x: 0, y: 0, width: width, height: 320)
        view.isEditable = true
        view.isSelectable = true
        view.text = source
        view.selectedRange = (source as NSString).range(of: "Outside")
        let controller = UIViewController()
        let window = UIWindow(frame: view.frame)
        window.rootViewController = controller
        controller.view.addSubview(view)
        window.makeKeyAndVisible()
        MarkdownPresentation.configure(view, mode: .livePreview)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        return (view, window)
    }
}
#endif
