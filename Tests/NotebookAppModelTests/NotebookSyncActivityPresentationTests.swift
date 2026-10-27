import Foundation
import NoteCore
import XCTest
import TestSupport
@testable import NotebookAppModel

@MainActor
final class NotebookSyncActivityPresentationTests: XCTestCase {
    func testWeightedProgressAppliesToAllActivePhasesAndHidesAfterFailure() {
        let progress = NotebookSyncProgress(
            phase: .receiving, receivedRecords: 2, completedNotes: 0,
            totalNotes: 0, lastProgressAt: Date(), overallFraction: 0.2,
            waitingSince: Date(timeIntervalSince1970: 10)
        )
        let active = NotebookSyncActivityPresentation(isActive: true, progress: progress)
        XCTAssertEqual(active.fraction, 0.2)
        XCTAssertEqual(String(localized: active.title), "Waiting for iCloud…")
        XCTAssertEqual(String(localized: active.detail(at: Date(timeIntervalSince1970: 55))!),
                       "Waiting for 45 seconds")
        XCTAssertNil(NotebookSyncActivityPresentation(isActive: false, progress: progress).fraction)
    }

    func testVerifyingSavedStateShowsItsCountWithoutAFraction() {
        let verifying = NotebookSyncProgress(
            phase: .verifyingSavedState, receivedRecords: 0,
            completedNotes: 0, totalNotes: 0, lastProgressAt: Date(),
            completedUnits: 120, totalUnits: 300
        )
        let activity = NotebookSyncActivityPresentation(isActive: true, progress: verifying)
        XCTAssertEqual(String(localized: activity.title), "Verifying saved sync data…")
        XCTAssertEqual(String(localized: activity.detail(at: Date())!),
                       "120 of 300 saved items verified")
        XCTAssertEqual(String(localized: activity.hint!),
                       "Usually once after an app update, before sync starts")
        XCTAssertNil(activity.fraction)
    }

    func testRemoteHistoryShowsLocalCheckingWithoutInventedCounts() {
        let local = NotebookSyncProgress(
            phase: .checkingRemoteHistory, receivedRecords: 0,
            completedNotes: 0, totalNotes: 0, lastProgressAt: Date(),
            overallFraction: 0.2
        )
        let activity = NotebookSyncActivityPresentation(isActive: true, progress: local)
        XCTAssertEqual(String(localized: activity.title), "Checking iCloud history…")
        XCTAssertEqual(activity.fraction, 0.2)
        XCTAssertNil(activity.detail(at: Date()))
        XCTAssertNil(activity.hint)

        let waiting = NotebookSyncProgress(
            phase: .checkingRemoteHistory, receivedRecords: 0,
            completedNotes: 0, totalNotes: 0, lastProgressAt: Date(),
            overallFraction: 0.2, waitingSince: Date(timeIntervalSince1970: 10)
        )
        let wait = NotebookSyncActivityPresentation(isActive: true, progress: waiting)
        XCTAssertEqual(String(localized: wait.title), "Waiting for iCloud…")
        XCTAssertEqual(wait.fraction, 0.2)
    }

    func testOnlyActiveNoteUploadsHaveAFractionAndFilenames() {
        let id = UUID()
        let upload = progress(phase: .uploadingNotes, ids: [id])
        let active = NotebookSyncActivityPresentation(isActive: true, progress: upload)
        XCTAssertEqual(active.fraction, 0.4)
        XCTAssertEqual(active.activeNoteIDs, [id])
        let stale = NotebookSyncActivityPresentation(isActive: false, progress: upload)
        XCTAssertNil(stale.fraction)
        XCTAssertTrue(stale.activeNoteIDs.isEmpty)
        for phase: NotebookSyncProgress.Phase in [
            .checking, .checkingRemoteHistory, .receiving, .uploadingCatalog,
            .cleaningUp, .cleaningUpSnapshots
        ] {
            XCTAssertNil(NotebookSyncActivityPresentation(
                isActive: true, progress: progress(phase: phase)
            ).fraction)
        }
    }

    func testUnknownAndInvalidTotalsCannotProduceInvalidProgress() {
        let unknown = progress(phase: .uploadingNotes, total: 0)
        XCTAssertNil(NotebookSyncActivityPresentation(isActive: true, progress: unknown).fraction)
        XCTAssertEqual(NotebookSyncActivityPresentation(
            isActive: true, progress: progress(phase: .uploadingNotes, total: 1)
        ).fraction, 1)
    }

    func testResolutionRetainsUnknownIDsAndDisambiguatesDuplicateNames() async throws {
        let directory = temporaryDirectory()
        let replica = NotebookReplica(directory: directory)
        try await replica.load()
        try await replica.createLocalNotebook()
        let firstFolder = try await replica.createFolder(name: "Trips")
        let secondFolder = try await replica.createFolder(name: "Home")
        let first = try await replica.createNote(name: "Plans.md", text: "Fictional", parentID: firstFolder)
        let second = try await replica.createNote(name: "Plans.md", text: "Fictional", parentID: secondFolder)
        let unknown = UUID()
        let files = NotebookSyncActiveFile.resolve(
            ids: [first, second, unknown, first], placements: replica.placements
        )
        XCTAssertEqual(files.map(\.id), [first, second, unknown])
        XCTAssertEqual(files[0].name, "Plans.md")
        XCTAssertEqual(files[0].folder, "Trips")
        XCTAssertEqual(files[1].folder, "Home")
        XCTAssertNil(files[2].name)
    }

    private func progress(
        phase: NotebookSyncProgress.Phase, total: Int = 5, ids: [UUID] = []
    ) -> NotebookSyncProgress {
        NotebookSyncProgress(phase: phase, receivedRecords: 0, completedNotes: 2,
                             totalNotes: total, lastProgressAt: Date(), activeNoteIDs: ids)
    }
}
