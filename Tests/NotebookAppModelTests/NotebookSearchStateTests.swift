import Foundation
import XCTest

@testable import NotebookAppModel
@testable import NoteCore

@MainActor
final class NotebookSearchStateTests: XCTestCase {
    func testNewQueryCannotPublishEarlierQueryResults() async throws {
        let fixture = try await makeReplica([
            ("Apple.md", "red fruit"),
            ("Banana.md", "yellow fruit"),
        ])
        let state = NotebookSearchState()
        state.isPresented = true
        state.query = "apple"
        let first = Task { await state.refresh(replica: fixture.replica, recentIDs: []) }
        try await Task.sleep(for: .milliseconds(20))
        state.query = "banana"
        let second = Task { await state.refresh(replica: fixture.replica, recentIDs: []) }

        await first.value
        await second.value

        XCTAssertEqual(state.results.map(\.title), ["Banana"])
        XCTAssertFalse(state.isPreparing)
    }

    func testSameNotebookRowsRemainUntilReplacementIsReady() async throws {
        let fixture = try await makeReplica([
            ("Apple.md", "red fruit"),
            ("Banana.md", "yellow fruit"),
        ])
        let state = NotebookSearchState()
        state.isPresented = true
        state.query = "apple"
        await state.refresh(replica: fixture.replica, recentIDs: [])
        XCTAssertEqual(state.results.map(\.title), ["Apple"])
        _ = try await fixture.replica.createFolder(name: "Orchard")
        state.query = "banana"

        let refresh = Task {
            await state.refresh(replica: fixture.replica, recentIDs: [])
        }
        for _ in 0..<100 where !state.isPreparing { await Task.yield() }

        XCTAssertTrue(state.isPreparing)
        XCTAssertEqual(state.results.map(\.title), ["Apple"])
        XCTAssertEqual(state.resultQuery, "apple")
        await refresh.value
        XCTAssertEqual(state.results.map(\.title), ["Banana"])
        XCTAssertEqual(state.resultQuery, "banana")
    }

    func testCancellingLatestRequestEndsPreparingState() async throws {
        let fixture = try await makeReplica([("Orbit.md", "Europa")])
        let state = NotebookSearchState()
        state.isPresented = true
        state.query = "Europa"
        let task = Task { await state.refresh(replica: fixture.replica, recentIDs: []) }
        try await Task.sleep(for: .milliseconds(20))

        task.cancel()
        await task.value

        XCTAssertFalse(state.isPreparing)
        XCTAssertNil(state.error)
    }

    func testCancelledQueryStillCachesCompletedCorpus() async throws {
        let fixture = try await makeReplica([("Orbit.md", "before")])
        let state = NotebookSearchState()
        state.isPresented = true
        state.query = "before"
        let task = Task {
            await state.refresh(replica: fixture.replica, recentIDs: [])
        }
        for _ in 0..<100 where !state.isPreparing { await Task.yield() }
        task.cancel()
        await task.value

        guard case .current(let snapshot) = await fixture.replica
            .noteStorage(fixture.ids[0]).load() else {
            return XCTFail("Expected stored note")
        }
        let changed = try NoteDocument(snapshot: snapshot)
        try changed.replaceAll(with: "after")
        try await fixture.replica.noteStorage(fixture.ids[0]).save(changed.snapshot())

        await state.refresh(replica: fixture.replica, recentIDs: [])

        XCTAssertEqual(state.results.map(\.id), fixture.ids)
    }

    func testSwitchingNotebookCannotRetainPriorRowsOrSelection() async throws {
        let first = try await makeReplica([("First.md", "shared phrase")])
        let second = try await makeReplica([("Second.md", "shared phrase")])
        let state = NotebookSearchState()
        state.isPresented = true
        state.query = "shared"
        await state.refresh(replica: first.replica, recentIDs: [])
        state.selectedResultID = first.ids[0]

        await state.refresh(replica: second.replica, recentIDs: [])

        XCTAssertEqual(state.results.map(\.id), [second.ids[0]])
        XCTAssertFalse(state.results.contains { $0.id == first.ids[0] })
        XCTAssertNil(state.selectedResultID)
    }

    func testQuickOpenDoesNotReplaceSelectionRemovedBySameQueryRefresh() async throws {
        let fixture = try await makeReplica([
            ("Europa.md", "moon shared"),
            ("Titan.md", "moon shared"),
        ])
        let state = NotebookSearchState()
        state.showingQuickOpen = true
        await state.refresh(replica: fixture.replica, recentIDs: fixture.ids)
        XCTAssertEqual(state.quickSelectionID, fixture.ids[0])
        state.quickSelectionID = fixture.ids[1]

        state.quickQuery = "shared"
        await state.refresh(replica: fixture.replica, recentIDs: fixture.ids)
        XCTAssertEqual(state.quickSelectionID, fixture.ids[1])

        try await fixture.replica.setTrashed(fixture.ids[1], true)
        await state.refresh(replica: fixture.replica, recentIDs: fixture.ids)
        XCTAssertEqual(state.results.map(\.id), [fixture.ids[0]])
        XCTAssertNil(state.quickSelectionID)

        state.quickQuery = "Europa"
        await state.refresh(replica: fixture.replica, recentIDs: fixture.ids)
        XCTAssertEqual(state.quickSelectionID, fixture.ids[0])
    }

    func testBeginningQuickOpenKeepsQueryForRetainedRows() async throws {
        let fixture = try await makeReplica([("Europa.md", "hidden ocean")])
        let state = NotebookSearchState()
        state.isPresented = true
        state.query = "ocean"
        await state.refresh(replica: fixture.replica, recentIDs: [])
        XCTAssertEqual(state.results.map(\.id), fixture.ids)

        state.isPresented = false
        state.beginQuickOpen()

        XCTAssertEqual(state.results.map(\.id), fixture.ids)
        XCTAssertEqual(state.resultQuery, "ocean")
    }

    func testEquivalentRevisionFromAnotherReplicaRebuildsCorpus() async throws {
        let fixture = try await makeReplica([("One.md", "before")])
        let first = NotebookReplica(directory: fixture.replica.directory)
        try await first.load()
        let replacement = NotebookReplica(directory: fixture.replica.directory)
        try await replacement.load()
        XCTAssertEqual(replacement.searchRevision, first.searchRevision)
        let state = NotebookSearchState()
        state.isPresented = true
        state.query = "before"
        await state.refresh(replica: first, recentIDs: [])
        XCTAssertEqual(state.results.map(\.id), fixture.ids)

        guard case .current(let snapshot) = await replacement
            .noteStorage(fixture.ids[0]).load() else {
            return XCTFail("Expected stored note")
        }
        let document = try NoteDocument(snapshot: snapshot)
        try document.replaceAll(with: "after")
        try await replacement.noteStorage(fixture.ids[0]).save(document.snapshot())
        XCTAssertEqual(replacement.searchRevision, first.searchRevision)

        state.query = "after"
        await state.refresh(replica: replacement, recentIDs: [])

        XCTAssertEqual(state.results.map(\.id), fixture.ids)
    }

    func testEmptyQuickOpenUsesUniqueRecentsAndCanBeEmpty() async throws {
        let fixture = try await makeReplica([
            ("One.md", "first"),
            ("Two.md", "second"),
        ])
        let state = NotebookSearchState()
        state.showingQuickOpen = true

        await state.refresh(replica: fixture.replica, recentIDs: [])
        XCTAssertTrue(state.results.isEmpty)
        XCTAssertNil(state.quickSelectionID)

        await state.refresh(
            replica: fixture.replica,
            recentIDs: [fixture.ids[1], fixture.ids[1], fixture.ids[0]]
        )
        XCTAssertEqual(state.results.map(\.id), [fixture.ids[1], fixture.ids[0]])
    }

    private func makeReplica(_ notes: [(String, String)]) async throws
        -> (replica: NotebookReplica, ids: [UUID])
    {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let replica = NotebookReplica(directory: directory)
        try await replica.createLocalNotebook()
        var ids: [UUID] = []
        for (name, text) in notes {
            ids.append(try await replica.createNote(name: name, text: text))
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (replica, ids)
    }
}
