import Foundation
import NoteCore
import TestSupport
import XCTest

@testable import NotebookAppModel

@MainActor
final class NotebookWorkspaceCreateNoteTests: XCTestCase {
    func testOpensTheNotebookWhenTheAppStartedForTheShortcut() async throws {
        let workspace = makeWorkspace()
        XCTAssertNil(workspace.replica)

        async let first = workspace.createNote(text: "Milk\nEggs", name: nil)
        async let second = workspace.createNote(text: "Call Sam", name: nil)
        let ids = try await [first, second]
        await finishStarting(workspace)

        let replica = try XCTUnwrap(workspace.replica)
        let milk = try await replica.openNote(ids[0])
        XCTAssertEqual(milk.text, "Milk\nEggs")
        let today = Date.now.formatted(
            Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
        XCTAssertEqual(
            Set(ids.compactMap { name(of: $0, in: replica) }),
            [today + ".md", today + " 2.md"],
            "Two runs at once must not pick the same name"
        )
    }

    func testSyncsTheNoteWithoutAnActiveWindowAfterReturning() async throws {
        let transport = StallingTransport(scope: "create-note")
        let remote = NotebookReplica(directory: temporaryDirectory())
        let remoteSync = NotebookSyncCoordinator(replica: remote, transport: transport)
        await remoteSync.synchronize()
        let workspace = makeWorkspace(transport: transport, mode: nil)
        await workspace.start()
        await finishStarting(workspace)

        // Sync hangs, as on a slow network. The action must still return,
        // within its time limit, and sync once the network answers.
        await transport.stall()
        let id = try await workspace.createNote(text: "From the Lock Screen", name: "Idea")
        await transport.open()
        await waitUntil {
            await remoteSync.synchronize()
            return remote.placements.contains { $0.item.id == id }
        }
        XCTAssertEqual(
            remote.placements.first { $0.item.id == id }?.item.name, "Idea.md")
    }

    func testUsesTheNewNoteFolderAndNumbersRepeatedNames() async throws {
        let workspace = makeWorkspace()
        await workspace.start()
        let replica = try XCTUnwrap(workspace.replica)
        let inbox = try await replica.createFolder(name: "Inbox")
        try await replica.setDefaultNewNoteParentID(inbox)

        let first = try await workspace.createNote(text: "a", name: "Idea.md")
        let second = try await workspace.createNote(text: "b", name: " idea ")

        XCTAssertEqual(name(of: first, in: replica), "Idea.md")
        XCTAssertEqual(name(of: second, in: replica), "idea 2.md")
        for id in [first, second] {
            XCTAssertEqual(
                replica.placements.first { $0.item.id == id }?.parentID, inbox)
        }
    }

    func testReportsWhyTheNotebookCouldNotOpen() async throws {
        let workspace = makeWorkspace(mode: .invalid)
        do {
            _ = try await workspace.createNote(text: "Lost", name: nil)
            XCTFail("Expected an error without a notebook")
        } catch let error as NotebookUnavailableError {
            XCTAssertEqual(
                error.errorDescription, "Set a valid isolated test workspace.")
        }
    }

    private func name(of id: UUID, in replica: NotebookReplica) -> String? {
        replica.placements.first { $0.item.id == id }?.item.name
    }

    private func waitUntil(_ condition: () async -> Bool) async {
        for _ in 0..<500 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out")
    }

    private func finishStarting(_ workspace: NotebookWorkspace) async {
        while workspace.isLoading { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func makeWorkspace(
        transport: (any SyncTransport)? = nil,
        mode: NotebookWorkspace.Mode? = .local
    ) -> NotebookWorkspace {
        let root = temporaryDirectory()
        return NotebookWorkspace(
            directory: root.appending(path: "Notebook"),
            documentsDirectory: root.appending(path: "Documents"),
            transport: transport, automaticSync: true, mode: mode
        )
    }
}

/// Holds every exchange until `open()`, like a network that doesn't answer.
private actor StallingTransport: SyncTransport {
    nonisolated let scope: String
    private let base: InMemorySyncTransport
    private var isOpen = true
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(scope: String) {
        self.scope = scope
        base = InMemorySyncTransport(scope: scope)
    }

    func stall() { isOpen = false }

    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting = []
    }

    func beginExchange() async throws {
        if !isOpen { await withCheckedContinuation { waiting.append($0) } }
        try await base.beginExchange()
    }

    func endExchange() async { await base.endExchange() }

    func bootstrap(proposing record: SyncRecord) async throws -> SyncRecord {
        try await base.bootstrap(proposing: record)
    }

    func publish(_ record: SyncRecord) async throws {
        try await base.publish(record)
    }

    func fetch(after cursor: String?) async throws -> SyncPage {
        try await base.fetch(after: cursor)
    }
}
