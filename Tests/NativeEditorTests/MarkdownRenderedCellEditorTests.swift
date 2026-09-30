import SwiftUI
import XCTest
@testable import NativeEditor
#if os(macOS)
import AppKit

@MainActor
final class MarkdownRenderedCellEditorTests: XCTestCase {
    private let source = "Intro\n\n| Name | Place |\n| --- | --- |\n| Moon | Harbor |\n| Star | Meadow |\n\nClosing"

    @MainActor
    private final class Document {
        var text: String
        var revision = Data([0])
        var committed: [String] = []
        var bindingWrites: [String] = []
        init(_ text: String) { self.text = text }
        func commit(_ text: String, base: Data) -> MarkdownEditorCommit {
            XCTAssertEqual(base, revision)
            committed.append(text)
            self.text = text
            revision = Data([UInt8(committed.count)])
            return MarkdownEditorCommit(text: text, revision: revision)
        }
    }

    @MainActor
    private struct Mounted {
        let window: NSWindow
        let owner: MarkdownTextView
        let document: Document
    }

    func testCellReplacementCommitsOnceAndUsesNativeUndoRedo() throws {
        let mounted = try mount()
        defer { mounted.window.orderOut(nil) }
        let owner = mounted.owner
        let cell = owner.markdownCellController
        try begin(cell, owner: owner, row: 1, column: 0)
        let editor = cell.editor
        cell.replaceLocal(range: NSRange(location: 4, length: 0), replacement: " 🪐")
        let expected = source.replacingOccurrences(of: "Moon", with: "Moon 🪐")
        XCTAssertEqual(owner.string, expected)
        XCTAssertEqual(mounted.document.text, expected)
        XCTAssertEqual(mounted.document.committed, [expected])
        XCTAssertTrue(mounted.document.bindingWrites.isEmpty)
        XCTAssertTrue(cell.editor === editor)
        XCTAssertEqual(editor.string, "Moon 🪐")
        let undo = try XCTUnwrap(owner.undoManager)
        XCTAssertTrue(editor.undoManager === undo)
        let undoTarget = try XCTUnwrap(cell.target)
        undo.undo()
        XCTAssertNotNil(MarkdownTableCellEditing.rebased(undoTarget, from: expected, to: source),
                        "The undo source diff must retain the same cell identity")
        XCTAssertTrue(cell.isActive, "Undo must preserve the active cell session")
        refresh(owner)
        XCTAssertTrue(cell.isActive, "Refresh must preserve the active cell session")
        XCTAssertEqual(owner.string, source)
        XCTAssertEqual(mounted.document.text, source)
        XCTAssertEqual(editor.string, "Moon")
        XCTAssertFalse(undo.canUndo, "One insertion must create one undo step")
        undo.redo()
        refresh(owner)
        XCTAssertEqual(owner.string, expected)
        XCTAssertEqual(mounted.document.text, expected)
        XCTAssertEqual(editor.string, "Moon 🪐")
    }

    func testExcessBodyCellsKeepBothTablesRenderedThroughEditAndUndo() throws {
        let first = "| A | B |\n| --- | --- |\n|  Sample |  ||  |  |\n"
        let second = "| C | D |\n| --- | --- |\n| Moon | Harbor | extra 🪐 |\n"
        let source = first + "\nBetween\n\n" + second + "\nClosing"
        let mounted = try mount(source)
        defer { mounted.window.orderOut(nil) }
        let owner = mounted.owner
        let cell = owner.markdownCellController
        XCTAssertEqual(owner.markdownTableScrollOverlays.count, 2)
        try begin(cell, owner: owner, row: 1, column: 0)
        XCTAssertEqual(cell.editor.string, "Sample")
        XCTAssertEqual(owner.markdownSyntaxCache.tableLayout?.rows.count, 4)
        cell.replaceLocal(range: NSRange(location: 6, length: 0), replacement: "!")
        refresh(owner)
        let expected = source.replacingOccurrences(of: "Sample", with: "Sample!")
        XCTAssertEqual(owner.string, expected)
        XCTAssertEqual(mounted.document.text, expected)
        XCTAssertEqual(owner.markdownTableScrollOverlays.count, 2)
        XCTAssertTrue(cell.perform(.tableNextCell))
        XCTAssertEqual(cell.target?.column, 1)
        XCTAssertEqual(cell.editor.string, "")
        XCTAssertEqual(owner.string, expected)
        let undo = try XCTUnwrap(owner.undoManager)
        undo.undo()
        refresh(owner)
        XCTAssertEqual(owner.string, source)
        XCTAssertEqual(mounted.document.text, source)
        XCTAssertTrue(cell.isActive)
        XCTAssertEqual(owner.markdownTableScrollOverlays.count, 2)
        undo.redo()
        refresh(owner)
        XCTAssertEqual(owner.string, expected)
        XCTAssertEqual(mounted.document.text, expected)
        XCTAssertEqual(owner.markdownTableScrollOverlays.count, 2)
    }

    func testUndoTraversesCellsAndProseInDocumentOrder() throws {
        let mounted = try mount()
        defer { mounted.window.orderOut(nil) }
        let owner = mounted.owner
        let cell = owner.markdownCellController
        let undo = try XCTUnwrap(owner.undoManager)
        undo.groupsByEvent = false
        try begin(cell, owner: owner, row: 1, column: 0)
        undo.beginUndoGrouping()
        cell.replaceLocal(range: NSRange(location: 4, length: 0), replacement: "!")
        undo.endUndoGrouping()
        let first = owner.string
        XCTAssertTrue(cell.perform(.tableNextCell))
        XCTAssertEqual(cell.target?.column, 1)
        undo.beginUndoGrouping()
        cell.replaceLocal(range: NSRange(location: 6, length: 0), replacement: "!")
        undo.endUndoGrouping()
        let second = owner.string
        cell.end(focusSource: true)
        owner.breakUndoCoalescing()
        undo.beginUndoGrouping()
        owner.insertText("!", replacementRange: NSRange(
            location: owner.string.utf16.count, length: 0
        ))
        owner.breakUndoCoalescing()
        undo.endUndoGrouping()
        XCTAssertEqual(mounted.document.text, second + "!")
        for expected in [second, first, source] {
            undo.undo()
            refresh(owner)
            XCTAssertEqual(owner.string, expected)
            XCTAssertEqual(mounted.document.text, expected)
        }
        for expected in [first, second, second + "!"] {
            undo.redo()
            refresh(owner)
            XCTAssertEqual(owner.string, expected)
            XCTAssertEqual(mounted.document.text, expected)
        }
    }

    func testNavigationAndReturnKeepGridAndCreateLastRow() throws {
        let mounted = try mount()
        defer { mounted.window.orderOut(nil) }
        let owner = mounted.owner
        let cell = owner.markdownCellController
        try begin(cell, owner: owner, row: 1, column: 0)
        let editor = cell.editor
        cell.replaceLocal(range: NSRange(location: 4, length: 0), replacement: "!")
        refresh(owner)
        XCTAssertEqual(owner.markdownSyntaxCache.tableLayout?.rows.count, 3)
        XCTAssertTrue(cell.editor === editor)
        XCTAssertTrue(mounted.window.firstResponder === editor)
        XCTAssertTrue(cell.perform(.tableNextCell))
        XCTAssertEqual(editor.string, "Harbor")
        XCTAssertTrue(cell.perform(.tablePreviousCell))
        XCTAssertEqual(editor.string, "Moon!")
        cell.nextRow()
        XCTAssertEqual(cell.target?.row, 2)
        XCTAssertEqual(cell.target?.column, 0)
        XCTAssertEqual(editor.string, "Star")
        cell.nextRow()
        refresh(owner)
        XCTAssertEqual(cell.target?.row, 3)
        XCTAssertEqual(cell.target?.column, 0)
        XCTAssertEqual(editor.string, "")
        XCTAssertEqual(MarkdownSyntax.parse(owner.string).tables.first?.rows.count, 3)
        XCTAssertEqual(mounted.document.text, owner.string)
        XCTAssertNotNil(owner.markdownSyntaxCache.tableLayout)
    }

    func testInactiveCellDoesNotHandleShortcutsFromAnotherField() throws {
        let mounted = try mount()
        defer { mounted.window.orderOut(nil) }
        let cell = mounted.owner.markdownCellController
        let field = NSSearchField(frame: NSRect(x: 0, y: 0, width: 180, height: 24))
        try XCTUnwrap(mounted.window.contentView).addSubview(field)
        let shortcuts: [(String, NSEvent.ModifierFlags, UInt16)] = [
            ("b", .command, 11), ("i", .command, 34), ("k", .command, 40),
            ("c", [.command, .shift], 8), ("f", .command, 3),
        ]
        for (key, flags, keyCode) in shortcuts {
            try begin(cell, owner: mounted.owner, row: 1, column: 0)
            cell.editor.setSelectedRange(NSRange(location: 0, length: 4))
            XCTAssertTrue(mounted.window.makeFirstResponder(field))
            let responder = try XCTUnwrap(mounted.window.firstResponder)
            XCTAssertFalse(responder === cell.editor)
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: mounted.window.windowNumber,
                context: nil, characters: key, charactersIgnoringModifiers: key,
                isARepeat: false, keyCode: keyCode
            ))
            XCTAssertFalse(cell.editor.performKeyEquivalent(with: event), key)
            XCTAssertEqual(mounted.owner.string, source, key)
            XCTAssertTrue(mounted.document.committed.isEmpty, key)
            XCTAssertTrue(mounted.window.firstResponder === responder, key)
            XCTAssertTrue(cell.isActive, key)
        }
    }

    func testFocusedCellStillHandlesFormattingAndFind() throws {
        let mounted = try mount()
        defer { mounted.window.orderOut(nil) }
        let cell = mounted.owner.markdownCellController
        try begin(cell, owner: mounted.owner, row: 1, column: 0)
        cell.editor.setSelectedRange(NSRange(location: 0, length: 4))
        for (key, keyCode) in [("b", UInt16(11)), ("f", UInt16(3))] {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: 0, windowNumber: mounted.window.windowNumber,
                context: nil, characters: key, charactersIgnoringModifiers: key,
                isARepeat: false, keyCode: keyCode
            ))
            XCTAssertTrue(cell.editor.performKeyEquivalent(with: event), key)
        }
        XCTAssertEqual(mounted.owner.string,
                       source.replacingOccurrences(of: "Moon", with: "**Moon**"))
        XCTAssertEqual(mounted.document.committed.count, 1)
        XCTAssertFalse(cell.isActive, "Find must return to the note's search interface")
    }

    func testGeometryRefreshPreservesScrollUntilCellNavigation() throws {
        let longSource = String(repeating: "Opening paragraph.\n\n", count: 35)
            + source + String(repeating: "\n\nClosing paragraph.", count: 35)
        let mounted = try mount(longSource)
        defer { mounted.window.orderOut(nil) }
        let owner = mounted.owner
        let cell = owner.markdownCellController
        try begin(cell, owner: owner, row: 1, column: 0)
        let scroller = try XCTUnwrap(owner.enclosingScrollView)
        let overlay = try XCTUnwrap(owner.markdownTableScrollOverlays.first)
        let row = overlay.rowFrames[1]
        let cellFrame = row.offsetBy(dx: overlay.frame.minX, dy: overlay.frame.minY)
        scroller.contentView.scroll(to: .zero)
        scroller.reflectScrolledClipView(scroller.contentView)
        XCTAssertFalse(scroller.contentView.bounds.intersects(cellFrame))
        let scrollOrigin = scroller.contentView.bounds.origin
        cell.updateGeometry()
        cell.synchronize(mode: .livePreview)
        cell.didScroll(offset: overlay.elasticHorizontalOffset,
                       tableRange: overlay.tableRange)
        XCTAssertEqual(scroller.contentView.bounds.origin, scrollOrigin)
        XCTAssertTrue(cell.isActive)
        XCTAssertTrue(cell.perform(.tableNextCell))
        XCTAssertTrue(scroller.contentView.bounds.intersects(cellFrame),
                      "Explicit cell navigation must reveal the editing row")
        XCTAssertEqual(owner.string, longSource)
        XCTAssertTrue(mounted.document.committed.isEmpty)
    }

    func testRemoteReplacementBeforeTableRebasesCell() throws {
        let mounted = try mount()
        defer { mounted.window.orderOut(nil) }
        let owner = mounted.owner
        let cell = owner.markdownCellController
        try begin(cell, owner: owner, row: 1, column: 0)
        let oldTarget = try XCTUnwrap(cell.target)
        replaceExternally(owner, with: "Preface\n\n" + source)
        let target = try XCTUnwrap(cell.target)
        XCTAssertTrue(cell.isActive)
        XCTAssertEqual(target.row, 1)
        XCTAssertEqual(target.column, 0)
        XCTAssertEqual(target.contentRange.location,
                       oldTarget.contentRange.location + 9)
        XCTAssertEqual(cell.editor.string, "Moon")
    }

    func testRemoteOtherCellAndSameCellRefreshActiveBuffer() throws {
        let mounted = try mount()
        defer { mounted.window.orderOut(nil) }
        let owner = mounted.owner
        let cell = owner.markdownCellController
        try begin(cell, owner: owner, row: 1, column: 0)
        let otherCell = source.replacingOccurrences(of: "Harbor", with: "Port")
        replaceExternally(owner, with: otherCell)
        XCTAssertTrue(cell.isActive,
                      "A remote edit of another cell must preserve this editor")
        XCTAssertEqual(cell.editor.string, "Moon")
        let sameCell = otherCell.replacingOccurrences(of: "Moon", with: "Luna")
        replaceExternally(owner, with: sameCell)
        XCTAssertTrue(cell.isActive)
        XCTAssertEqual(cell.editor.string, "Luna")
        XCTAssertEqual(cell.target?.column, 0)
    }

    func testMarkedCandidateAcceptanceCreatesOneSourceUndoStep() throws {
        let mounted = try mount()
        defer { mounted.window.orderOut(nil) }
        let owner = mounted.owner
        let cell = owner.markdownCellController
        try begin(cell, owner: owner, row: 1, column: 0)
        let editor = cell.editor
        editor.setMarkedText("つき", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: 0, length: 4))
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(owner.string, source)
        XCTAssertTrue(mounted.document.committed.isEmpty)
        editor.insertText("月", replacementRange: editor.markedRange())
        refresh(owner)
        let accepted = source.replacingOccurrences(of: "Moon", with: "月")
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(editor.string, "月")
        XCTAssertEqual(owner.string, accepted)
        XCTAssertEqual(mounted.document.committed, [accepted])
        let undo = try XCTUnwrap(owner.undoManager)
        undo.undo()
        refresh(owner)
        XCTAssertEqual(owner.string, source)
        XCTAssertEqual(mounted.document.text, source)
        XCTAssertEqual(editor.string, "Moon")
        XCTAssertFalse(undo.canUndo, "Candidate acceptance must undo once")
        undo.redo()
        refresh(owner)
        XCTAssertEqual(owner.string, accepted)
        XCTAssertEqual(editor.string, "月")
        XCTAssertEqual(mounted.document.text, accepted)
    }

    func testActiveCellPreservesCenterAndRightAlignment() throws {
        for (delimiter, alignment) in [(":---:", NSTextAlignment.center),
                                       ("---:", NSTextAlignment.right)] {
            let aligned = source.replacingOccurrences(of: "| --- | --- |",
                                                       with: "| \(delimiter) | --- |")
            let mounted = try mount(aligned)
            defer { mounted.window.orderOut(nil) }
            let owner = mounted.owner
            let cell = owner.markdownCellController
            try begin(cell, owner: owner, row: 1, column: 0)
            XCTAssertEqual(cell.editor.alignment, alignment)
            cell.replaceLocal(range: NSRange(location: 4, length: 0), replacement: "!")
            refresh(owner)
            XCTAssertEqual(cell.editor.alignment, alignment)
        }
    }

    func testScrollingAnotherTableDoesNotMoveActiveCellTable() throws {
        let wide = String(repeating: "Long fictional harbor name ", count: 15)
        let headers = "| Name | " + Array(repeating: "Place", count: 7).joined(separator: " | ") + " |"
        let delimiters = "| " + Array(repeating: "---", count: 8).joined(separator: " | ") + " |"
        let firstTable = headers + "\n" + delimiters + "\n| Moon | "
            + Array(repeating: wide, count: 7).joined(separator: " | ") + " |"
        let secondTable = headers + "\n" + delimiters + "\n| Star | "
            + Array(repeating: wide, count: 7).joined(separator: " | ") + " |"
        let mounted = try mount(firstTable + "\n\nBetween\n\n" + secondTable + "\n\nClosing")
        defer { mounted.window.orderOut(nil) }
        let owner = mounted.owner
        let tables = MarkdownSyntax.parse(owner.string).tables
        XCTAssertEqual(tables.count, 2)
        let cell = owner.markdownCellController
        XCTAssertTrue(cell.begin(tableRange: tables[0].range, row: 1, column: 0))
        refresh(owner)
        let active = try XCTUnwrap(owner.markdownTableScrollOverlays.first {
            $0.tableRange == tables[0].range
        })
        let other = try XCTUnwrap(owner.markdownTableScrollOverlays.first {
            $0.tableRange == tables[1].range
        })
        XCTAssertGreaterThan(other.contentWidth, other.frame.width)
        let originalOffset = active.elasticHorizontalOffset
        let originalEditorFrame = cell.editor.frame
        other.contentView.scroll(to: CGPoint(x: 40, y: 0))
        other.reflectScrolledClipView(other.contentView)
        XCTAssertEqual(active.elasticHorizontalOffset, originalOffset, accuracy: 0.5)
        XCTAssertEqual(cell.editor.frame, originalEditorFrame)
        XCTAssertEqual(cell.target?.tableRange, tables[0].range)
    }

    func testDeletingActiveRowUsesSourceUndoAndKeepsRemainingGrid() throws {
        let mounted = try mount()
        defer { mounted.window.orderOut(nil) }
        let owner = mounted.owner
        let cell = owner.markdownCellController
        try begin(cell, owner: owner, row: 1, column: 0)
        XCTAssertTrue(cell.perform(.tableDeleteRow))
        refresh(owner)
        let expected = source.replacingOccurrences(of: "| Moon | Harbor |\n", with: "")
        XCTAssertEqual(owner.string, expected)
        XCTAssertEqual(mounted.document.text, expected)
        XCTAssertEqual(owner.markdownSyntaxCache.tableLayout?.rows.count, 2)
        let undo = try XCTUnwrap(owner.undoManager)
        undo.undo()
        refresh(owner)
        XCTAssertEqual(owner.string, source)
        XCTAssertEqual(mounted.document.text, source)
        XCTAssertEqual(owner.markdownSyntaxCache.tableLayout?.rows.count, 3)
        undo.redo()
        refresh(owner)
        XCTAssertEqual(owner.string, expected)
        XCTAssertEqual(mounted.document.text, expected)
    }

    func testLongCellGrowsRowWithoutLosingGridOrEditorFocus() throws {
        let mounted = try mount()
        defer { mounted.window.orderOut(nil) }
        let owner = mounted.owner
        let cell = owner.markdownCellController
        try begin(cell, owner: owner, row: 1, column: 0)
        let initialHeight = try XCTUnwrap(owner.markdownSyntaxCache.tableLayout?.rows[1].height)
        let longText = String(repeating: "Fictional moonlit harbor and meadow. ", count: 30)
        cell.replaceLocal(range: NSRange(location: 0, length: 4), replacement: longText)
        refresh(owner)
        let layout = try XCTUnwrap(owner.markdownSyntaxCache.tableLayout)
        XCTAssertEqual(layout.rows.count, 3)
        XCTAssertGreaterThan(layout.rows[1].height, initialHeight)
        XCTAssertGreaterThan(cell.editor.frame.height, initialHeight)
        XCTAssertTrue(mounted.window.firstResponder === cell.editor)
        XCTAssertTrue(cell.isActive)
        XCTAssertEqual(cell.editor.string.trimmingCharacters(in: .whitespaces),
                       longText.trimmingCharacters(in: .whitespaces))
        XCTAssertEqual(mounted.document.text, owner.string)
        XCTAssertTrue(owner.string.hasSuffix("Closing"))
    }

    func testNoOpCompositionReplaysDeferredRemoteParentRevision() throws {
        let mounted = try mount()
        defer { mounted.window.orderOut(nil) }
        let owner = mounted.owner
        let cell = owner.markdownCellController
        try begin(cell, owner: owner, row: 1, column: 0)
        cell.editor.setMarkedText("Moon", selectedRange: NSRange(location: 4, length: 0),
                                  replacementRange: NSRange(location: 0, length: 4))
        let remote = source.replacingOccurrences(of: "Harbor", with: "Port")
        try updateParent(mounted, text: remote)
        XCTAssertEqual(owner.string, source,
                       "Remote source replacement waits for composition to finish")
        cell.editor.unmarkText()
        refresh(owner)
        XCTAssertEqual(owner.string, remote)
        XCTAssertEqual(mounted.document.text, remote)
        XCTAssertTrue(mounted.document.committed.isEmpty)
        XCTAssertTrue(cell.isActive)
        XCTAssertEqual(cell.editor.string, "Moon")
    }

    func testCancelledCompositionReplaysDeferredRemoteParentRevision() throws {
        let mounted = try mount()
        defer { mounted.window.orderOut(nil) }
        let owner = mounted.owner
        let cell = owner.markdownCellController
        try begin(cell, owner: owner, row: 1, column: 0)
        cell.editor.setMarkedText("Temporary", selectedRange: NSRange(location: 9, length: 0),
                                  replacementRange: NSRange(location: 0, length: 4))
        let remote = "Preface\n\n" + source
        try updateParent(mounted, text: remote)
        cell.editor.insertText("Moon", replacementRange: cell.editor.markedRange())
        refresh(owner)
        XCTAssertEqual(owner.string, remote)
        XCTAssertTrue(mounted.document.committed.isEmpty)
        XCTAssertTrue(cell.isActive)
        XCTAssertEqual(cell.editor.string, "Moon")
        XCTAssertEqual(cell.target?.row, 1)
    }

    func testReadOnlyParentEndsCompositionWithoutCommittingCandidate() throws {
        let mounted = try mount()
        defer { mounted.window.orderOut(nil) }
        let owner = mounted.owner
        let cell = owner.markdownCellController
        try begin(cell, owner: owner, row: 1, column: 0)
        cell.editor.setMarkedText("Temporary", selectedRange: NSRange(location: 9, length: 0),
                                  replacementRange: NSRange(location: 0, length: 4))
        try updateParent(mounted, text: source, isReadOnly: true)
        XCTAssertFalse(owner.isEditable)
        cell.editor.unmarkText()
        refresh(owner)
        XCTAssertFalse(cell.isActive)
        XCTAssertEqual(owner.string, source)
        XCTAssertEqual(mounted.document.text, source)
        XCTAssertTrue(mounted.document.committed.isEmpty)
        XCTAssertFalse(owner.undoManager?.canUndo ?? false)
    }

    func testSourceMarkedTextPreventsDirectAndDeferredCellActivation() throws {
        let mounted = try mount()
        defer { mounted.window.orderOut(nil) }
        let owner = mounted.owner
        let table = try XCTUnwrap(MarkdownSyntax.parse(owner.string).tables.first)
        let range = table.rows[0].cells[0]
        owner.setMarkedText("Moon", selectedRange: NSRange(location: 4, length: 0),
                            replacementRange: range)
        XCTAssertTrue(owner.hasMarkedText())
        let cell = owner.markdownCellController
        XCTAssertFalse(cell.begin(tableRange: table.range, row: 1, column: 0))
        cell.activateSourceSelection()
        let drained = expectation(description: "Pending activation callback runs")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
        XCTAssertFalse(cell.isActive)
        XCTAssertTrue(owner.hasMarkedText())
        XCTAssertTrue(mounted.window.firstResponder === owner)
        owner.unmarkText()
    }

    func testReadOnlyParentImmediatelyEndsUnmarkedActiveCell() throws {
        let mounted = try mount()
        defer { mounted.window.orderOut(nil) }
        let owner = mounted.owner
        let cell = owner.markdownCellController
        try begin(cell, owner: owner, row: 1, column: 0)
        XCTAssertTrue(cell.isActive)
        XCTAssertTrue(mounted.window.firstResponder === cell.editor)
        let document = mounted.document
        let coordinator = try XCTUnwrap(owner.delegate as? MarkdownEditor.Coordinator)
        let parent = MarkdownEditor(
            text: Binding(get: { document.text }, set: {
                document.bindingWrites.append($0)
                document.text = $0
            }),
            isReadOnly: true,
            editRevision: document.revision,
            commitEdit: { document.commit($0, base: $1) },
            mode: .livePreview
        )
        coordinator.update(parent: parent, textView: owner)
        XCTAssertFalse(owner.isEditable)
        XCTAssertFalse(cell.isActive,
                       "Read-only transitions must close cells even at the same revision")
        XCTAssertFalse(mounted.window.firstResponder === cell.editor)
        XCTAssertEqual(owner.string, source)
        XCTAssertTrue(document.committed.isEmpty)
    }

    func testRemoteDecomposedUnicodeCellPreservesLiteralBytesAndInsertionOffset() throws {
        let original = source.replacingOccurrences(of: "Moon", with: "Café")
        let mounted = try mount(original)
        defer { mounted.window.orderOut(nil) }
        let owner = mounted.owner
        let cell = owner.markdownCellController
        try begin(cell, owner: owner, row: 1, column: 0)
        let decomposed = "Cafe\u{0301}"
        let remote = original.replacingOccurrences(of: "Café", with: decomposed)
        try updateParent(mounted, text: remote)
        refresh(owner)
        XCTAssertTrue(cell.isActive)
        XCTAssertEqual(Array(owner.string.utf8), Array(remote.utf8))
        XCTAssertEqual(Array(cell.editor.string.utf8), Array(decomposed.utf8))
        XCTAssertEqual(cell.target?.contentRange.length, 5)
        XCTAssertTrue(mounted.document.committed.isEmpty)
        cell.replaceLocal(range: NSRange(location: 5, length: 0), replacement: "!")
        let expected = remote.replacingOccurrences(of: decomposed, with: decomposed + "!")
        XCTAssertEqual(Array(owner.string.utf8), Array(expected.utf8))
        XCTAssertEqual(Array(mounted.document.text.utf8), Array(expected.utf8))
        XCTAssertEqual(Array(cell.editor.string.utf8), Array((decomposed + "!").utf8))
        XCTAssertEqual(mounted.document.committed.count, 1)
        XCTAssertEqual(Array(try XCTUnwrap(mounted.document.committed.first).utf8),
                       Array(expected.utf8))
    }

    private func updateParent(_ mounted: Mounted, text: String,
                              isReadOnly: Bool = false) throws {
        let document = mounted.document
        document.text = text
        document.revision = Data([99])
        let coordinator = try XCTUnwrap(mounted.owner.delegate as? MarkdownEditor.Coordinator)
        let parent = MarkdownEditor(
            text: Binding(get: { document.text }, set: {
                document.bindingWrites.append($0)
                document.text = $0
            }),
            isReadOnly: isReadOnly,
            editRevision: document.revision,
            commitEdit: { document.commit($0, base: $1) },
            mode: .livePreview
        )
        coordinator.update(parent: parent, textView: mounted.owner)
    }

    private func mount(_ initial: String? = nil) throws -> Mounted {
        let source = initial ?? self.source
        _ = NSApplication.shared
        let document = Document(source)
        let editor = MarkdownEditor(
            text: Binding(get: { document.text }, set: {
                document.bindingWrites.append($0)
                document.text = $0
            }),
            editRevision: document.revision,
            commitEdit: { document.commit($0, base: $1) },
            mode: .livePreview
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 500),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let host = NSHostingView(rootView: editor)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let owner = try XCTUnwrap(findOwner(in: host))
        window.makeFirstResponder(owner)
        owner.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
        refresh(owner)
        owner.undoManager?.removeAllActions()
        return Mounted(window: window, owner: owner, document: document)
    }

    private func begin(_ cell: MarkdownTableCellEditorController,
                       owner: MarkdownTextView, row: Int, column: Int) throws {
        let table = try XCTUnwrap(MarkdownSyntax.parse(owner.string).tables.first)
        XCTAssertTrue(cell.begin(tableRange: table.range, row: row, column: column))
        refresh(owner)
    }

    private func refresh(_ owner: MarkdownTextView) {
        MarkdownPresentation.refresh(owner, mode: .livePreview)
    }

    private func replaceExternally(_ owner: MarkdownTextView, with text: String) {
        let old = owner.string as NSString
        let new = text as NSString
        let selected = owner.selectedRange()
        var prefix = 0
        while prefix < min(old.length, new.length),
              old.character(at: prefix) == new.character(at: prefix) {
            prefix += 1
        }
        var suffix = 0
        while suffix < min(old.length, new.length) - prefix,
              old.character(at: old.length - suffix - 1)
                == new.character(at: new.length - suffix - 1) {
            suffix += 1
        }
        let oldEnd = old.length - suffix
        let location = selected.location >= oldEnd
            ? selected.location + new.length - old.length : selected.location
        let selection = NSRange(location: min(max(0, location), new.length),
                                length: 0)
        owner.textStorage?.replaceCharacters(
            in: NSRange(location: 0, length: owner.string.utf16.count), with: text
        )
        owner.setSelectedRange(selection)
        owner.undoManager?.removeAllActions()
        refresh(owner)
    }

    private func findOwner(in view: NSView) -> MarkdownTextView? {
        if let owner = view as? MarkdownTextView { return owner }
        for child in view.subviews {
            if let owner = findOwner(in: child) { return owner }
        }
        return nil
    }
}
#endif
