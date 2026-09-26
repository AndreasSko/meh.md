import SwiftUI
import XCTest

@testable import NativeEditor

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

@MainActor
final class RemoteEditorTests: XCTestCase {
    func testSuccessfulCommitDoesNotWriteBindingAgainAndPreservesUndo() throws {
        let model = EditorModel(text: "hello", revision: revision(0))
        let mounted = mount(model)
        let textView = try XCTUnwrap(mounted.textView)
        defer { mounted.tearDown() }

        moveInsertionPointToEnd(of: textView)
        insert("!", in: textView)
        mounted.flushUpdates()
        XCTAssertEqual(model.text, "hello!")
        XCTAssertEqual(nativeText(in: textView), model.text)
        XCTAssertEqual(model.requests.count, 1)
        XCTAssertTrue(model.bindingWrites.isEmpty)

        let undo = try XCTUnwrap(textView.undoManager)
        undo.undo()
        mounted.flushUpdates()
        XCTAssertEqual(model.text, "hello")
        XCTAssertEqual(nativeText(in: textView), model.text)
        undo.redo()
        mounted.flushUpdates()
        XCTAssertEqual(model.text, "hello!")
        XCTAssertEqual(nativeText(in: textView), model.text)
        XCTAssertTrue(model.bindingWrites.isEmpty)
    }

    func testAcknowledgedRevisionDoesNotReadWholeBindingText() {
        var reads = 0
        let editor = MarkdownEditor(
            text: Binding(get: { reads += 1; return "hello" }, set: { _ in }),
            editRevision: revision(0),
            commitEdit: { text, revision in
                MarkdownEditorCommit(text: text, revision: revision)
            }
        )
        let coordinator = editor.makeCoordinator()
        let textView = MarkdownTextView(usingTextLayoutManager: true)
#if os(macOS)
        textView.string = "hello"
#else
        textView.text = "hello"
#endif
        reads = 0
        coordinator.update(parent: editor, textView: textView)
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(nativeText(in: textView), "hello")
    }

    func testStaleParentAfterCommitDoesNotRollBackOrChangeNextEditBase() throws {
        let model = EditorModel(text: "hello", revision: revision(0))
        let mounted = mount(model)
        let textView = try XCTUnwrap(mounted.textView)
        let coordinator = try XCTUnwrap(textView.delegate as? MarkdownEditor.Coordinator)
        defer { mounted.tearDown() }
        let staleParent = MarkdownEditor(
            text: .constant("hello"),
            editRevision: revision(0),
            commitEdit: { try model.commit($0, basedOn: $1) }
        )
        moveInsertionPointToEnd(of: textView)
        insert("!", in: textView)
        coordinator.update(parent: staleParent, textView: textView)
        XCTAssertEqual(nativeText(in: textView), "hello!")
        insert("?", in: textView)
        mounted.flushUpdates()
        XCTAssertEqual(model.requests.map(\.revision), [revision(0), revision(1)])
        XCTAssertEqual(nativeText(in: textView), "hello!?")
        XCTAssertEqual(model.text, "hello!?")
        XCTAssertTrue(model.bindingWrites.isEmpty)
    }

    func testRemoteTableReplacementRefreshesPreviewWithoutWritingBack() throws {
        let source = "| Name | Time |\n| --- | --- |\n| Walk | 09:00 |\n\nOutside"
        let model = EditorModel(text: source, revision: revision(0))
        model.mode = .livePreview
        let mounted = mount(model)
        let textView = try XCTUnwrap(mounted.textView)
        defer { mounted.tearDown() }
        moveInsertionPointToEnd(of: textView)
        let remote = source.replacingOccurrences(of: "09:00", with: "10:30")
        model.receiveRemote(text: remote, revision: revision(9))
        mounted.flushUpdates()
        MarkdownPresentation.refresh(textView, mode: .livePreview)
        XCTAssertEqual(nativeText(in: textView), remote)
        XCTAssertTrue(model.requests.isEmpty)
        XCTAssertTrue(model.bindingWrites.isEmpty)
        let cache = MarkdownPresentation.syntaxCache(for: textView)
        XCTAssertEqual(cache.tableLayout?.rows.last?.cells.last?.string, "10:30")
        insert("!", in: textView)
        mounted.flushUpdates()
        XCTAssertEqual(model.requests.map(\.revision), [revision(9)])
        XCTAssertEqual(model.text, remote + "!")
    }

    func testCommandAfterRemoteUpdateUsesFreshRevisionInLivePreview() throws {
        let model = EditorModel(text: "* Moon", revision: revision(0))
        model.mode = .livePreview
        let mounted = mount(model)
        let textView = try XCTUnwrap(mounted.textView)
        defer { mounted.tearDown() }
        model.receiveRemote(text: "* Remote Moon", revision: revision(9))
        mounted.flushUpdates()
        moveInsertionPointToEnd(of: textView)
        model.navigation.performCommand?(.continueLine)
        XCTAssertEqual(nativeText(in: textView), "* Remote Moon\n* ")
        XCTAssertEqual(model.requests.map(\.revision), [revision(9)])
        mounted.flushUpdates()
        model.mode = .source
        mounted.flushUpdates()
        XCTAssertEqual(nativeText(in: textView), "* Remote Moon\n* ")
        XCTAssertEqual(model.requests.count, 1)
        textView.undoManager?.undo()
        XCTAssertEqual(nativeText(in: textView), "* Remote Moon")
    }

    func testRemoteUpdateBetweenLocalEditsUsesDisplayedRevision() throws {
        let model = EditorModel(text: "hello", revision: revision(0))
        let mounted = mount(model)
        let textView = try XCTUnwrap(mounted.textView)
        defer { mounted.tearDown() }

        moveInsertionPointToEnd(of: textView)
        insert("!", in: textView)
        mounted.flushUpdates()
        XCTAssertEqual(model.requests.map(\.revision), [revision(0)])
        XCTAssertTrue(textView.undoManager?.canUndo == true)

        model.receiveRemote(text: "Remote hello!", revision: revision(9))
        mounted.flushUpdates()
        XCTAssertEqual(nativeText(in: textView), "Remote hello!")
        XCTAssertFalse(textView.undoManager?.canUndo == true)

        moveInsertionPointToEnd(of: textView)
        insert("?", in: textView)
        XCTAssertEqual(model.requests.map(\.revision), [revision(0), revision(9)])
        XCTAssertEqual(nativeText(in: textView), "Remote hello!?")
    }

    func testRemoteUpdateBeforeEditorHasFirstResponder() throws {
        let model = EditorModel(text: "hello", revision: revision(0))
        let mounted = mount(model, focus: false)
        let textView = try XCTUnwrap(mounted.textView)
        defer { mounted.tearDown() }

        XCTAssertFalse(isFirstResponder(textView))
        model.receiveRemote(text: "Remote hello", revision: revision(9))
        mounted.flushUpdates()

        XCTAssertEqual(nativeText(in: textView), "Remote hello")
        XCTAssertFalse(textView.undoManager?.canUndo == true)
    }

    func testRemoteUpdateWaitsForMarkedTextAndMergesFromItsBase() throws {
        let model = EditorModel(text: "hello", revision: revision(0))
        model.commitResult = { replacement, baseRevision in
            XCTAssertEqual(baseRevision, self.revision(0))
            XCTAssertEqual(replacement, "hello世界")
            return MarkdownEditorCommit(
                text: "Remote hello世界",
                revision: self.revision(10)
            )
        }
        let mounted = mount(model)
        let textView = try XCTUnwrap(mounted.textView)
        defer { mounted.tearDown() }

        moveInsertionPointToEnd(of: textView)
        setMarkedText("世界", in: textView)
        XCTAssertTrue(hasMarkedText(in: textView))

        model.receiveRemote(text: "Remote hello", revision: revision(9))
        mounted.flushUpdates()
        XCTAssertTrue(hasMarkedText(in: textView))
        XCTAssertEqual(nativeText(in: textView), "hello世界")
        XCTAssertTrue(model.requests.isEmpty)

        unmarkText(in: textView)
        XCTAssertFalse(hasMarkedText(in: textView))
        XCTAssertEqual(model.requests.map(\.revision), [revision(0)])
        XCTAssertEqual(nativeText(in: textView), "Remote hello世界")
        XCTAssertEqual(model.text, "Remote hello世界")
        XCTAssertTrue(model.bindingWrites.isEmpty)
        XCTAssertFalse(textView.undoManager?.canUndo == true)
    }

    func testRemoteReplacementDropsStaleUndoThenLocalUndoWorks() throws {
        let model = EditorModel(text: "hello", revision: revision(0))
        let mounted = mount(model)
        let textView = try XCTUnwrap(mounted.textView)
        defer { mounted.tearDown() }

        moveInsertionPointToEnd(of: textView)
        insert("!", in: textView)
        XCTAssertTrue(textView.undoManager?.canUndo == true)

        model.receiveRemote(text: "Remote hello!", revision: revision(9))
        mounted.flushUpdates()
        let undoManager = try XCTUnwrap(textView.undoManager)
        XCTAssertFalse(undoManager.canUndo)
        XCTAssertFalse(undoManager.canRedo)

        moveInsertionPointToEnd(of: textView)
        insert("?", in: textView)
        XCTAssertTrue(undoManager.canUndo)
        undoManager.undo()

        XCTAssertEqual(nativeText(in: textView), "Remote hello!")
        XCTAssertEqual(model.text, "Remote hello!")
        XCTAssertEqual(model.requests.suffix(2).map(\.revision), [
            revision(9),
            revision(2),
        ])
    }

    func testSameTextRemoteRevisionBecomesNextEditBase() throws {
        let model = EditorModel(text: "hello", revision: revision(0))
        let mounted = mount(model)
        let textView = try XCTUnwrap(mounted.textView)
        defer { mounted.tearDown() }

        model.receiveRemote(text: "hello", revision: revision(9))
        mounted.flushUpdates()
        moveInsertionPointToEnd(of: textView)
        insert("!", in: textView)

        XCTAssertEqual(model.requests.map(\.revision), [revision(9)])
        XCTAssertEqual(nativeText(in: textView), "hello!")
        XCTAssertTrue(textView.undoManager?.canUndo == true)
    }

    func testRemoteSelectionMappingDoesNotSplitEmoji() throws {
        let model = EditorModel(text: "A😀B", revision: revision(0))
        let mounted = mount(model)
        let textView = try XCTUnwrap(mounted.textView)
        defer { mounted.tearDown() }

        setSelection(NSRange(location: 3, length: 0), in: textView)
        model.receiveRemote(text: "X A😀B", revision: revision(9))
        mounted.flushUpdates()

        XCTAssertEqual(selectedRange(in: textView), NSRange(location: 5, length: 0))
        insert("!", in: textView)
        XCTAssertEqual(nativeText(in: textView), "X A😀!B")
    }

    func testCanonicalRemoteReplacementKeepsCursorAtEnd() throws {
        let composed = "\u{00E9}"
        let decomposed = "e\u{0301}"
        let model = EditorModel(text: composed, revision: revision(0))
        let mounted = mount(model)
        let textView = try XCTUnwrap(mounted.textView)
        defer { mounted.tearDown() }

        moveInsertionPointToEnd(of: textView)
        model.receiveRemote(text: decomposed, revision: revision(9))
        mounted.flushUpdates()

        XCTAssertEqual(selectedRange(in: textView), NSRange(location: 2, length: 0))
        insert("!", in: textView)
        XCTAssertTrue(nativeText(in: textView).utf8.elementsEqual(
            "e\u{0301}!".utf8
        ))
    }

    func testFailedCommitKeepsNativeTextAndBaseRevision() throws {
        enum TestError: Error { case failed }

        let model = EditorModel(text: "hello", revision: revision(0))
        model.commitResult = { _, _ in throw TestError.failed }
        let mounted = mount(model)
        let textView = try XCTUnwrap(mounted.textView)
        defer { mounted.tearDown() }

        moveInsertionPointToEnd(of: textView)
        insert("!", in: textView)
        mounted.flushUpdates()
        XCTAssertEqual(nativeText(in: textView), "hello!")
        insert("?", in: textView)

        XCTAssertEqual(nativeText(in: textView), "hello!?")
        XCTAssertEqual(model.text, "hello")
        XCTAssertEqual(model.requests.map(\.revision), [revision(0), revision(0)])
        XCTAssertEqual(model.errorCount, 2)
    }

    func testFontChangesAfterFailedSavePreservePendingEdit() throws {
        enum TestError: Error { case failed }
        let model = EditorModel(text: "hello", revision: revision(0))
        model.commitResult = { _, _ in throw TestError.failed }
        let mounted = mount(model)
        let textView = try XCTUnwrap(mounted.textView)
        defer { mounted.tearDown() }

        moveInsertionPointToEnd(of: textView)
        insert("!", in: textView)
        mounted.flushUpdates()
        let originalSize = try XCTUnwrap(textView.font).pointSize
        model.fontSize = 24
        model.fontFamily = .serif
        model.receiveRemote(text: "remote replacement", revision: revision(9))
        mounted.flushUpdates()
        mounted.flushUpdates()

        XCTAssertGreaterThan(try XCTUnwrap(textView.font).pointSize, originalSize)
        XCTAssertEqual(
            try XCTUnwrap(textView.font).fontName,
            MarkdownPresentation.bodyFont(
                for: .serif,
                pointSize: 24
            ).fontName
        )
        XCTAssertEqual(nativeText(in: textView), "hello!")
        XCTAssertEqual(selectedRange(in: textView), NSRange(location: 6, length: 0))
        XCTAssertTrue(textView.undoManager?.canUndo == true)
        insert("?", in: textView)
        XCTAssertEqual(nativeText(in: textView), "hello!?")
        XCTAssertEqual(model.requests.map(\.revision), [revision(0), revision(0)])
    }

    private func revision(_ value: UInt8) -> Data {
        Data([value])
    }
}

@MainActor
private final class EditorModel: ObservableObject {
    struct Request {
        let text: String
        let revision: Data
    }

    @Published var text: String
    @Published var revision: Data
    @Published var fontSize: Double = 17
    @Published var fontFamily: EditorFontFamily = .system
    @Published var mode: MarkdownEditorMode = .source
    let navigation = MarkdownEditorNavigation()
    var requests: [Request] = []
    var bindingWrites: [String] = []
    @Published var errorCount = 0
    var commitResult: ((String, Data) throws -> MarkdownEditorCommit)?
    private var nextRevision: UInt8 = 1

    init(text: String, revision: Data) {
        self.text = text
        self.revision = revision
    }

    func receiveRemote(text: String, revision: Data) {
        self.text = text
        self.revision = revision
    }

    func commit(_ replacement: String, basedOn revision: Data) throws
        -> MarkdownEditorCommit {
        requests.append(Request(text: replacement, revision: revision))
        let result: MarkdownEditorCommit
        if let commitResult {
            result = try commitResult(replacement, revision)
        } else {
            result = MarkdownEditorCommit(
                text: replacement,
                revision: Data([nextRevision])
            )
            nextRevision += 1
        }
        // Match NoteSession: a successful commit has already updated the model.
        self.text = result.text
        self.revision = result.revision
        return result
    }
}

@MainActor
private struct EditorHost: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        MarkdownEditor(
            text: Binding(get: { model.text }, set: {
                model.bindingWrites.append($0)
                model.text = $0
            }),
            editRevision: model.revision,
            commitEdit: { replacement, revision in
                try model.commit(replacement, basedOn: revision)
            },
            onEditError: { _ in model.errorCount += 1 },
            navigation: model.navigation,
            fontSize: model.fontSize,
            fontFamily: model.fontFamily,
            mode: model.mode
        )
    }
}

#if os(macOS)
@MainActor
private extension RemoteEditorTests {
    typealias NativeTextView = NSTextView

    struct MountedEditor {
        let window: NSWindow
        let host: NSHostingView<EditorHost>
        let textView: NSTextView?

        @MainActor func flushUpdates() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            host.layoutSubtreeIfNeeded()
        }

        @MainActor func tearDown() {
            window.orderOut(nil)
        }
    }

    func mount(_ model: EditorModel, focus: Bool = true) -> MountedEditor {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let host = NSHostingView(rootView: EditorHost(model: model))
        window.contentView = host
        window.makeFirstResponder(host)
        host.layoutSubtreeIfNeeded()
        let textView = findTextView(in: host)
        if focus, let textView {
            window.makeFirstResponder(textView)
        }
        return MountedEditor(window: window, host: host, textView: textView)
    }

    func findTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        for subview in view.subviews {
            if let textView = findTextView(in: subview) { return textView }
        }
        return nil
    }

    func moveInsertionPointToEnd(of textView: NSTextView) {
        textView.setSelectedRange(
            NSRange(location: (textView.string as NSString).length, length: 0)
        )
    }

    func insert(_ text: String, in textView: NSTextView) {
        textView.insertText(
            text,
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
    }

    func nativeText(in textView: NSTextView) -> String { textView.string }

    func isFirstResponder(_ textView: NSTextView) -> Bool {
        textView.window?.firstResponder === textView
    }

    func setMarkedText(_ text: String, in textView: NSTextView) {
        textView.setMarkedText(
            text,
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
    }

    func hasMarkedText(in textView: NSTextView) -> Bool {
        textView.hasMarkedText()
    }

    func unmarkText(in textView: NSTextView) { textView.unmarkText() }

    func setSelection(_ range: NSRange, in textView: NSTextView) {
        textView.setSelectedRange(range)
    }

    func selectedRange(in textView: NSTextView) -> NSRange {
        textView.selectedRange()
    }
}
#elseif os(iOS)
@MainActor
private extension RemoteEditorTests {
    typealias NativeTextView = UITextView

    struct MountedEditor {
        let window: UIWindow
        let host: UIHostingController<EditorHost>
        let textView: UITextView?

        @MainActor func flushUpdates() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            host.view.layoutIfNeeded()
        }

        @MainActor func tearDown() {
            window.isHidden = true
        }
    }

    func mount(_ model: EditorModel, focus: Bool = true) -> MountedEditor {
        let host = UIHostingController(rootView: EditorHost(model: model))
        let window = UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        let textView = findTextView(in: host.view)
        if focus {
            _ = textView?.becomeFirstResponder()
        }
        return MountedEditor(window: window, host: host, textView: textView)
    }

    func findTextView(in view: UIView) -> UITextView? {
        if let textView = view as? UITextView { return textView }
        for subview in view.subviews {
            if let textView = findTextView(in: subview) { return textView }
        }
        return nil
    }

    func moveInsertionPointToEnd(of textView: UITextView) {
        textView.selectedRange = NSRange(
            location: (textView.text as NSString).length,
            length: 0
        )
    }

    func insert(_ text: String, in textView: UITextView) {
        textView.insertText(text)
    }

    func nativeText(in textView: UITextView) -> String { textView.text }

    func isFirstResponder(_ textView: UITextView) -> Bool {
        textView.isFirstResponder
    }

    func setMarkedText(_ text: String, in textView: UITextView) {
        textView.setMarkedText(
            text,
            selectedRange: NSRange(location: 2, length: 0)
        )
    }

    func hasMarkedText(in textView: UITextView) -> Bool {
        textView.markedTextRange != nil
    }

    func unmarkText(in textView: UITextView) { textView.unmarkText() }

    func setSelection(_ range: NSRange, in textView: UITextView) {
        textView.selectedRange = range
    }

    func selectedRange(in textView: UITextView) -> NSRange {
        textView.selectedRange
    }
}
#endif
