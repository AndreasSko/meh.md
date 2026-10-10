import Foundation
import XCTest
import NoteCore
@testable import NotebookAppModel

#if DEBUG
@MainActor
final class NotebookUITestFixtureTests: XCTestCase {
    func testEachFixturePersistsItsHierarchyAndStableIDs() async throws {
        for fixture in NotebookUITestFixture.allCases {
            let root = FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let directory = root.appending(path: "NotebookPreviewTests/run")
            let environment = preview("run", fixture: fixture.rawValue)
            let replica = NotebookReplica(directory: directory)
            try await replica.createLocalNotebook()
            try await NotebookUITestFixture.seedIfRequested(
                replica, isPreview: true, directory: directory,
                environment: environment)
            let children = replica.orderedChildren(parentID: nil).map(\.item)
            let expected: [String]
            switch fixture {
            case .historyRestore: expected = ["Recovery Sketch.md"]
            case .writing: expected = ["Fictional field notes.md", "Save boundary.md"]
            case .dragOrder: expected = ["Charlie.md", "Alpha.md", "Bravo.md", "Journeys"]
            case .dragNested: expected = ["Travel checklist.md", "Journeys"]
            case .dragSubtree: expected = ["Packing list.md", "Trips", "Archive"]
            case .dragLongList:
                expected = (1 ... 48).map {
                    String(format: "%02d Field observation.md", $0)
                } + ["Journeys"]
            }
            XCTAssertEqual(children.map(\.name), expected)
            if fixture == .writing || fixture == .dragOrder {
                let note = try await replica.openNote(children[fixture == .writing ? 0 : 2].id)
                XCTAssertEqual(note.text, NotebookUITestFixture.literalSource)
            }
            if fixture == .dragOrder {
                for child in children.prefix(3) {
                    let note = try await replica.openNote(child.id)
                    XCTAssertEqual(note.text, child.name == "Bravo.md"
                        ? NotebookUITestFixture.literalSource
                        : "# Fictional \(child.name.replacingOccurrences(of: ".md", with: ""))")
                }
            }
            if let folder = children.first(where: { $0.name == "Journeys" }) {
                let weekend = try XCTUnwrap(
                    replica.orderedChildren(parentID: folder.id).first?.item)
                XCTAssertEqual(weekend.name, "Weekend")
                XCTAssertEqual(
                    replica.orderedChildren(parentID: weekend.id).map(\.item.name),
                    fixture == .dragLongList ? ["Island.md"] : [])
            }
            if let trips = children.first(where: { $0.name == "Trips" }) {
                XCTAssertEqual(replica.orderedChildren(parentID: trips.id)
                    .map(\.item.name), ["Island"])
            }
            let reopened = NotebookReplica(directory: directory)
            try await reopened.load()
            try await NotebookUITestFixture.seedIfRequested(
                reopened, isPreview: true, directory: directory,
                environment: environment)
            XCTAssertEqual(reopened.orderedChildren(parentID: nil).map(\.item.id),
                           children.map(\.id))
            if fixture == .dragOrder {
                let journeys = try XCTUnwrap(children.first { $0.name == "Journeys" })
                let originalChildren = replica.orderedChildren(parentID: journeys.id)
                    .map(\.item)
                let reopenedChildren = reopened.orderedChildren(parentID: journeys.id)
                    .map(\.item)
                XCTAssertEqual(reopenedChildren.map(\.id), originalChildren.map(\.id))
                XCTAssertEqual(reopenedChildren.map(\.name), ["Weekend"])
            }
            if fixture == .historyRestore {
                let session = try await reopened.openNote(children[0].id)
                XCTAssertEqual(session.text, NotebookUITestFixture.historyCurrentSource)
                let versions = try session.historyVersions()
                XCTAssertFalse(versions.isEmpty)
                XCTAssertTrue(try versions.map { try session.historicalText(for: $0) }
                    .contains(NotebookUITestFixture.historyOriginalSource))
            }
        }
    }

    func testMalformedOrUnisolatedRequestsCannotSeed() {
        let directory = URL(filePath: "/tmp/NotebookPreviewTests/run")
        let valid = preview("run", fixture: "writing")
        XCTAssertNil(NotebookUITestFixture.requested(
            environment: [:], isPreview: true, directory: directory))
        XCTAssertNil(NotebookUITestFixture.requested(
            environment: valid.filter { $0.key != "MEH_NOTEBOOK_TEST_FIXTURE" },
            isPreview: true, directory: directory))
        XCTAssertEqual(NotebookUITestFixture.requested(
            environment: valid, isPreview: true, directory: directory), .writing)
        for changes in [
            ["MEH_NOTEBOOK_PREVIEW_RUN": "../run"],
            ["MEH_NOTEBOOK_PREVIEW": "0"],
            ["MEH_SYNC_URL": "http://127.0.0.1"],
            ["MEH_SYNC_CLOUDKIT": "1"],
            ["MEH_NOTEBOOK_TEST_FIXTURE": "unknown"]
        ] {
            XCTAssertNil(NotebookUITestFixture.requested(
                environment: valid.merging(changes) { _, new in new },
                isPreview: true, directory: directory))
        }
        XCTAssertNil(NotebookUITestFixture.requested(
            environment: valid, isPreview: false, directory: directory))
        XCTAssertNil(NotebookUITestFixture.requested(
            environment: valid, isPreview: true,
            directory: URL(filePath: "/tmp/Notebook/run")))
        let legacy = ["MEH_NOTEBOOK_PREVIEW": "1",
                      "MEH_NOTEBOOK_PREVIEW_RUN": "run",
                      "MEH_NOTEBOOK_DRAG_FIXTURE": "nested"]
        XCTAssertNil(NotebookUITestFixture.requested(
            environment: legacy, isPreview: true, directory: directory))
    }

    func testExplicitPreviewRequestsFailClosedWithoutChangingOrdinaryRouting() {
        XCTAssertEqual(NotebookWorkspace.previewRequest(environment: [:]), .none)
        XCTAssertEqual(NotebookWorkspace.previewRequest(
            environment: ["MEH_NOTEBOOK_PREVIEW": "0"]), .none)
        let valid = preview("run", fixture: "writing")
        XCTAssertEqual(NotebookWorkspace.previewRequest(environment: valid), .valid("run"))
        for changes in [
            ["MEH_NOTEBOOK_PREVIEW_RUN": "../personal"],
            ["MEH_NOTEBOOK_PREVIEW_RUN": ""],
            ["MEH_SYNC_URL": "http://127.0.0.1"],
            ["MEH_SYNC_CLOUDKIT": "1"],
            ["MEH_SYNC_TEST_TRANSPORT": "loopback"]
        ] {
            XCTAssertEqual(NotebookWorkspace.previewRequest(
                environment: valid.merging(changes) { _, new in new }), .invalid)
        }
        XCTAssertEqual(NotebookWorkspace.previewRequest(
            environment: ["MEH_NOTEBOOK_PREVIEW": "1"]), .invalid)
    }

    private func preview(_ run: String, fixture: String) -> [String: String] {
        ["MEH_NOTEBOOK_PREVIEW": "1", "MEH_NOTEBOOK_PREVIEW_RUN": run,
         "MEH_NOTEBOOK_TEST_FIXTURE": fixture]
    }
}
#endif
