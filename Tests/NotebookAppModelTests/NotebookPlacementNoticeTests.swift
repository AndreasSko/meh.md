import Foundation
@testable import NoteCore
import XCTest

@testable import NotebookAppModel

@MainActor
final class NotebookPlacementNoticeTests: XCTestCase {
    private let id = UUID()
    private let projects = UUID()
    private let archive = UUID()

    func testNoIssueOrOnlyAReorderShowsNothing() {
        XCTAssertNil(NotebookPlacementNotice(placement()))
        XCTAssertNil(NotebookPlacementNotice(placement(issues: [.concurrentReorder])))
    }

    func testTwoNamesListEveryName() throws {
        var conflicted = placement(name: "Hi.md", issues: [.concurrentRename])
        conflicted.alternatives.names = ["Hi.md", "Welcome.md"]
        let notice = try XCTUnwrap(NotebookPlacementNotice(conflicted))
        XCTAssertEqual(notice.kind, .names(["Hi.md", "Welcome.md"]))
        XCTAssertEqual(notice.mark, "2 names")
        XCTAssertEqual(notice.title, "Two names for one note")
    }

    func testTwoFoldersComeBeforeRecoveredPlacements() throws {
        var conflicted = placement(
            parentID: projects, issues: [.concurrentMove, .missingParent, .nameCollision])
        conflicted.alternatives.parentIDs = [archive, projects]
        let notice = try XCTUnwrap(NotebookPlacementNotice(conflicted))
        XCTAssertEqual(notice.kind, .folders([archive, projects]))
        XCTAssertEqual(notice.mark, "2 places")
    }

    func testRecoveredPlacementsExplainWhatHappened() {
        XCTAssertEqual(
            NotebookPlacementNotice(placement(issues: [.cycleRecovered]))?.kind, .folderLoop)
        XCTAssertEqual(
            NotebookPlacementNotice(placement(issues: [.missingParent]))?.kind, .folderGone)
        let same = NotebookPlacementNotice(placement(name: "Notes.md", issues: [.nameCollision]))
        XCTAssertEqual(same?.kind, .sameName)
        XCTAssertTrue(same?.message.contains("\u{201C}Notes\u{201D}") == true)
    }

    func testGhostGoesAfterTheRowsInItsOpenFolder() {
        let other = UUID()
        var moved = placement(parentID: projects, issues: [.concurrentMove])
        moved.alternatives.parentIDs = [archive, projects]
        let rows: [(id: UUID, depth: Int)] = [
            (projects, 0), (id, 1), (archive, 0), (other, 1), (UUID(), 2), (UUID(), 0),
        ]
        let ghosts = NotebookGhost.ghosts(
            rows: rows, placements: [moved], expandedIDs: [projects, archive])
        XCTAssertEqual(ghosts.map(\.parentID), [archive])
        XCTAssertEqual(ghosts.map(\.index), [5])
        XCTAssertEqual(ghosts.map(\.depth), [1])
        XCTAssertTrue(NotebookGhost.ghosts(
            rows: rows, placements: [moved], expandedIDs: [projects]).isEmpty)
    }

    func testTopLevelGhostNeedsVisibleFiles() {
        var moved = placement(parentID: projects, issues: [.concurrentMove])
        moved.alternatives.parentIDs = [nil, projects]
        let rows: [(id: UUID, depth: Int)] = [(projects, 0), (id, 1)]
        XCTAssertEqual(
            NotebookGhost.ghosts(rows: rows, placements: [moved], expandedIDs: [projects])
                .map(\.index),
            [2])
        XCTAssertTrue(
            NotebookGhost.ghosts(rows: [], placements: [moved], expandedIDs: []).isEmpty)
    }

    private func placement(
        name: String = "Note.md", parentID: UUID? = nil,
        issues: Set<NotebookPlacementIssue> = []
    ) -> NotebookPlacement {
        NotebookPlacement(
            item: NotebookItem(
                id: id, kind: .note, name: name, parentID: parentID, orderKey: nil,
                isTrashed: false, isPermanentlyDeleted: false, importRootID: nil),
            parentID: parentID, displayName: name, isInTrash: false, issues: issues)
    }
}

@MainActor
final class NotebookPlacementNoticeChoiceTests: XCTestCase {
    private let id = UUID()
    private let projects = UUID()
    private let archive = UUID()

    func testDeletedFoldersCantBeChosen() throws {
        let notice = try XCTUnwrap(NotebookPlacementNotice(moved(to: [archive, projects])))
        let choices = notice.choices(in: [folder(projects)])
        XCTAssertEqual(Set(choices.map(\.label)), ["Deleted folder", "Projects"])
        XCTAssertEqual(choices.first { $0.value == .parent(archive) }?.isAvailable, false)
        XCTAssertEqual(
            NotebookPlacementNotice.selection(.parent(archive), in: choices)?.value,
            .parent(projects))
        XCTAssertNil(NotebookPlacementNotice.selection(nil, in: notice.choices(in: [])))
    }

    func testPickedChoiceIsMatchedByValueWhenSyncChangesTheList() throws {
        var three = placement(issues: [.concurrentRename])
        three.alternatives.names = ["A.md", "B.md", "C.md"]
        let picked = NotebookPlacementNotice.Choice.Value.name("C.md")
        let before = try XCTUnwrap(NotebookPlacementNotice(three)).choices(in: [])
        XCTAssertEqual(NotebookPlacementNotice.selection(picked, in: before)?.label, "C")

        var two = three
        two.alternatives.names = ["B.md", "C.md"]
        let after = try XCTUnwrap(NotebookPlacementNotice(two)).choices(in: [])
        XCTAssertEqual(NotebookPlacementNotice.selection(picked, in: after)?.label, "C")
        two.alternatives.names = ["A.md", "B.md"]
        let gone = try XCTUnwrap(NotebookPlacementNotice(two)).choices(in: [])
        XCTAssertEqual(NotebookPlacementNotice.selection(picked, in: gone)?.label, "A")
    }

    private func moved(to parents: [UUID?]) -> NotebookPlacement {
        var result = placement(issues: [.concurrentMove])
        result.alternatives.parentIDs = parents
        return result
    }

    private func folder(_ folderID: UUID) -> NotebookPlacement {
        NotebookPlacement(
            item: NotebookItem(
                id: folderID, kind: .folder, name: "Projects", parentID: nil, orderKey: nil,
                isTrashed: false, isPermanentlyDeleted: false, importRootID: nil),
            parentID: nil, displayName: "Projects", isInTrash: false, issues: [])
    }

    private func placement(issues: Set<NotebookPlacementIssue>) -> NotebookPlacement {
        NotebookPlacement(
            item: NotebookItem(
                id: id, kind: .note, name: "A.md", parentID: nil, orderKey: nil,
                isTrashed: false, isPermanentlyDeleted: false, importRootID: nil),
            parentID: nil, displayName: "A.md", isInTrash: false, issues: issues)
    }
}
