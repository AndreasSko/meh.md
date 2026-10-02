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
            case .attachmentBrowser: expected = ["Attachments Demo"]
            case .storageLarge: expected = ["Field journals"]
            case .historyRestore: expected = ["Recovery Sketch.md"]
            case .writing: expected = ["Fictional field notes.md", "Save boundary.md"]
            case .syncStatus:
                expected = ["Field notes.md", "Tide chart.md", "Island sketch.md"]
            case .dragOrder: expected = ["Charlie.md", "Alpha.md", "Bravo.md", "Journeys"]
            case .dragNested: expected = ["Travel checklist.md", "Journeys"]
            case .dragSubtree: expected = ["Packing list.md", "Trips", "Archive"]
            case .dragLongList:
                expected = (1 ... 48).map {
                    String(format: "%02d Field observation.md", $0)
                } + ["Journeys"]
            }
            XCTAssertEqual(children.map(\.name), expected)
            if fixture == .attachmentBrowser {
                let descriptors = try replica.attachmentDescriptors()
                XCTAssertEqual(descriptors.count, 2)
                XCTAssertEqual(try replica.attachmentDescriptors(
                    includeTrashed: false).count, 1)
                for descriptor in descriptors {
                    let url = try await replica.attachmentFileURL(for: descriptor.id)
                    let bytes = try Data(contentsOf: url)
                    if replica.placements.first(where: {
                        $0.item.id == descriptor.id
                    })?.item.name == "Discarded sample.bin" {
                        XCTAssertEqual(bytes, Data(repeating: 0xA5, count: 4096))
                    } else {
                        XCTAssertTrue(bytes.starts(with: Data("%PDF-1.4".utf8)))
                    }
                }
            }
            if fixture == .storageLarge {
                let activeNotes = replica.placements.filter {
                    $0.item.kind == .note && !$0.isInTrash
                }
                XCTAssertEqual(activeNotes.count, 320)
                XCTAssertEqual(replica.placements.filter {
                    $0.item.kind == .note && $0.isInTrash
                }.count, 7)
                let large = try XCTUnwrap(activeNotes.first {
                    $0.item.name.hasPrefix("016 ")
                })
                let note = try await replica.openNote(large.item.id)
                XCTAssertGreaterThan(note.text.utf8.count, 100_000)
                XCTAssertTrue(note.text.contains("Fictional revision 4."))
                XCTAssertGreaterThan(try note.historyVersions().count, 1)
                let wrongRun = root.appending(path: "Documents/NotebookPreviewTests/other")
                try await NotebookUITestFixture.seedIfRequested(
                    replica, isPreview: true, directory: directory,
                    documentsDirectory: wrongRun, environment: environment)
                XCTAssertFalse(FileManager.default.fileExists(atPath: wrongRun.path))
                let documents = root.appending(path: "Documents/NotebookPreviewTests/run")
                try await NotebookUITestFixture.seedIfRequested(
                    replica, isPreview: true, directory: directory,
                    documentsDirectory: documents, environment: environment)
                let copies = documents.appending(path: "Notebook Copies/Markdown")
                let files = try XCTUnwrap(FileManager.default.enumerator(
                    at: copies, includingPropertiesForKeys: nil)?.allObjects as? [URL])
                XCTAssertEqual(files.filter { $0.pathExtension == "md" }.count, 320)
                XCTAssertEqual(replica.orderedChildren(parentID: nil).map(\.item.id),
                               children.map(\.id))
            }
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
            if fixture == .syncStatus {
                XCTAssertEqual(try replica.deletedIDs.count, 1)
                XCTAssertEqual(try reopened.deletedIDs, try replica.deletedIDs)
                let statusTransport = NotebookSyncStatusPreviewTransport(
                    runID: "fixture-run"
                )
                XCTAssertEqual(statusTransport.scope, "sync-status-preview-fixture-run")
                XCTAssertNotEqual(
                    statusTransport.scope,
                    NotebookSyncStatusPreviewTransport(runID: "another-run").scope
                )
            }
        }
    }

    func testPreviewReceiveCallbackRoutesThroughTransportProtocol() async throws {
        let transport: any SyncTransport = NotebookSyncStatusPreviewTransport(
            runID: "receive-handler", phaseDelay: .zero
        )
        let capture = PreviewReceiveActivityCapture()
        await transport.setReceiveActivityHandler { activity in
            await capture.record(activity)
        }
        _ = try await transport.fetch(after: nil)
        let activities = await capture.activities
        XCTAssertEqual(activities, [.checkingHistory])

        await transport.setReceiveActivityHandler(nil)
        _ = try await transport.fetch(after: nil)
        let afterClearing = await capture.activities
        XCTAssertEqual(afterClearing, activities)
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
        let syncStatus = preview("sync-status-run", fixture: "sync-status")
        let syncStatusDirectory = URL(
            filePath: "/tmp/NotebookPreviewTests/sync-status-run"
        )
        XCTAssertEqual(
            NotebookUITestFixture.requested(
                environment: syncStatus, isPreview: true,
                directory: syncStatusDirectory
            ),
            .syncStatus
        )
        XCTAssertNil(NotebookUITestFixture.requested(
            environment: syncStatus.merging(
                ["MEH_SYNC_TEST_TRANSPORT": "loopback"]
            ) { _, new in new },
            isPreview: true, directory: syncStatusDirectory
        ))
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
private actor PreviewReceiveActivityCapture {
    private(set) var activities: [SyncReceiveActivity] = []
    func record(_ activity: SyncReceiveActivity) { activities.append(activity) }
}
#endif
