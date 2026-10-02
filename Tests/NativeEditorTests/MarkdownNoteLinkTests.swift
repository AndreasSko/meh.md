import Foundation
import SwiftUI
import XCTest

@testable import NativeEditor

#if os(macOS)
import AppKit

@MainActor
final class MarkdownNoteLinkTests: XCTestCase {
    func testReusedNativeViewAttachesReplacementNavigation() throws {
        let source = "Connect [["
        let fixture = makeTextView(source: source)
        defer { fixture.window.orderOut(nil) }
        let original = MarkdownEditorNavigation()
        let editor = MarkdownEditor(text: .constant(source), navigation: original)
        let coordinator = editor.makeCoordinator()
        coordinator.attachNavigation(to: fixture.view)
        let replacement = MarkdownEditorNavigation()
        XCTAssertNil(replacement.insertLink)

        coordinator.update(parent: MarkdownEditor(
            text: .constant(source), navigation: replacement
        ), textView: fixture.view)

        XCTAssertTrue(fixture.view.markdownLinkNavigation === replacement)
        let insert = try XCTUnwrap(replacement.insertLink)
        XCTAssertTrue(insert(.init(
            range: NSRange(location: 8, length: 2), replacement: "[[Project]]",
            selection: NSRange(location: 19, length: 0)
        ), source))
        XCTAssertEqual(fixture.view.string, "Connect [[Project]]")
    }

    func testHoverEventsUpdateCursorWhenLinkActivationArrivesAfterAttachment() throws {
        let source = "[[planet.md|label]]\nOutside"
        let fixture = makeTextView(source: source)
        let view = fixture.view
        defer { fixture.window.orderOut(nil); NSCursor.arrow.set() }
        view.setSelectedRange((source as NSString).range(of: "Outside"))
        MarkdownPresentation.configure(view, mode: .livePreview)
        let navigation = MarkdownEditorNavigation()
        view.markdownLinkNavigation = navigation
        view.updateTrackingAreas()
        XCTAssertTrue(view.trackingAreas.contains {
            $0.owner as? MarkdownTextView === view
                && $0.options.contains([.cursorUpdate, .mouseMoved, .inVisibleRect])
        })
        let point = linkLabelPoint(in: view, source: source)
        let hover = try mouseMovedEvent(at: point, in: view)
        let cursorHover = try cursorUpdateEvent(at: point, in: view)
        NSCursor.iBeam.set()
        view.cursorUpdate(with: cursorHover)
        XCTAssertEqual(NSCursor.current, .iBeam)

        // NotebookView installs this callback asynchronously, after the native
        // editor is already attached. Hover must work without a click or edit.
        navigation.openLink = { _ in }
        view.cursorUpdate(with: cursorHover)
        XCTAssertEqual(NSCursor.current, .pointingHand)
        view.mouseMoved(with: try mouseMovedEvent(at: NSPoint(x: 330, y: point.y), in: view))
        XCTAssertEqual(NSCursor.current, .iBeam)
        view.mouseMoved(with: hover)
        XCTAssertEqual(NSCursor.current, .pointingHand)
        view.mouseMoved(with: try mouseMovedEvent(at: point, in: view, modifiers: .shift))
        XCTAssertEqual(NSCursor.current, .iBeam)

        MarkdownPresentation.configure(view, mode: .source)
        fixture.window.resetCursorRects()
        let rawPoint = linkLabelPoint(in: view, source: source)
        view.mouseMoved(with: try mouseMovedEvent(at: rawPoint, in: view))
        XCTAssertEqual(NSCursor.current, .iBeam)
        view.cursorUpdate(with: try cursorUpdateEvent(at: rawPoint, in: view, modifiers: .command))
        XCTAssertEqual(NSCursor.current, .pointingHand)
        navigation.openLink = nil
        view.cursorUpdate(with: try cursorUpdateEvent(at: rawPoint, in: view, modifiers: .command))
        XCTAssertEqual(NSCursor.current, .iBeam)
    }

    private func cursorUpdateEvent(
        at point: NSPoint, in view: MarkdownTextView,
        modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        let window = try XCTUnwrap(view.window)
        return try XCTUnwrap(NSEvent.enterExitEvent(
            with: .cursorUpdate, location: view.convert(point, to: nil),
            modifierFlags: modifiers, timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, trackingNumber: 0, userData: nil
        ))
    }

    private func mouseMovedEvent(
        at point: NSPoint, in view: MarkdownTextView,
        modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        let window = try XCTUnwrap(view.window)
        return try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved, location: view.convert(point, to: nil),
            modifierFlags: modifiers, timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 0, pressure: 0
        ))
    }

    func testArrowKeysChooseThirdSuggestionWithoutMovingCaret() throws {
        let fixture = makeTextView(source: "Connect [[")
        let view = fixture.view
        defer { fixture.window.orderOut(nil) }
        let navigation = MarkdownEditorNavigation()
        view.markdownLinkNavigation = navigation
        navigation.hasLinkCompletion = true
        view.setSelectedRange(NSRange(location: 10, length: 0))
        let caret = view.selectedRange()
        var selection = 0
        navigation.completionCommand = { command in
            switch command {
            case "next": selection = min(2, selection + 1)
            case "previous": selection = max(0, selection - 1)
            case "accept":
                let name = ["Alpha", "Beta", "Gamma"][selection]
                let replacement = "[[\(name)]]"
                return view.insertNoteLink(.init(
                    range: NSRange(location: 8, length: 2),
                    replacement: replacement,
                    selection: NSRange(location: 8 + replacement.utf16.count, length: 0)
                ), expected: "Connect [[")
            case "dismiss": navigation.hasLinkCompletion = false
            default: return false
            }
            return true
        }

        view.keyDown(with: try keyEvent(124, in: fixture.window)) // Right
        view.keyDown(with: try keyEvent(125, in: fixture.window)) // Down
        XCTAssertEqual(selection, 2)
        XCTAssertEqual(view.selectedRange(), caret)
        XCTAssertEqual(view.string, "Connect [[")
        view.keyDown(with: try keyEvent(123, in: fixture.window)) // Left
        view.keyDown(with: try keyEvent(126, in: fixture.window)) // Up
        XCTAssertEqual(selection, 0)
        XCTAssertEqual(view.selectedRange(), caret)
        view.keyDown(with: try keyEvent(125, in: fixture.window))
        view.keyDown(with: try keyEvent(125, in: fixture.window))
        view.keyDown(with: try keyEvent(36, in: fixture.window, characters: "\r"))
        XCTAssertEqual(view.string, "Connect [[Gamma]]")
        view.keyDown(with: try keyEvent(53, in: fixture.window, characters: "\u{1B}"))
        XCTAssertFalse(navigation.hasLinkCompletion)
    }

    func testModifiedArrowsRemainAvailableForTextSelection() throws {
        let fixture = makeTextView(source: "Connect [[")
        defer { fixture.window.orderOut(nil) }
        let navigation = MarkdownEditorNavigation()
        fixture.view.markdownLinkNavigation = navigation
        navigation.hasLinkCompletion = true
        var completionCommands = 0
        navigation.completionCommand = { _ in completionCommands += 1; return true }
        fixture.view.setSelectedRange(NSRange(location: 10, length: 0))
        fixture.view.keyDown(with: try keyEvent(
            123, in: fixture.window, modifiers: .shift
        ))
        XCTAssertEqual(completionCommands, 0)
        XCTAssertEqual(fixture.view.selectedRange(), NSRange(location: 9, length: 1))
    }

    func testRenderedLinkClickOpensButSourceAndBlankSpaceRemainEditable() throws {
        for linkText in ["[[planet.md|label]]", "[label](planet.md)"] {
            let source = "\(linkText)\nOutside"
            let fixture = makeTextView(source: source)
            let view = fixture.view
            defer { fixture.window.orderOut(nil) }
            let navigation = MarkdownEditorNavigation()
            view.markdownLinkNavigation = navigation
            var opened: String?
            navigation.openLink = { opened = $0.destination }
            let outside = (source as NSString).range(of: "Outside")
            view.setSelectedRange(outside)
            MarkdownPresentation.configure(view, mode: .livePreview)
            view.layoutSubtreeIfNeeded()
            let point = linkLabelPoint(in: view, source: source)
            XCTAssertNotNil(view.noteLink(at: point, modifiers: []))
            let cursorRects = view.noteLinkCursorRects(modifiers: [])
            XCTAssertTrue(cursorRects.contains { $0.contains(point) })
            XCTAssertFalse(cursorRects.contains { $0.contains(NSPoint(x: 330, y: point.y)) })
            XCTAssertTrue(view.noteLinkCursorRects(modifiers: .shift).isEmpty)
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: .leftMouseDown, location: view.convert(point, to: nil),
                modifierFlags: [], timestamp: 0,
                windowNumber: fixture.window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1
            ))
            view.mouseDown(with: event)
            XCTAssertEqual(opened, "planet.md")
            XCTAssertEqual(view.selectedRange(), outside)
            XCTAssertEqual(view.string, source)
            XCTAssertNil(view.noteLink(at: NSPoint(x: 330, y: point.y), modifiers: []))
            XCTAssertNil(view.noteLink(at: point, modifiers: .shift))

            // The active paragraph exposes literal syntax for editing.
            view.setSelectedRange(NSRange(location: 2, length: 0))
            MarkdownPresentation.configure(view, mode: .livePreview)
            let activePoint = linkLabelPoint(in: view, source: source)
            XCTAssertNil(view.noteLink(at: activePoint, modifiers: []))
            XCTAssertTrue(view.noteLinkCursorRects(modifiers: []).isEmpty)
            XCTAssertNotNil(view.noteLink(at: activePoint, modifiers: .command))
            XCTAssertTrue(view.noteLinkCursorRects(modifiers: .command).contains { $0.contains(activePoint) })
            MarkdownPresentation.configure(view, mode: .source)
            XCTAssertNil(view.noteLink(at: linkLabelPoint(in: view, source: source), modifiers: []))
            XCTAssertTrue(view.noteLinkCursorRects(modifiers: []).isEmpty)
            XCTAssertNotNil(view.noteLink(at: linkLabelPoint(in: view, source: source), modifiers: .command))
        }
    }

    func testLinkCursorCoversWrappedLabelsAndRequiresNavigation() {
        let label = "First part of a long fictional note label ending here"
        let source = "[[planet.md|\(label)]]\nOutside"
        let fixture = makeTextView(source: source)
        let view = fixture.view
        defer { fixture.window.orderOut(nil) }
        view.textContainer?.size.width = 180
        view.setSelectedRange((source as NSString).range(of: "Outside"))
        MarkdownPresentation.configure(view, mode: .livePreview)
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(view.noteLinkCursorRects(modifiers: []).isEmpty)
        let navigation = MarkdownEditorNavigation()
        navigation.openLink = { _ in }
        view.markdownLinkNavigation = navigation
        let rects = view.noteLinkCursorRects(modifiers: [])
        XCTAssertGreaterThan(rects.count, 1)
        for word in ["First", "here"] {
            let screenRect = view.firstRect(
                forCharacterRange: (source as NSString).range(of: word), actualRange: nil
            )
            let local = view.convert(fixture.window.convertFromScreen(screenRect), from: nil)
            let point = NSPoint(x: local.midX, y: local.midY)
            XCTAssertTrue(rects.contains { $0.contains(point) }, word)
            XCTAssertNotNil(view.noteLink(at: point, modifiers: []))
        }
    }

    private func linkLabelPoint(in view: MarkdownTextView, source: String) -> NSPoint {
        let rect = view.firstRect(
            forCharacterRange: (source as NSString).range(of: "label"), actualRange: nil
        )
        let local = view.convert(view.window!.convertFromScreen(rect), from: nil)
        return NSPoint(x: local.midX, y: local.midY)
    }

    private func keyEvent(
        _ code: UInt16, in window: NSWindow,
        modifiers: NSEvent.ModifierFlags = [], characters: String? = nil
    ) throws -> NSEvent {
        let key = characters ?? [123: "\u{F702}", 124: "\u{F703}",
                                 125: "\u{F701}", 126: "\u{F700}"][code] ?? ""
        return try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: key, charactersIgnoringModifiers: key,
            isARepeat: false, keyCode: code
        ))
    }

    func testNativeInsertionRequiresCurrentSourceAndUndoRestoresExactText() throws {
        let source = "Read [[Cafe]] after"
        let fixture = makeTextView(source: source)
        let view = fixture.view
        defer { fixture.window.orderOut(nil) }
        let originalRange = (source as NSString).range(of: "[[Cafe]]")
        let replacement = "[[Café.md|Coffee]]"
        let change = MarkdownEditingChange(
            range: originalRange,
            replacement: replacement,
            selection: NSRange(
                location: originalRange.location + (replacement as NSString).length,
                length: 0
            )
        )
        view.undoManager?.removeAllActions()

        XCTAssertFalse(view.insertNoteLink(change, expected: "stale buffer"))
        XCTAssertEqual(view.string, source)
        XCTAssertFalse(view.undoManager?.canUndo == true)

        XCTAssertTrue(view.insertNoteLink(change, expected: source))
        XCTAssertEqual(
            view.string,
            "Read [[Café.md|Coffee]] after"
        )
        let undoManager = try XCTUnwrap(view.undoManager)
        XCTAssertTrue(undoManager.canUndo)
        undoManager.undo()
        XCTAssertEqual(view.string, source)
    }

    func testWikiLinkPreviewKeepsLiteralSourceAndHidesOnlyLinkSyntax() throws {
        let source = "[[planet.md|🪐 Saturn]]\nOutside"
        let fixture = makeTextView(source: source)
        let view = fixture.view
        defer { fixture.window.orderOut(nil) }
        view.setSelectedRange((source as NSString).range(of: "Outside"))

        MarkdownPresentation.configure(view, mode: .livePreview)
        let undoManager = try XCTUnwrap(view.undoManager)
        undoManager.registerUndo(withTarget: view) { _ in }

        let syntax = MarkdownSyntax.parse(source)
        let hidden = MarkdownLivePreview.hiddenRanges(
            in: source,
            result: syntax,
            snapshot: MarkdownLivePreview.snapshot(for: view)
        ).map { (source as NSString).substring(with: $0) }

        XCTAssertEqual(hidden, ["[[planet.md|", "]]" ])
        XCTAssertTrue(syntax.spans.contains { $0.role == .link })
        XCTAssertEqual(view.string, source)
        XCTAssertTrue(undoManager.canUndo)
    }

    func testWikiAndMarkdownLinksShareSpansButCodeExamplesDoNot() throws {
        let source = "[[note.md|label]] and [**guide**](guide.md) and `[[code]]`"
        let result = MarkdownSyntax.parse(source)
        let links = result.spans.filter { $0.role == .link }

        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(
            links.map { (source as NSString).substring(with: $0.range) },
            ["[[note.md|label]]", "[**guide**](guide.md)"]
        )
        XCTAssertFalse(links.contains { NSLocationInRange(
            (source as NSString).range(of: "[[code]]").location,
            $0.range
        ) })

        for guardedSource in [
            "<!-- [hidden](comment.md) -->\nvisible",
            "---\ntitle: [hidden](frontmatter.md)\n---\nvisible",
        ] {
            let previous = MarkdownSyntax.parse(guardedSource)
            let updated = guardedSource + "!"
            let edit = NSRange(
                location: (guardedSource as NSString).length,
                length: 1
            )
            XCTAssertNil(MarkdownSyntax.incrementallyParse(
                updated,
                previousText: guardedSource,
                previousResult: previous,
                editedRange: edit,
                changeInLength: 1
            ))
        }
    }

    private func makeTextView(
        source: String
    ) -> (view: MarkdownTextView, window: NSWindow) {
        _ = NSApplication.shared
        let view = MarkdownTextView(usingTextLayoutManager: true)
        view.frame = NSRect(x: 0, y: 0, width: 360, height: 240)
        view.isEditable = true
        view.allowsUndo = true
        view.string = source
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        window.makeFirstResponder(view)
        return (view, window)
    }
}
#endif
