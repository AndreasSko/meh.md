import Foundation
import XCTest

@testable import NativeEditor
@testable import NoteCore

@MainActor
final class MarkdownSnippetMenuTests: XCTestCase {
    func testSingleRegisteredFolderFlattensOnlyItsRoot() {
        let root = UUID(), child = UUID(), note = UUID(), loose = UUID()
        let snippets = [
            NotebookSnippet(id: note, name: "Agenda.md", path: "Snippets/Work/Agenda.md",
                            categories: [.init(id: root, name: "Snippets"),
                                         .init(id: child, name: "Work")]),
            NotebookSnippet(id: loose, name: "Greeting.md", path: "Greeting.md",
                            categories: [])
        ]
        let sources = [
            NotebookSnippetSource(id: root, kind: .folder, name: "Snippets", path: "Snippets"),
            NotebookSnippetSource(id: loose, kind: .note, name: "Greeting.md", path: "Greeting.md")
        ]
        let entries = EditorSnippetMenuEntry.tree(snippets, sources: sources)
        XCTAssertEqual(entries.map(\.id), [child, loose])
        XCTAssertEqual(entries[0].children.first?.snippetID, note)
        XCTAssertEqual(entries[1].name, "Greeting")
    }

    func testSecondRegisteredFolderKeepsRootsEvenWhenEmpty() {
        let root = UUID(), other = UUID(), note = UUID()
        let snippet = NotebookSnippet(id: note, name: "Agenda.md", path: "Work/Agenda.md",
                                     categories: [.init(id: root, name: "Work")])
        let sources = [
            NotebookSnippetSource(id: root, kind: .folder, name: "Work", path: "Work"),
            NotebookSnippetSource(id: other, kind: .folder, name: "Personal", path: "Personal")
        ]
        let entries = EditorSnippetMenuEntry.tree([snippet], sources: sources)
        XCTAssertEqual(entries.first?.id, root)
        XCTAssertEqual(entries.first?.children.first?.snippetID, note)
    }

    func testRegistrationChangesRebuildMenuWithoutChangingSnippetRows() {
        let root = UUID(), other = UUID(), note = UUID()
        let snippet = NotebookSnippet(id: note, name: "Agenda.md", path: "Work/Agenda.md",
                                     categories: [.init(id: root, name: "Work")])
        let source = NotebookSnippetSource(id: root, kind: .folder, name: "Work", path: "Work")
        let otherSource = NotebookSnippetSource(id: other, kind: .folder,
                                               name: "Other", path: "Other")
        let menu = EditorSnippetMenuState()
        menu.update([snippet], sources: [source])
        XCTAssertEqual(menu.entries.first?.snippetID, note)
        menu.update([snippet], sources: [source, otherSource])
        XCTAssertEqual(menu.entries.first?.id, root)
        menu.update([snippet], sources: [source])
        XCTAssertEqual(menu.entries.first?.snippetID, note)
    }
}
