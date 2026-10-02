import Foundation
import XCTest
import NoteCore

@testable import NotebookAppModel

@MainActor
final class NotebookLinkStateTests: XCTestCase {
    func testSwitchingBacklinkTargetClearsRowsBeforeLoading() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let replica = NotebookReplica(directory: directory)
        try await replica.createLocalNotebook()
        let first = try await replica.createNote(name: "First.md", text: "First")
        let second = try await replica.createNote(name: "Second.md", text: "Second")
        let source = try await replica.createNote(name: "Meeting.md", text: "[[First]]")
        let state = NotebookLinkState()
        await state.refresh(replica: replica, targetID: first)
        XCTAssertEqual(state.backlinks.map(\.sourceID), [source])
        XCTAssertFalse(state.hasBacklinkScope(replica: replica, targetID: second))

        state.prepareBacklinks(replica: replica, targetID: second)
        XCTAssertTrue(state.backlinks.isEmpty)
        XCTAssertTrue(state.isLoading)
        XCTAssertNil(state.error)
        XCTAssertTrue(state.hasBacklinkScope(replica: replica, targetID: second))
        await state.refresh(replica: replica, targetID: second)
        XCTAssertTrue(state.backlinks.isEmpty)
        XCTAssertFalse(state.isLoading)
    }

    func testAuthoringRefreshDoesNotReplaceDisplayedBacklinks() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let replica = NotebookReplica(directory: directory)
        try await replica.createLocalNotebook()
        let target = try await replica.createNote(name: "Project.md", text: "Project")
        let source = try await replica.createNote(name: "Meeting.md", text: "[[Project]]")
        let state = NotebookLinkState()
        await state.refresh(replica: replica, targetID: target)
        await state.refresh(replica: replica)
        XCTAssertEqual(state.backlinks.map(\.sourceID), [source])
        XCTAssertTrue(state.hasBacklinkScope(replica: replica, targetID: target))
    }

    func testCompletionSupportsEmptyWikiOpenerAndExistingClosingBrackets() {
        let emptySource = "[[¦"
        let empty = detectCompletion(in: emptySource)
        XCTAssertEqual(empty?.query, "")
        XCTAssertEqual(empty?.range, NSRange(location: 0, length: 2))

        let source = "😀 [[Café¦]]"
        let completion = detectCompletion(in: source)
        let literal = removingCaret(from: source)
        XCTAssertEqual(completion?.query, "Café")
        XCTAssertEqual(completion?.range, (literal as NSString).range(of: "[[Café]]"))
    }

    func testCompletionRejectsEscapedAndNonProseWikiOpeners() {
        let examples = [
            #"\[[planet¦"#,
            "`[[planet¦`",
            "```\n[[planet¦\n```",
            "    [[planet¦]]",
            "<!-- [[planet¦]] -->",
            "---\ntitle: [[planet¦]]\n---\n",
        ]

        for example in examples {
            XCTAssertNil(detectCompletion(in: example), "Unexpected completion in: \(example)")
        }
    }

    private func detectCompletion(in sourceWithCaret: String) -> NotebookLinkCompletion? {
        let caret = (sourceWithCaret as NSString).range(of: "¦")
        guard caret.location != NSNotFound else { return nil }
        let source = removingCaret(from: sourceWithCaret)
        return NotebookLinkCompletion.detect(
            in: source,
            selection: NSRange(location: caret.location, length: 0)
        )
    }

    private func removingCaret(from source: String) -> String {
        source.replacingOccurrences(of: "¦", with: "")
    }
}
