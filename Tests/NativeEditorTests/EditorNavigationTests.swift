import SwiftUI
import XCTest

@testable import NativeEditor

#if os(macOS)
import AppKit

@MainActor
final class EditorNavigationTests: XCTestCase {
    func testPrepareCommitsNativeBufferBeforeFreezingEditor() throws {
        let model = NavigationEditorModel()
        let fixture = makeFixture(model)
        fixture.textView.string = "hello!"
        var editableDuringCommit: Bool?
        model.onCommit = { editableDuringCommit = fixture.textView.isEditable }

        XCTAssertTrue(try XCTUnwrap(fixture.navigation.prepareToLeave)())

        XCTAssertEqual(model.committedTexts, ["hello!"])
        XCTAssertEqual(model.text, "hello!")
        XCTAssertEqual(editableDuringCommit, true)
        XCTAssertFalse(fixture.textView.isEditable)
    }

    func testFailedCommitPreventsLeavingAndKeepsEditorEditable() throws {
        let model = NavigationEditorModel()
        model.commitError = NavigationTestError.failed
        let fixture = makeFixture(model)
        fixture.textView.string = "not recorded"

        XCTAssertFalse(try XCTUnwrap(fixture.navigation.prepareToLeave)())

        XCTAssertEqual(model.committedTexts, ["not recorded"])
        XCTAssertEqual(model.text, "hello")
        XCTAssertEqual(model.errorCount, 1)
        XCTAssertTrue(fixture.textView.isEditable)
    }

    func testMarkedTextPreventsLeavingWithoutAttemptingCommit() throws {
        let model = NavigationEditorModel()
        let fixture = makeFixture(model)
        fixture.textView.setSelectedRange(
            NSRange(location: fixture.textView.string.utf16.count, length: 0)
        )
        fixture.textView.setMarkedText(
            "world",
            selectedRange: NSRange(location: 5, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(fixture.textView.hasMarkedText())

        XCTAssertFalse(try XCTUnwrap(fixture.navigation.prepareToLeave)())

        XCTAssertTrue(model.committedTexts.isEmpty)
        XCTAssertEqual(model.text, "hello")
        XCTAssertTrue(fixture.textView.isEditable)
    }

    func testResumeMakesFrozenEditorEditableAgain() throws {
        let fixture = makeFixture(NavigationEditorModel())

        XCTAssertTrue(try XCTUnwrap(fixture.navigation.prepareToLeave)())
        XCTAssertFalse(fixture.textView.isEditable)

        try XCTUnwrap(fixture.navigation.resumeEditing)()
        XCTAssertTrue(fixture.textView.isEditable)
    }

    private func makeFixture(_ model: NavigationEditorModel) -> NavigationFixture {
        let navigation = MarkdownEditorNavigation()
        let editor = MarkdownEditor(
            text: Binding(
                get: { model.text },
                set: { model.text = $0 }
            ),
            editRevision: model.revision,
            commitEdit: { text, revision in
                try model.commit(text, revision: revision)
            },
            onEditError: { _ in model.errorCount += 1 },
            navigation: navigation
        )
        let coordinator = editor.makeCoordinator()
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.string = model.text
        coordinator.attachNavigation(to: textView)
        return NavigationFixture(
            navigation: navigation,
            coordinator: coordinator,
            textView: textView
        )
    }
}

private enum NavigationTestError: Error {
    case failed
}

@MainActor
private final class NavigationEditorModel {
    var text = "hello"
    var revision = Data([0])
    var committedTexts: [String] = []
    var errorCount = 0
    var commitError: Error?
    var onCommit: (() -> Void)?

    func commit(_ text: String, revision: Data) throws -> MarkdownEditorCommit {
        committedTexts.append(text)
        onCommit?()
        if let commitError { throw commitError }
        self.text = text
        self.revision = Data([1])
        return MarkdownEditorCommit(text: text, revision: self.revision)
    }
}

@MainActor
private struct NavigationFixture {
    let navigation: MarkdownEditorNavigation
    let coordinator: MarkdownEditor.Coordinator
    let textView: NSTextView
}
#endif
