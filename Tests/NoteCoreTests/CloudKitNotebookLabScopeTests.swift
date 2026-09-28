import Foundation
import XCTest

@testable import NoteCore

final class CloudKitNotebookLabScopeTests: XCTestCase {
    private let firstRun = UUID(
        uuidString: "9D584D35-1A0B-4326-8F5E-C3396F6F130E"
    )!
    private let secondRun = UUID(
        uuidString: "E6290B3B-90EC-4BE0-83CC-E5CDE173395D"
    )!

    func testLabZoneIsDerivedAndDisjointFromCanonicalNotebook() throws {
        let zone = CloudKitNotebookLabScope.zoneName(runID: firstRun)
        XCTAssertEqual(
            zone,
            "meh-md-notebook-lab-v2-9d584d35-1a0b-4326-8f5e-c3396f6f130e"
        )
        XCTAssertNotEqual(zone, CloudKitTransportMode.notebook.zoneName)
        XCTAssertNotEqual(
            zone, CloudKitNotebookLabScope.zoneName(runID: secondRun)
        )
        XCTAssertNoThrow(try CloudKitNotebookLabScope.validate(
            zoneName: zone, runID: firstRun
        ))
        XCTAssertThrowsError(try CloudKitTransportMode.notebook.validate(
            zoneName: zone
        )) { error in
            XCTAssertEqual(error as? SyncError, .scopeChanged)
        }
    }

    func testLabRejectsCanonicalCustomAndWrongRunZones() {
        let firstZone = CloudKitNotebookLabScope.zoneName(runID: firstRun)
        let rejected = [
            CloudKitTransportMode.notebook.zoneName,
            CloudKitTransportMode.legacy.zoneName,
            "custom-v2",
            CloudKitNotebookLabScope.zoneName(runID: secondRun),
            firstZone.uppercased(),
        ]
        for zone in rejected {
            XCTAssertThrowsError(try CloudKitNotebookLabScope.validate(
                zoneName: zone, runID: firstRun
            )) { error in
                XCTAssertEqual(error as? SyncError, .scopeChanged)
            }
        }
    }

    func testLabStateIsNestedUnderRunSpecificDirectory() {
        let base = URL(fileURLWithPath: "/fictional/cloudkit-state")
        let first = CloudKitNotebookLabScope.stateDirectory(
            base: base, runID: firstRun
        )
        let second = CloudKitNotebookLabScope.stateDirectory(
            base: base, runID: secondRun
        )
        XCTAssertEqual(
            first,
            base.appendingPathComponent(
                "notebook-lab-9d584d35-1a0b-4326-8f5e-c3396f6f130e",
                isDirectory: true
            )
        )
        XCTAssertNotEqual(first, base)
        XCTAssertNotEqual(first, second)
    }
}
