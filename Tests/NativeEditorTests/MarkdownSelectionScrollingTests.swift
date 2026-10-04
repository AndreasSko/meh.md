import XCTest

@testable import NativeEditor

#if os(iOS)
import UIKit

@MainActor
final class MarkdownSelectionScrollingTests: XCTestCase {
    func testAnimatedOffsetCannotMoveRangedSelection() async throws {
        let fixture = try await makeFixture()
        defer { fixture.window.isHidden = true }

        let view = fixture.textView
        let selection = (view.text as NSString).range(of: "Line 3")
        XCTAssertTrue(view.becomeFirstResponder())
        view.selectedRange = selection
        await waitForScrollAnimationToSettle()
        let originalOffset = view.contentOffset
        let requestedOffset = CGPoint(x: 0, y: 240)

        view.setContentOffset(requestedOffset, animated: true)
        await waitForScrollAnimationToSettle()

        XCTAssertEqual(view.contentOffset, originalOffset)
        XCTAssertEqual(view.selectedRange, selection)
    }

    func testExplicitRangeRevealScrollsToDistantSelection() async throws {
        let fixture = try await makeFixture()
        defer { fixture.window.isHidden = true }

        let view = fixture.textView
        let selection = (view.text as NSString).range(of: "Line 240")
        XCTAssertTrue(view.becomeFirstResponder())
        view.selectedRange = selection
        await waitForScrollAnimationToSettle()
        view.setContentOffset(.zero, animated: false)
        XCTAssertEqual(view.contentOffset.y, 0, accuracy: 1)

        view.scrollRangeToVisible(selection)
        await waitForScrollAnimationToSettle()

        XCTAssertGreaterThan(view.contentOffset.y, 100)
        XCTAssertEqual(view.selectedRange, selection)
        let caretEnd = try XCTUnwrap(view.selectedTextRange).end
        XCTAssertTrue(view.bounds.intersects(view.caretRect(for: caretEnd)))
    }

    func testUnanimatedOffsetMovesViewportAndRetainsSelection() async throws {
        let fixture = try await makeFixture()
        defer { fixture.window.isHidden = true }

        let view = fixture.textView
        let selection = (view.text as NSString).range(of: "Line 3")
        view.selectedRange = selection
        await waitForScrollAnimationToSettle()
        let requestedOffset = CGPoint(x: 0, y: 180)

        view.setContentOffset(requestedOffset, animated: false)

        XCTAssertEqual(view.contentOffset.y, requestedOffset.y, accuracy: 1)
        XCTAssertEqual(view.selectedRange, selection)
    }

    func testNestedExplicitScrollScopeEndsAfterOperation() async throws {
        let fixture = try await makeFixture()
        defer { fixture.window.isHidden = true }

        let view = fixture.textView
        let selection = (view.text as NSString).range(of: "Line 3")
        XCTAssertTrue(view.becomeFirstResponder())
        view.selectedRange = selection
        await waitForScrollAnimationToSettle()
        view.setContentOffset(.zero, animated: false)

        view.markdownWithAllowedScrolling {
            view.markdownWithAllowedScrolling {
                UIView.performWithoutAnimation {
                    view.setContentOffset(
                        CGPoint(x: 0, y: 150), animated: true
                    )
                }
            }
        }
        await waitForScrollAnimationToSettle()
        XCTAssertEqual(view.contentOffset.y, 150, accuracy: 1)

        UIView.performWithoutAnimation {
            view.setContentOffset(CGPoint(x: 0, y: 260), animated: true)
        }
        await waitForScrollAnimationToSettle()

        XCTAssertEqual(view.contentOffset.y, 150, accuracy: 1)
        XCTAssertEqual(view.selectedRange, selection)
    }

    func testReplacementAndUndoPreserveTheNativeText() async throws {
        let fixture = try await makeFixture()
        defer { fixture.window.isHidden = true }

        let view = fixture.textView
        let original = view.text!
        let selection = (original as NSString).range(of: "Line 25")
        XCTAssertTrue(view.becomeFirstResponder())
        try XCTUnwrap(view.undoManager).removeAllActions()
        view.selectedRange = selection
        await waitForScrollAnimationToSettle()

        view.insertText("Edited line")

        XCTAssertEqual(view.text, (original as NSString).replacingCharacters(
            in: selection,
            with: "Edited line"
        ))
        XCTAssertEqual(
            view.selectedRange.location,
            selection.location + "Edited line".utf16.count
        )

        try XCTUnwrap(view.undoManager).undo()

        XCTAssertEqual(view.text, original)
    }

    func testCaretSelectionCanScrollWithAnimation() async throws {
        let fixture = try await makeFixture()
        defer { fixture.window.isHidden = true }

        let view = fixture.textView
        XCTAssertTrue(view.becomeFirstResponder())
        view.selectedRange = NSRange(location: 0, length: 0)
        await waitForScrollAnimationToSettle()

        // Disabling UIView animations keeps this native UIScrollView request
        // deterministic while still exercising the animated override path.
        UIView.performWithoutAnimation {
            view.setContentOffset(CGPoint(x: 0, y: 170), animated: true)
        }
        await waitForScrollAnimationToSettle()

        XCTAssertGreaterThan(view.contentOffset.y, 100)
        XCTAssertEqual(view.selectedRange, NSRange(location: 0, length: 0))
    }

    private func makeFixture() async throws -> (
        window: UIWindow,
        host: UIViewController,
        textView: MarkdownTextView
    ) {
        // The package's command-line xctest host does not drive UIKit scroll
        // animations. Run these checks in an application host with a scene.
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else {
            throw XCTSkip("Native scrolling tests require an application host")
        }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        let host = UIViewController()
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        window.rootViewController = host
        host.view.addSubview(textView)
        textView.frame = host.view.bounds
        textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        textView.font = .systemFont(ofSize: 17)
        textView.text = (1...260).map {
            "Line \($0) of a fictional note used for editor scrolling tests."
        }.joined(separator: "\n")
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        textView.layoutIfNeeded()
        if let manager = textView.textLayoutManager,
           let content = manager.textContentManager {
            manager.ensureLayout(for: content.documentRange)
        }
        XCTAssertTrue(textView.window === window)
        XCTAssertTrue(textView.becomeFirstResponder())
        // Keyboard/focus reveals own the viewport during setup. Wait before
        // measuring whether a later selection scroll request can move it.
        await waitForScrollAnimationToSettle()
        return (window, host, textView)
    }

    private func waitForScrollAnimationToSettle() async {
        let settled = expectation(description: "scroll animation settles")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            settled.fulfill()
        }
        await fulfillment(of: [settled], timeout: 1)
    }
}
#endif
