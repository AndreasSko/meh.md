import Foundation
import SwiftUI
import XCTest

@testable import NoteCore
@testable import NativeEditor

#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class MarkdownNativeTextChangeTests: XCTestCase {
    func testMarkedReplacementUsesStaleRevisionMergeFallback() async throws {
        let original = try NoteDocument(text: "hello")
        let storage = NativeHintStorage(original.snapshot())
        let session = NoteSession(storage: storage)
        await session.load()
        let initialRevision = try XCTUnwrap(session.editorRevision)
        var receivedChanges: [NoteEditorTextChange?] = []
        func makeEditor() -> MarkdownEditor {
            MarkdownEditor(
                text: Binding(get: { session.text }, set: { _ in }),
                editRevision: session.editorRevision,
                commitNativeEdit: { text, revision, change in
                    receivedChanges.append(change)
                    let committed = try session.commitEditorText(
                        text, basedOn: revision, change: change
                    )
                    return MarkdownEditorCommit(
                        text: session.text, revision: committed
                    )
                }
            )
        }
        var editor = makeEditor()
        let coordinator = editor.makeCoordinator()
        let (view, textStorage) = fixture("hello")
        let tearDown = attachForNativeEditing(view, coordinator: coordinator)
        defer { tearDown() }

        setMarkedText("世界", replacing: NSRange(location: 1, length: 3),
                      in: view)
        XCTAssertTrue(hasMarkedText(in: view))
        XCTAssertNil(
            view.markdownSyntaxCache.nativeTextChange(in: textStorage)
        )
        notify(coordinator, view: view)
        XCTAssertEqual(session.text, "hello")

        let remote = try original.fork()
        try remote.replaceUTF16(
            range: NSRange(location: 0, length: 0), with: "Remote "
        )
        try session.mergeRemote(remote.snapshot())
        editor = makeEditor()
        coordinator.update(parent: editor, textView: view)
        XCTAssertTrue(hasMarkedText(in: view))
        XCTAssertEqual(editorText(view), "h世界o")

        unmarkText(in: view)
        notify(coordinator, view: view)

        XCTAssertEqual(receivedChanges.count, 1)
        XCTAssertNil(receivedChanges[0])
        XCTAssertEqual(session.text, "Remote h世界o")
        XCTAssertEqual(editorText(view), session.text)
        XCTAssertNotEqual(initialRevision, session.editorRevision)
        try await session.flush()
        try remote.merge(NoteDocument(snapshot: await storage.latest))
        XCTAssertEqual(try remote.text, session.text)
    }

    func testNativeInsertSurvivesSyntaxPreparation() {
        let (view, storage) = fixture("Start 🪐\nTail")
        let cache = view.markdownSyntaxCache
        let oldLength = storage.length
        storage.replaceCharacters(in: NSRange(location: oldLength, length: 0), with: " bright")
        _ = view.availableTableCommands
        MarkdownPresentation.refresh(view, mode: .livePreview)
        XCTAssertEqual(cache.nativeTextChange(in: storage),
                       NoteEditorTextChange(range: NSRange(location: oldLength, length: 0),
                                            replacement: " bright"))
        cache.acknowledgeNativeText()
        XCTAssertNil(cache.nativeTextChange(in: storage))
    }

    func testBatchedPureInsertionsAndDeletionsKeepBaselineCoordinates() {
        let (view, storage) = fixture("abcd")
        let cache = view.markdownSyntaxCache
        storage.replaceCharacters(in: NSRange(location: 4, length: 0), with: "x")
        storage.replaceCharacters(in: NSRange(location: 4, length: 0), with: "y")
        XCTAssertEqual(cache.nativeTextChange(in: storage),
                       NoteEditorTextChange(range: NSRange(location: 4, length: 0),
                                            replacement: "yx"))
        cache.acknowledgeNativeText()
        storage.replaceCharacters(in: NSRange(location: 4, length: 2), with: "")
        storage.replaceCharacters(in: NSRange(location: 3, length: 1), with: "")
        XCTAssertEqual(cache.nativeTextChange(in: storage),
                       NoteEditorTextChange(range: NSRange(location: 3, length: 3),
                                            replacement: ""))
    }

    func testMixedReplacementsFallBackAndStorageReplacementResetsIntent() {
        let (view, storage) = fixture("abcd")
        let cache = view.markdownSyntaxCache
        storage.replaceCharacters(in: NSRange(location: 1, length: 1), with: "long")
        XCTAssertNil(cache.nativeTextChange(in: storage))
        let other = NSTextStorage(string: "Other")
        _ = cache.textSnapshot(in: other)
        XCTAssertNil(cache.nativeTextChange(in: storage))
        XCTAssertNil(cache.nativeTextChange(in: other))
        other.replaceCharacters(in: NSRange(location: 5, length: 0), with: "!")
        XCTAssertEqual(cache.nativeTextChange(in: other),
                       NoteEditorTextChange(range: NSRange(location: 5, length: 0),
                                            replacement: "!"))
    }

    func testNativeCommitAcknowledgesIntentAndRetainsFailedBatchForRetry() {
        var model = "Start"
        var revision = Data([1])
        var changes: [NoteEditorTextChange?] = []
        var failNext = true
        let editor = MarkdownEditor(
            text: Binding(get: { model }, set: { model = $0 }),
            editRevision: revision,
            commitNativeEdit: { text, base, change in
                XCTAssertEqual(base, revision)
                changes.append(change)
                if failNext { failNext = false; throw Failure.expected }
                model = text
                revision = Data([2])
                return MarkdownEditorCommit(text: text, revision: revision)
            }
        )
        let coordinator = editor.makeCoordinator()
        let (view, storage) = fixture(model)
        storage.replaceCharacters(in: NSRange(location: 5, length: 0), with: "x")
        notify(coordinator, view: view)
        XCTAssertEqual(model, "Start")
        XCTAssertNotNil(view.markdownSyntaxCache.nativeTextChange(in: storage))
        storage.replaceCharacters(in: NSRange(location: 6, length: 0), with: "y")
        notify(coordinator, view: view)
        XCTAssertEqual(model, "Startxy")
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(changes.last ?? nil,
                       NoteEditorTextChange(range: NSRange(location: 5, length: 0),
                                            replacement: "xy"))
        XCTAssertNil(view.markdownSyntaxCache.nativeTextChange(in: storage))
    }

    func testCancelledNativeBatchDoesNotContaminateNextCommit() {
        var model = "Start"
        var changes: [NoteEditorTextChange?] = []
        let editor = MarkdownEditor(
            text: Binding(get: { model }, set: { model = $0 }),
            editRevision: Data([1]),
            commitNativeEdit: { text, _, change in
                changes.append(change)
                model = text
                return MarkdownEditorCommit(text: text, revision: Data([2]))
            }
        )
        let coordinator = editor.makeCoordinator()
        let (view, storage) = fixture(model)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "x")
        storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "")
        notify(coordinator, view: view)
        XCTAssertTrue(changes.isEmpty)
        storage.replaceCharacters(in: NSRange(location: 5, length: 0), with: "!")
        notify(coordinator, view: view)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first ?? nil,
                       NoteEditorTextChange(range: NSRange(location: 5, length: 0),
                                            replacement: "!"))
    }

    func testExternalBufferReplacementResetsNativeIntent() {
        var model = "Start"
        var changes: [NoteEditorTextChange?] = []
        var editor = MarkdownEditor(
            text: Binding(get: { model }, set: { model = $0 }),
            editRevision: Data([1]),
            commitNativeEdit: { text, _, change in
                changes.append(change)
                model = text
                return MarkdownEditorCommit(text: text, revision: Data([3]))
            }
        )
        let coordinator = editor.makeCoordinator()
        let (view, storage) = fixture(model)
        storage.replaceCharacters(in: NSRange(location: 5, length: 0), with: "x")
        model = "Remote"
        editor.editRevision = Data([2])
        coordinator.update(parent: editor, textView: view)
        XCTAssertEqual(storage.string, "Remote")
        XCTAssertNil(view.markdownSyntaxCache.nativeTextChange(in: storage))
        storage.replaceCharacters(in: NSRange(location: 6, length: 0), with: "!")
        notify(coordinator, view: view)
        XCTAssertEqual(changes.first ?? nil,
                       NoteEditorTextChange(range: NSRange(location: 6, length: 0),
                                            replacement: "!"))
    }

    private func fixture(_ text: String) -> (MarkdownTextView, NSTextStorage) {
        let view = MarkdownTextView(usingTextLayoutManager: true)
#if os(macOS)
        view.string = text
        let storage = view.textStorage!
#else
        view.text = text
        let storage = view.textStorage
#endif
        MarkdownPresentation.configure(view, mode: .livePreview)
        view.markdownSyntaxCache.acknowledgeNativeText()
        return (view, storage)
    }

    private func notify(_ coordinator: MarkdownEditor.Coordinator, view: MarkdownTextView) {
#if os(macOS)
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
#else
        coordinator.textViewDidChange(view)
#endif
    }

    private func editorText(_ view: MarkdownTextView) -> String {
#if os(macOS)
        view.string
#else
        view.text ?? ""
#endif
    }

    private func setMarkedText(
        _ text: String, replacing range: NSRange, in view: MarkdownTextView
    ) {
#if os(macOS)
        view.setSelectedRange(range)
        view.setMarkedText(
            text,
            selectedRange: NSRange(location: text.utf16.count, length: 0),
            replacementRange: range
        )
#else
        view.selectedRange = range
        view.setMarkedText(text, selectedRange: NSRange(location: text.utf16.count,
                                                        length: 0))
#endif
    }

    private func hasMarkedText(in view: MarkdownTextView) -> Bool {
#if os(macOS)
        view.hasMarkedText()
#else
        view.markedTextRange != nil
#endif
    }

    private func unmarkText(in view: MarkdownTextView) {
#if os(macOS)
        view.unmarkText()
#else
        view.unmarkText()
#endif
    }

    private func attachForNativeEditing(
        _ view: MarkdownTextView,
        coordinator: MarkdownEditor.Coordinator
    ) -> () -> Void {
        view.delegate = coordinator
#if os(macOS)
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView?.addSubview(view)
        view.frame = window.contentView?.bounds ?? .zero
        window.makeKeyAndOrderFront(nil)
        _ = window.makeFirstResponder(view)
        return { window.orderOut(nil) }
#else
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(view)
        view.frame = controller.view.bounds
        window.makeKeyAndVisible()
        _ = view.becomeFirstResponder()
        return { window.isHidden = true }
#endif
    }

    private enum Failure: Error { case expected }
}

private actor NativeHintStorage: NoteStorage {
    private(set) var latest: NoteSnapshot

    init(_ snapshot: NoteSnapshot) {
        latest = snapshot
    }

    func load() async -> NoteLoadResult { .current(latest) }

    func save(_ snapshot: NoteSnapshot) async throws {
        latest = snapshot
    }

    func recover(_ recovery: NoteRecovery) async throws -> NoteSnapshot {
        recovery.previous
    }
}
