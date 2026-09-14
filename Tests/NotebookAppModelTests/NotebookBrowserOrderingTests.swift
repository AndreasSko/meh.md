import XCTest

@testable import NotebookAppModel

@MainActor
final class NotebookBrowserOrderingTests: XCTestCase {
    private let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let third = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    func testReorderPreservesSourceOrderAndParent() {
        let parent = UUID()
        let request = NotebookBrowserOrdering.request(
            sources: [third, first],
            before: second,
            parentID: parent,
            siblingIDs: [first, second, third]
        )

        XCTAssertEqual(
            request,
            NotebookBrowserReorderRequest(
                sources: [first, third], parentID: parent, before: second
            )
        )
    }

    func testNoOpAndForeignSourcesAreRejected() {
        XCTAssertNil(NotebookBrowserOrdering.request(
            sources: [first], before: second, parentID: nil,
            siblingIDs: [first, second, third]
        ))
        XCTAssertNil(NotebookBrowserOrdering.request(
            sources: [UUID()], before: second, parentID: nil,
            siblingIDs: [first, second, third]
        ))
    }

    func testMoveUpAndDownUseBeforeOrEnd() {
        XCTAssertEqual(
            NotebookBrowserOrdering.moveUpRequest(
                id: second, parentID: nil,
                siblingIDs: [first, second, third]
            )?.before,
            first
        )
        XCTAssertEqual(
            NotebookBrowserOrdering.moveDownRequest(
                id: second, parentID: nil,
                siblingIDs: [first, second, third]
            )?.before,
            nil
        )
        XCTAssertNil(NotebookBrowserOrdering.moveUpRequest(
            id: first, parentID: nil,
            siblingIDs: [first, second, third]
        ))
        XCTAssertNil(NotebookBrowserOrdering.moveDownRequest(
            id: third, parentID: nil,
            siblingIDs: [first, second, third]
        ))
    }

}
