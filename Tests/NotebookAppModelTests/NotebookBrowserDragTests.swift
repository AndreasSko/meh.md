import Foundation
import XCTest

@testable import NoteCore
@testable import NotebookAppModel

@MainActor
final class NotebookBrowserDragTests: XCTestCase {
    func testRootAndFolderCenterAppendToTheirOwnScope() {
        let source = row(1)
        let folder = row(2, kind: .folder)
        let drag = drag([source])
        XCTAssertEqual(target(nil, .root, drag, [source, folder]),
                       .init(rowID: nil, position: .root,
                             parentID: nil, beforeID: nil))
        XCTAssertEqual(target(folder.item.id, .into, drag, [source, folder]),
                       .init(rowID: folder.item.id, position: .into,
                             parentID: folder.item.id, beforeID: nil))
        XCTAssertNil(target(source.item.id, .into, drag, [source, folder]))
        let note = row(3)
        XCTAssertNil(target(note.item.id, .into, drag, [source, note]))
    }

    func testEdgesUseSiblingScopeAndSkipDraggedBatch() {
        let folder = row(1, kind: .folder)
        let a = row(2, parentID: folder.item.id)
        let b = row(3, parentID: folder.item.id)
        let c = row(4, parentID: folder.item.id)
        let d = row(5, parentID: folder.item.id)
        let rows = [folder, a, b, c, d]
        let drag = drag([b, c])
        XCTAssertEqual(target(a.item.id, .after, drag, rows),
                       .init(rowID: a.item.id, position: .after,
                             parentID: folder.item.id, beforeID: d.item.id))
        XCTAssertEqual(target(d.item.id, .before, drag, rows),
                       .init(rowID: d.item.id, position: .before,
                             parentID: folder.item.id, beforeID: d.item.id))
        XCTAssertEqual(target(d.item.id, .after, drag, rows)?.beforeID, nil)
        XCTAssertNil(target(b.item.id, .before, drag, rows))
        XCTAssertNil(target(c.item.id, .after, drag, rows))
        XCTAssertEqual(drag.itemIDs, [b.item.id, c.item.id])
    }

    func testAfterExpandedFolderPlacesBesideFolderNotAmongDescendants() {
        let source = row(1)
        let folder = row(2, kind: .folder)
        let child = row(3, parentID: folder.item.id)
        let nested = row(4, kind: .folder, parentID: folder.item.id)
        let grandchild = row(5, parentID: nested.item.id)
        let sibling = row(6)
        let result = target(folder.item.id, .after, drag([source]),
                            [source, folder, child, nested, grandchild, sibling])
        XCTAssertEqual(result?.parentID, nil)
        XCTAssertEqual(result?.beforeID, sibling.item.id)
    }

    func testSameParentAdjacentDropMapsToDurableNoOp() {
        let a = row(1)
        let b = row(2)
        let c = row(3)
        let d = row(4)
        let rows = [a, b, c, d]
        let drag = drag([b, c])
        let result = target(a.item.id, .after, drag, rows)
        XCTAssertEqual(result?.beforeID, d.item.id)
        XCTAssertNil(NotebookBrowserOrdering.request(
            sources: drag.itemIDs, before: result?.beforeID,
            parentID: result?.parentID, siblingIDs: rows.map(\.item.id)))
    }

    func testMovedUnavailableTrashedAndDuplicateSourcesRejectAllTargets() {
        let source = row(1)
        let folder = row(2, kind: .folder)
        let rows = [source, folder]
        let invalidDrags = [
            drag([]),
            drag([source, source]),
            drag([source, row(3)]),
            NotebookBrowserDrag(notebookID: UUID(), sources: [
                .init(itemID: source.item.id, parentID: folder.item.id),
            ]),
        ]
        for drag in invalidDrags {
            XCTAssertNil(target(nil, .root, drag, rows))
            XCTAssertNil(target(folder.item.id, .into, drag, rows))
        }
        for invalidSource in [row(1, isInTrash: true), row(1, deleted: true)] {
            XCTAssertNil(target(nil, .root, drag([source]),
                                [invalidSource, folder]))
        }
    }

    func testFolderCannotMoveIntoItselfOrDescendant() {
        let folder = row(1, kind: .folder)
        let child = row(2, kind: .folder, parentID: folder.item.id)
        let grandchild = row(3, kind: .folder, parentID: child.item.id)
        let note = row(4, parentID: grandchild.item.id)
        let rows = [folder, child, grandchild, note]
        let drag = drag([folder])
        XCTAssertNil(target(folder.item.id, .into, drag, rows))
        XCTAssertNil(target(child.item.id, .into, drag, rows))
        XCTAssertNil(target(grandchild.item.id, .into, drag, rows))
        XCTAssertNil(target(note.item.id, .before, drag, rows))
        XCTAssertNil(target(note.item.id, .after, drag, rows))
    }

    func testConflictedSourceIsForbiddenEvenWhenWinningParentMatches() {
        let folder = row(1, kind: .folder)
        let source = row(2, parentID: folder.item.id)
        let destination = row(3, kind: .folder)
        let anchor = row(4, parentID: destination.item.id)
        let conflicted = row(2, parentID: folder.item.id,
                             issues: [.concurrentMove])
        let rows = [folder, conflicted, destination, anchor]
        let drag = drag([source])
        XCTAssertNil(target(nil, .root, drag, rows))
        XCTAssertNil(target(destination.item.id, .into, drag, rows))
        XCTAssertNil(target(anchor.item.id, .before, drag, rows))
        XCTAssertNil(target(anchor.item.id, .after, drag, rows))
    }

    func testTrashAndRecoveredFolderTargetsRejectBeforeSpringLoading() {
        let source = row(1)
        let trash = row(2, kind: .folder, isInTrash: true)
        let recovered = row(3, kind: .folder, storedParentID: id(99),
                            issues: [.missingParent])
        let rows = [source, trash, recovered]
        let drag = drag([source])
        XCTAssertNil(target(trash.item.id, .into, drag, rows))
        XCTAssertNil(target(recovered.item.id, .before, drag, rows))
        XCTAssertNil(target(recovered.item.id, .after, drag, rows))
        XCTAssertNil(target(recovered.item.id, .into, drag, rows))
    }

    func testAfterEdgeSkipsRecoveredSiblingAsInvalidStoredAnchor() {
        let source = row(1)
        let ordinary = row(2)
        let recovered = row(3, storedParentID: id(99),
                            issues: [.missingParent], ranked: false)
        let result = target(ordinary.item.id, .after, drag([source]),
                            [source, ordinary, recovered])
        XCTAssertNotNil(result)
        XCTAssertNil(result?.beforeID)
    }

    func testBatchAcrossParentsKeepsCapturedSourceOrder() {
        let left = row(1, kind: .folder)
        let right = row(2, kind: .folder)
        let a = row(3, parentID: left.item.id)
        let b = row(4, parentID: right.item.id)
        let destination = row(5, kind: .folder)
        let drag = drag([b, a])
        let result = target(destination.item.id, .into, drag,
                            [a, right, destination, b, left])
        XCTAssertEqual(result?.parentID, destination.item.id)
        XCTAssertEqual(drag.itemIDs, [b.item.id, a.item.id])
        XCTAssertEqual(drag.sources.map(\.parentID),
                       [right.item.id, left.item.id])
    }

    func testSharedDestinationEligibilityAcceptsRootAndNestedFolders() {
        let source = row(1)
        let folder = row(2, kind: .folder)
        let nested = row(3, kind: .folder, parentID: folder.item.id)
        let rows = [source, folder, nested]
        for destination in [nil, folder.item.id, nested.item.id] {
            XCTAssertTrue(allowsDestination(destination, excluding: [source], rows: rows))
        }
        XCTAssertEqual(target(nested.item.id, .into, drag([source]), rows)?.parentID,
                       nested.item.id)
    }

    func testSharedDestinationEligibilityRejectsRecoveredAncestry() {
        let source = row(1)
        let missingParent = row(2, kind: .folder, storedParentID: id(99),
                                issues: [.missingParent])
        let cyclicRoot = row(3, kind: .folder, storedParentID: id(4),
                             issues: [.cycleRecovered])
        let cyclicChild = row(4, kind: .folder, parentID: cyclicRoot.item.id)
        for ancestor in [missingParent, cyclicRoot] {
            let nested = row(5, kind: .folder, parentID: ancestor.item.id)
            let rows = [source, ancestor, nested, cyclicChild]
            XCTAssertFalse(allowsDestination(ancestor.item.id,
                                            excluding: [source], rows: rows))
            XCTAssertFalse(allowsDestination(nested.item.id,
                                            excluding: [source], rows: rows))
            XCTAssertNil(target(nested.item.id, .into, drag([source]), rows))
        }
    }

    func testSharedDestinationEligibilityRejectsUnavailableAndInvalidAncestors() {
        let source = row(1)
        let invalidAncestors = [
            row(2, kind: .folder, isInTrash: true),
            row(2, kind: .folder, deleted: true),
            row(2),
        ]
        for ancestor in invalidAncestors {
            let nested = row(3, kind: .folder, parentID: ancestor.item.id)
            let rows = [source, ancestor, nested]
            XCTAssertFalse(allowsDestination(nested.item.id,
                                            excluding: [source], rows: rows))
            XCTAssertNil(target(nested.item.id, .into, drag([source]), rows))
        }
        let missingAncestor = row(3, kind: .folder, parentID: id(99))
        XCTAssertFalse(allowsDestination(missingAncestor.item.id,
                                        excluding: [source],
                                        rows: [source, missingAncestor]))
        XCTAssertNil(target(missingAncestor.item.id, .into, drag([source]),
                            [source, missingAncestor]))
    }

    func testSharedDestinationEligibilityRejectsCyclesAndSelectedDescendants() {
        let folder = row(1, kind: .folder)
        let nested = row(2, kind: .folder, parentID: folder.item.id)
        XCTAssertFalse(allowsDestination(folder.item.id,
                                        excluding: [folder], rows: [folder, nested]))
        XCTAssertFalse(allowsDestination(nested.item.id,
                                        excluding: [folder], rows: [folder, nested]))
        let a = row(3, kind: .folder, parentID: id(4))
        let b = row(4, kind: .folder, parentID: a.item.id)
        XCTAssertFalse(allowsDestination(a.item.id, excluding: [folder],
                                        rows: [folder, a, b]))
        XCTAssertNil(target(a.item.id, .into, drag([folder]), [folder, a, b]))
    }

    private func allowsDestination(
        _ parentID: UUID?, excluding sources: [NotebookPlacement],
        rows: [NotebookPlacement]
    ) -> Bool {
        NotebookBrowserDragPlacement.allowsDestination(
            parentID, excluding: Set(sources.map(\.item.id)),
            byID: Dictionary(uniqueKeysWithValues: rows.map { ($0.item.id, $0) }))
    }

    private func target(
        _ rowID: UUID?, _ position: NotebookBrowserDropTarget.Position,
        _ drag: NotebookBrowserDrag, _ placements: [NotebookPlacement]
    ) -> NotebookBrowserDropTarget? {
        NotebookBrowserDragPlacement.target(
            rowID: rowID, position: position,
            drag: drag, placements: placements)
    }

    private func drag(_ rows: [NotebookPlacement]) -> NotebookBrowserDrag {
        NotebookBrowserDrag(notebookID: UUID(), sources: rows.map {
            .init(itemID: $0.item.id, parentID: $0.item.parentID)
        })
    }

    private func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format:
            "00000000-0000-0000-0000-%012d", value))!
    }

    private func row(
        _ value: Int, kind: NotebookItemKind = .note,
        parentID: UUID? = nil, storedParentID: UUID? = nil,
        isInTrash: Bool = false, deleted: Bool = false,
        issues: Set<NotebookPlacementIssue> = [], ranked: Bool = true
    ) -> NotebookPlacement {
        let name = "Item \(value)" + (kind == .note ? ".md" : "")
        let item = NotebookItem(
            id: id(value), kind: kind, name: name,
            parentID: storedParentID ?? parentID,
            orderKey: ranked
                ? NotebookOrderKey(rawValue: String(format: "%04x", value))
                : nil,
            isTrashed: isInTrash, isPermanentlyDeleted: deleted,
            importRootID: nil)
        return NotebookPlacement(item: item, parentID: parentID,
            displayName: name, isInTrash: isInTrash, issues: issues)
    }
}
