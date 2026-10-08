#if os(macOS)
import AppKit
import SwiftUI
import XCTest

@testable import NativeEditor

@MainActor
final class MarkdownTitleAccessibilityTests: XCTestCase {
    func testEmbeddedTitleHostIsReachableAndRemovesStaleChildren() async throws {
        _ = NSApplication.shared
        let view = MarkdownTextView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 400)
        )
        let source = "| One | Two |\n| --- | --- |\n| Alpha | Beta |\n\nBody"
        view.string = source
        view.textContainer?.containerSize = NSSize(width: 500, height: 400)
        let selection = (source as NSString).range(of: "Body")
        view.setSelectedRange(selection)
        let window = NSWindow(
            contentRect: view.frame, styleMask: .borderless,
            backing: .buffered, defer: false
        )
        window.contentView = view
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        MarkdownPresentation.configure(view, mode: .livePreview)
        view.updateMarkdownTableScrollOverlays()
        let overlay = try XCTUnwrap(view.markdownTableScrollOverlays.first)
        view.undoManager?.removeAllActions()

        view.updateMarkdownTitle(AnyView(
            TextField("Title", text: .constant("Fictional observatory"), axis: .vertical)
                .accessibilityIdentifier("title-field")
        ), height: 40)
        await settleLayout(view, window: window)
        let titleHost = try XCTUnwrap(view.subviews.compactMap {
            $0 as? NSHostingView<AnyView>
        }.first)
        // SwiftUI materializes its control AX descendants for external clients.
        // The native parent must expose their hosting bridge first. App UI
        // tests separately verify title-field and note-title control identities.
        let titleChildren = NSAccessibility.unignoredChildren(from: [titleHost])
        XCTAssertFalse(titleChildren.isEmpty)
        for child in titleChildren {
            XCTAssertEqual((view.accessibilityChildren() ?? []).filter {
                ($0 as AnyObject) === (child as AnyObject)
            }.count, 1)
        }
        XCTAssertTrue((view.accessibilityChildren() ?? []).contains {
            ($0 as AnyObject) === overlay
        })
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(view.selectedRange(), selection)
        XCTAssertFalse(view.undoManager?.canUndo == true)

        view.updateMarkdownTitle(AnyView(
            Button("Fictional observatory") {}
                .accessibilityIdentifier("note-title")
        ), height: 40)
        await settleLayout(view, window: window)
        XCTAssertTrue(view.subviews.contains { $0 === titleHost })
        for child in NSAccessibility.unignoredChildren(from: [titleHost]) {
            XCTAssertEqual((view.accessibilityChildren() ?? []).filter {
                ($0 as AnyObject) === (child as AnyObject)
            }.count, 1)
        }
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(view.selectedRange(), selection)
        XCTAssertFalse(view.undoManager?.canUndo == true)

        view.updateMarkdownTitle(nil, height: 0)
        await settleLayout(view, window: window)
        XCTAssertFalse(view.subviews.contains { $0 === titleHost })
        for child in titleChildren {
            XCTAssertFalse((view.accessibilityChildren() ?? []).contains {
                ($0 as AnyObject) === (child as AnyObject)
            })
        }
        let overlayMatches = (view.accessibilityChildren() ?? []).filter {
            ($0 as AnyObject) === overlay
        }
        XCTAssertEqual(overlayMatches.count, 1)
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(view.selectedRange(), selection)
        XCTAssertFalse(view.undoManager?.canUndo == true)
    }

    private func settleLayout(_ view: NSView, window: NSWindow) async {
        window.contentView?.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        await Task.yield()
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
    }
}
#endif
