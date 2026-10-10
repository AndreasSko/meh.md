#if NOTEBOOK_CLOUD_UI_LAB
import Foundation
import XCTest
@testable import NotebookAppModel

@MainActor
final class NotebookCloudUITestScopeTests: XCTestCase {
    func testMissingOrInvalidIdentityCannotSelectOrdinaryStorage() {
        for value in [nil, "", "Notebook", "../Notebook", "not-a-uuid"] {
            XCTAssertNil(NotebookCloudUITestScope(runID: value))
        }
        let workspace = NotebookWorkspace()
        guard case .invalid = workspace.mode else {
            return XCTFail("A lab binary without its bundled identity must fail closed")
        }
        XCTAssertFalse(workspace.usesSync)
        XCTAssertTrue(workspace.directory.path.contains("CloudKitUITests/invalid-configuration"))
        XCTAssertFalse(NotebookWorkspace.isPreviewEnabled)
    }

    func testLabIdentityProducesOnlyItsOwnStableDirectory() throws {
        let id = UUID()
        let scope = try XCTUnwrap(NotebookCloudUITestScope(runID: id.uuidString))
        XCTAssertEqual(scope.runID, id)
        XCTAssertEqual(scope.directoryComponent, "CloudKitUITests/" + id.uuidString.lowercased())
        let other = try XCTUnwrap(NotebookCloudUITestScope(runID: UUID().uuidString))
        XCTAssertNotEqual(scope.directoryComponent, other.directoryComponent)
    }
}
#endif
