import Foundation
import NoteCore
import XCTest

@testable import NotebookAppModel

@MainActor
final class NotebookNavigationStateTests: XCTestCase {
    func testWindowsKeepIndependentSelectionsAndPositions() async throws {
        let fixture = try await Fixture()
        let first = try await fixture.replica.createNote(name: "First.md")
        let second = try await fixture.replica.createNote(name: "Second.md")
        let firstScene = UUID()
        let secondScene = UUID()
        let firstState = fixture.makeState(sceneID: firstScene)
        let secondState = fixture.makeState(sceneID: secondScene)
        firstState.recordOpened(first)
        firstState.setPosition(Data([1]), for: first)
        secondState.recordOpened(second)
        secondState.setPosition(Data([2]), for: second)

        let restoredFirst = fixture.makeState(sceneID: firstScene)
        let restoredSecond = fixture.makeState(sceneID: secondScene)
        await restoredFirst.restoreLastSelection()
        await restoredSecond.restoreLastSelection()
        XCTAssertEqual(restoredFirst.selectedID, first)
        XCTAssertEqual(restoredSecond.selectedID, second)
        XCTAssertEqual(restoredFirst.position(for: first), Data([1]))
        XCTAssertNil(restoredSecond.position(for: first))
        XCTAssertEqual(restoredSecond.position(for: second), Data([2]))
    }

    func testFirstSceneMigratesLegacySelectionOnlyOnce() async throws {
        let fixture = try await Fixture()
        let note = try await fixture.replica.createNote(name: "Legacy.md")
        fixture.makeState().recordOpened(note)

        let firstScene = UUID()
        let restored = fixture.makeState(sceneID: firstScene)
        let newWindow = fixture.makeState(sceneID: UUID())
        XCTAssertEqual(restored.lastNoteID, note)
        XCTAssertNil(newWindow.lastNoteID)
        await restored.restoreLastSelection()
        XCTAssertEqual(restored.selectedID, note)
        XCTAssertEqual(fixture.makeState(sceneID: firstScene).lastNoteID, note)
    }

    func testRequestedNoteOpensOnlyBeforeSceneHasSavedSelection() async throws {
        let fixture = try await Fixture()
        let saved = try await fixture.replica.createNote(name: "Saved.md")
        let requested = try await fixture.replica.createNote(name: "Requested.md")
        let scene = UUID()
        let state = fixture.makeState(sceneID: scene)
        await state.restoreLastSelection(preferredNoteID: requested)
        XCTAssertEqual(state.selectedID, requested)
        XCTAssertEqual(state.lastNoteID, requested)

        let relaunched = fixture.makeState(sceneID: scene)
        relaunched.recordOpened(saved)
        await relaunched.restoreLastSelection(preferredNoteID: requested)
        XCTAssertEqual(relaunched.selectedID, saved)
        XCTAssertEqual(relaunched.lastNoteID, saved)

        try await fixture.replica.setTrashed(requested, true)
        let freshWindow = fixture.makeState(sceneID: UUID())
        await freshWindow.restoreLastSelection(preferredNoteID: requested)
        XCTAssertNil(freshWindow.selectedID)
    }

    func testClosedWindowDoesNotReopenRequestedNoteOnRelaunch() async throws {
        let fixture = try await Fixture()
        let note = try await fixture.replica.createNote(name: "Opened.md")
        let sceneID = UUID()
        let window = fixture.makeState(sceneID: sceneID)
        await window.restoreLastSelection(preferredNoteID: note)
        XCTAssertEqual(window.selectedID, note)

        window.clearSelection()
        let relaunched = fixture.makeState(sceneID: sceneID)
        await relaunched.restoreLastSelection(preferredNoteID: note)
        XCTAssertNil(relaunched.lastNoteID)
        XCTAssertNil(relaunched.selectedID)
    }

    func testCorruptScenePreferencesAllowRequestedNote() async throws {
        let fixture = try await Fixture()
        let note = try await fixture.replica.createNote(name: "Requested.md")
        let sceneID = UUID()
        let notebookID = try XCTUnwrap(fixture.replica.catalogSnapshot).notebookID
        let key = "meh.md.navigation.\(notebookID.uuidString).scene.\(sceneID.uuidString)"
        fixture.store.set(Data([0, 1, 2]), forKey: key)

        let state = fixture.makeState(sceneID: sceneID)
        await state.restoreLastSelection(preferredNoteID: note)
        XCTAssertEqual(state.selectedID, note)
    }

    func testLeavingNotePreventsRestoreAndReopeningEnablesIt() async throws {
        let fixture = try await Fixture()
        let note = try await fixture.replica.createNote(name: "Moon.md")
        let state = fixture.makeState()
        let session = try await fixture.replica.openNote(note)
        state.installSelection(note, session: session, recordActivity: true)
        try await fixture.replica.recordRecentActivity(for: note)
        state.setPosition(Data([1, 2, 3]), for: note)

        let withOpenNote = fixture.makeState()
        await withOpenNote.restoreLastSelection()
        XCTAssertEqual(withOpenNote.selectedID, note)

        state.recordClosed()
        // Position capture may still run when the app backgrounds.
        state.setPosition(Data([4, 5, 6]), for: note)
        let inBrowser = fixture.makeState()
        await inBrowser.restoreLastSelection()
        XCTAssertNil(inBrowser.lastNoteID)
        XCTAssertNil(inBrowser.selectedID)
        XCTAssertNil(inBrowser.selectedSession)
        XCTAssertEqual(inBrowser.recentNoteIDs, [note])
        XCTAssertEqual(inBrowser.position(for: note), Data([4, 5, 6]))

        // Reopening the retained editor goes through recordOpened.
        state.recordOpened(note)
        let reopened = fixture.makeState()
        await reopened.restoreLastSelection()
        XCTAssertEqual(reopened.selectedID, note)
    }

    func testClearingSelectionAlsoClearsPersistedRestoreTarget() async throws {
        let fixture = try await Fixture()
        let note = try await fixture.replica.createNote(name: "Moon.md")
        let state = fixture.makeState()
        let session = try await fixture.replica.openNote(note)
        state.installSelection(note, session: session, recordActivity: true)

        state.clearSelection()

        XCTAssertNil(state.selectedID)
        XCTAssertNil(state.selectedSession)
        let relaunched = fixture.makeState()
        await relaunched.restoreLastSelection()
        XCTAssertNil(relaunched.lastNoteID)
        XCTAssertNil(relaunched.selectedID)
    }

    func testSortingPreservesLocalRecentsPositionAndEditor() async throws {
        let fixture = try await Fixture()
        let alpha = try await fixture.replica.createNote(name: "Alpha.md")
        let beta = try await fixture.replica.createNote(name: "Beta.md")
        let state = fixture.makeState()
        let session = try await fixture.replica.openNote(alpha)
        state.installSelection(alpha, session: session, recordActivity: true)
        try await fixture.replica.recordRecentActivity(for: alpha)
        try await fixture.replica.recordRecentActivity(for: beta)
        state.setPosition(Data([4, 5, 6]), for: alpha)

        try await fixture.replica.sortChildren(parentID: nil, by: .nameDescending)
        try await fixture.replica.reorder([alpha], parentID: nil, before: beta)
        state.refreshAvailability()

        XCTAssertEqual(state.recentNoteIDs, [beta, alpha])
        XCTAssertEqual(state.position(for: alpha), Data([4, 5, 6]))
        XCTAssertEqual(state.selectedID, alpha)
        XCTAssertIdentical(state.selectedSession, session)
    }

    func testLocalRenamePromotesWithoutReplacingLastEditor() async throws {
        let fixture = try await Fixture()
        let selected = try await fixture.replica.createNote(name: "Open.md")
        let sibling = try await fixture.replica.createNote(name: "Sibling.md")
        let state = fixture.makeState()
        let session = try await fixture.replica.openNote(selected)
        state.installSelection(selected, session: session, recordActivity: true)

        try await fixture.replica.rename(sibling, to: "Renamed.md")

        XCTAssertEqual(state.recentNoteIDs, [sibling])
        XCTAssertEqual(state.selectedID, selected)
        XCTAssertEqual(state.lastNoteID, selected)
        XCTAssertIdentical(state.selectedSession, session)
    }

    func testOpeningPreservesEditedOrderAndRemembersLastNote() async throws {
        let fixture = try await Fixture()
        let first = try await fixture.replica.createNote(name: "First.md")
        let second = try await fixture.replica.createNote(name: "Second.md")
        let unread = try await fixture.replica.createNote(name: "Unread.md")
        let state = fixture.makeState()
        try await fixture.replica.recordRecentActivity(for: first)
        try await fixture.replica.recordRecentActivity(for: second)

        state.recordOpened(first)
        XCTAssertEqual(state.recentNoteIDs, [second, first])
        state.recordOpened(unread)
        XCTAssertEqual(state.recentNoteIDs, [second, first])
        let relaunched = fixture.makeState()
        XCTAssertEqual(relaunched.lastNoteID, unread)
        XCTAssertEqual(relaunched.recentNoteIDs, [second, first])

        try await fixture.replica.recordRecentActivity(for: first)
        XCTAssertEqual(state.recentNoteIDs, [first, second])
    }

    func testExplicitLocalActivityOrdersAndLimitsRecents() async throws {
        let fixture = try await Fixture()
        var ids: [UUID] = []
        for index in 0..<6 {
            ids.append(try await fixture.replica.createNote(name: "\(index).md"))
        }
        let state = fixture.makeState()

        for id in ids { try await fixture.replica.recordRecentActivity(for: id) }
        try await fixture.replica.recordRecentActivity(for: ids[1])

        XCTAssertEqual(state.recentNoteIDs, [ids[1], ids[5], ids[4], ids[3], ids[2]])
        XCTAssertNil(state.lastNoteID)
        XCTAssertNil(state.selectedID)
    }

    func testRenameAndMoveKeepLocalIdentifiersButTrashPrunesThem() async throws {
        let fixture = try await Fixture()
        let folder = try await fixture.replica.createFolder(name: "Folder")
        let note = try await fixture.replica.createNote(name: "One.md")
        let state = fixture.makeState()
        let session = try await fixture.replica.openNote(note)
        state.installSelection(note, session: session, recordActivity: true)
        try await fixture.replica.recordRecentActivity(for: note)
        state.setFolderExpanded(folder, isExpanded: true)
        state.setPosition(Data([1, 2]), for: note)
        await state.loadRecentSessions()
        XCTAssertEqual(Set(state.recentSessions.keys), [note])

        try await fixture.replica.rename(note, to: "Renamed.md")
        try await fixture.replica.move(note, to: folder)
        state.refreshAvailability()
        XCTAssertEqual(state.recentNoteIDs, [note])
        XCTAssertEqual(state.position(for: note), Data([1, 2]))
        XCTAssertTrue(state.expandedFolderIDs.contains(folder))

        try await fixture.replica.setTrashed(note, true)
        state.refreshAvailability()
        XCTAssertEqual(state.selectedID, note)
        XCTAssertIdentical(state.selectedSession, session)
        XCTAssertTrue(state.recentNoteIDs.isEmpty)
        XCTAssertEqual(state.position(for: note), Data([1, 2]))
        await state.loadRecentSessions()
        XCTAssertTrue(state.recentSessions.isEmpty)

        let deletion = try fixture.replica.deletionSelection(rootID: note)
        try await fixture.replica.permanentlyDelete(deletion)
        state.refreshAvailability()
        XCTAssertEqual(state.selectedID, note)
        XCTAssertTrue(session.isPermanentlyDeleted)
        XCTAssertNil(state.position(for: note))
        XCTAssertTrue(state.recentNoteIDs.isEmpty)
    }

    func testPreferencesPersistPerNotebookAndCorruptionIsIgnored() async throws {
        let suite = "NotebookNavigationStateTests-\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let fixture = try await Fixture(store: store)
        let note = try await fixture.replica.createNote(name: "One.md")
        let folder = try await fixture.replica.createFolder(name: "Folder")
        let state = fixture.makeState()
        try await fixture.replica.recordRecentActivity(for: note)
        state.isRecentsExpanded = false
        state.isTreeExpanded = false
        state.isTrashExpanded = true
        state.setFolderExpanded(folder, isExpanded: true)
        state.setPosition(Data([3]), for: note)

        let relaunched = fixture.makeState()
        XCTAssertNil(relaunched.lastNoteID)
        XCTAssertNil(relaunched.selectedID)
        XCTAssertEqual(relaunched.recentNoteIDs, [note])
        XCTAssertFalse(relaunched.isRecentsExpanded)
        XCTAssertFalse(relaunched.isTreeExpanded)
        XCTAssertTrue(relaunched.isTrashExpanded)
        XCTAssertTrue(relaunched.expandedFolderIDs.contains(folder))
        XCTAssertEqual(relaunched.position(for: note), Data([3]))

        let otherNotebook = try await Fixture(store: store)
        _ = try await otherNotebook.replica.createNote(name: "Other.md")
        XCTAssertNil(otherNotebook.makeState().selectedID)
        XCTAssertTrue(otherNotebook.makeState().recentNoteIDs.isEmpty)

        let key = "meh.md.navigation.\(try XCTUnwrap(fixture.replica.catalogSnapshot).notebookID.uuidString)"
        store.set(Data([0, 1, 2]), forKey: key)
        let corrupted = fixture.makeState()
        XCTAssertNil(corrupted.lastNoteID)
        XCTAssertEqual(corrupted.recentNoteIDs, [note])
    }

    func testRenameActivityUpdatesSynchronizedRecency() async throws {
        let fixture = try await Fixture()
        let first = try await fixture.replica.createNote(name: "First.md")
        let second = try await fixture.replica.createNote(name: "Second.md")
        let state = fixture.makeState()
        try await fixture.replica.recordRecentActivity(for: first)

        try await fixture.replica.rename(second, to: "Remote rename.md")
        state.refreshAvailability()

        XCTAssertEqual(state.recentNoteIDs, [second, first])
    }

    func testUnavailableRestoreCandidateKeepsActiveSelection() async throws {
        let fixture = try await Fixture()
        let stale = try await fixture.replica.createNote(name: "Stale.md")
        let active = try await fixture.replica.createNote(name: "Active.md")
        let preferenceWriter = fixture.makeState()
        preferenceWriter.recordOpened(stale)

        let state = fixture.makeState()
        let activeSession = try await fixture.replica.openNote(active)
        try await fixture.replica.setTrashed(stale, true)
        state.installSelection(active, session: activeSession, recordActivity: false)
        await state.restoreLastSelection()

        XCTAssertNil(state.lastNoteID)
        XCTAssertEqual(
            state.restorationMessage,
            "Last note unavailable. Choose another note."
        )
        XCTAssertEqual(state.selectedID, active)
        XCTAssertIdentical(state.selectedSession, activeSession)
    }

    func testMismatchedSessionInstallationLeavesSelectionUntouched() async throws {
        let fixture = try await Fixture()
        let selected = try await fixture.replica.createNote(name: "Selected.md")
        let other = try await fixture.replica.createNote(name: "Other.md")
        let state = fixture.makeState()
        let selectedSession = try await fixture.replica.openNote(selected)
        let otherSession = try await fixture.replica.openNote(other)
        state.installSelection(selected, session: selectedSession, recordActivity: true)

        state.installSelection(other, session: selectedSession, recordActivity: true)

        XCTAssertEqual(state.selectedID, selected)
        XCTAssertIdentical(state.selectedSession, selectedSession)
        XCTAssertEqual(state.lastNoteID, selected)
        XCTAssertTrue(state.recentNoteIDs.isEmpty)
        XCTAssertNotIdentical(state.selectedSession, otherSession)
    }

    func testRemoteMergeUpdatesRecentSessionWithoutReordering() async throws {
        let fixture = try await Fixture()
        var ids: [UUID] = []
        for index in 0..<5 {
            ids.append(try await fixture.replica.createNote(
                name: "\(index).md", text: "local \(index)"
            ))
        }
        let state = fixture.makeState()
        for id in ids { try await fixture.replica.recordRecentActivity(for: id) }
        let expectedOrder = state.recentNoteIDs
        await state.loadRecentSessions()
        XCTAssertEqual(Set(state.recentSessions.keys), Set(ids))

        let id = try XCTUnwrap(expectedOrder.first)
        let remoteRoot = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString
        )
        defer { try? FileManager.default.removeItem(at: remoteRoot) }
        try FileManager.default.copyItem(at: fixture.root, to: remoteRoot)
        let remote = NotebookReplica(directory: remoteRoot)
        try await remote.load()
        let remoteSession = try await remote.openNote(id)
        try remoteSession.replaceAll(with: "changed remotely")
        try await remoteSession.flush()
        let remoteSnapshot = try XCTUnwrap(remoteSession.currentSnapshot)

        let localSession = try XCTUnwrap(state.recentSessions[id])
        try localSession.mergeRemote(remoteSnapshot)

        XCTAssertEqual(localSession.text, "changed remotely")
        XCTAssertEqual(state.recentSessions[id]?.text, "changed remotely")
        XCTAssertEqual(state.recentNoteIDs, expectedOrder)
    }
}

@MainActor
private final class Fixture {
    let root: URL
    let replica: NotebookReplica
    let store: UserDefaults
    private let ownedSuiteName: String?

    init(store: UserDefaults? = nil) async throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        replica = NotebookReplica(directory: root)
        if let store {
            self.store = store
            ownedSuiteName = nil
        } else {
            let suiteName = UUID().uuidString
            self.store = UserDefaults(suiteName: suiteName)!
            ownedSuiteName = suiteName
        }
        try await replica.load()
        try await replica.createLocalNotebook()
    }

    isolated deinit {
        try? FileManager.default.removeItem(at: root)
        if let ownedSuiteName {
            store.removePersistentDomain(forName: ownedSuiteName)
        }
    }

    func makeState(sceneID: UUID? = nil) -> NotebookNavigationState {
        NotebookNavigationState(replica: replica, store: store, sceneID: sceneID)
    }
}
