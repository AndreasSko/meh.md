import Foundation
import XCTest

@testable import NoteCore

@MainActor
final class NoteSessionTests: XCTestCase {
    func testSlowWriteDoesNotAcknowledgeOrOverwriteLaterTyping() async throws {
        let initial = try NoteDocument(text: "initial").snapshot()
        let storage = ControlledStorage(loadResult: .current(initial))
        await storage.setPaused(true)
        let session = NoteSession(storage: storage)
        await session.load()

        XCTAssertEqual(session.persistedSnapshot, initial)

        try session.replaceAll(with: "first")
        await waitUntil { await storage.saveCount == 1 }
        try session.replaceAll(with: "second")
        XCTAssertEqual(session.persistedSnapshot, initial)
        await storage.releaseOneSave()
        await waitUntil { await storage.saveCount == 2 }

        XCTAssertEqual(session.text, "second")
        XCTAssertEqual(session.status, .saving)
        XCTAssertEqual(
            try NoteDocument(snapshot: XCTUnwrap(session.persistedSnapshot)).text,
            "first"
        )

        await storage.releaseOneSave()
        await waitUntil { session.status == .saved }
        let saved = await storage.savedSnapshots
        XCTAssertEqual(saved.count, 2)
        XCTAssertEqual(try NoteDocument(snapshot: saved[0]).text, "first")
        XCTAssertEqual(try NoteDocument(snapshot: saved[1]).text, "second")
        XCTAssertEqual(session.text, "second")
        XCTAssertEqual(session.persistedSnapshot, saved.last)
    }

    func testFailurePreservesTextAndLaterEditRetries() async throws {
        let initial = try NoteDocument(text: "initial").snapshot()
        let storage = ControlledStorage(loadResult: .current(initial))
        await storage.failNextSave()
        let session = NoteSession(storage: storage)
        await session.load()

        try session.replaceAll(with: "unsaved")
        await waitUntil {
            if case .saveFailed = session.status { return true }
            return false
        }

        XCTAssertEqual(session.text, "unsaved")
        XCTAssertTrue(session.isEditingEnabled)

        try session.replaceAll(with: "retry latest")
        await waitUntil { session.status == .saved }
        let saved = await storage.savedSnapshots
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(
            try NoteDocument(snapshot: saved[0]).text,
            "retry latest"
        )
    }

    func testPausedFailureKeepsLatestTypingForExplicitRetry() async throws {
        let initial = try NoteDocument(text: "initial").snapshot()
        let storage = ControlledStorage(loadResult: .current(initial))
        await storage.setPaused(true)
        await storage.failNextSave()
        let session = NoteSession(storage: storage)
        await session.load()

        try session.replaceAll(with: "first")
        await waitUntil { await storage.saveCount == 1 }
        try session.replaceAll(with: "latest")
        await storage.releaseOneSave()
        await waitUntil {
            if case .saveFailed = session.status { return true }
            return false
        }

        XCTAssertEqual(session.text, "latest")
        session.retrySave()
        await waitUntil { await storage.saveCount == 1 }
        await storage.releaseOneSave()
        await waitUntil { session.status == .saved }
        let saved = await storage.savedSnapshots
        XCTAssertEqual(try NoteDocument(snapshot: saved[0]).text, "latest")
    }

    func testRepeatedLoadCannotReplaceTextDuringSave() async throws {
        let initial = try NoteDocument(text: "initial").snapshot()
        let storage = ControlledStorage(loadResult: .current(initial))
        await storage.setPaused(true)
        let session = NoteSession(storage: storage)
        await session.load()
        try session.replaceAll(with: "editing")
        await waitUntil { await storage.saveCount == 1 }

        await session.load()

        XCTAssertEqual(session.text, "editing")
        XCTAssertEqual(session.status, .saving)
        await storage.releaseOneSave()
        await waitUntil { session.status == .saved }
    }

    func testRecoveryFailureKeepsEditingBlockedAndCanRetry() async throws {
        let previous = try NoteDocument(text: "known good").snapshot()
        let recovery = NoteRecovery(
            previous: previous,
            currentFailure: .corrupt
        )
        let storage = ControlledStorage(
            loadResult: .recoveryRequired(recovery)
        )
        await storage.failNextRecovery()
        let session = NoteSession(storage: storage)
        await session.load()

        await session.recoverFromPrevious()
        XCTAssertFalse(session.isEditingEnabled)
        XCTAssertNotNil(session.recoveryErrorMessage)

        await session.recoverFromPrevious()
        XCTAssertEqual(session.text, "known good")
        XCTAssertEqual(session.status, .saved)
        XCTAssertTrue(session.isEditingEnabled)
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () async -> Bool
    ) async {
        for _ in 0 ..< 1_000 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("Condition did not become true")
    }
}

private enum ControlledStorageError: Error {
    case injected
}

private actor ControlledStorage: NoteStorage {
    private let loadResult: NoteLoadResult
    private var paused = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var failSave = false
    private var failRecovery = false
    private(set) var savedSnapshots: [NoteSnapshot] = []

    var saveCount: Int { savedSnapshots.count + continuations.count }

    init(loadResult: NoteLoadResult) {
        self.loadResult = loadResult
    }

    func load() -> NoteLoadResult {
        loadResult
    }

    func save(_ snapshot: NoteSnapshot) async throws {
        if paused {
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
            }
        }
        if failSave {
            failSave = false
            throw ControlledStorageError.injected
        }
        savedSnapshots.append(snapshot)
    }

    func recover(_ recovery: NoteRecovery) throws -> NoteSnapshot {
        if failRecovery {
            failRecovery = false
            throw ControlledStorageError.injected
        }
        return recovery.previous
    }

    func setPaused(_ paused: Bool) {
        self.paused = paused
    }

    func releaseOneSave() {
        continuations.removeFirst().resume()
    }

    func failNextSave() {
        failSave = true
    }

    func failNextRecovery() {
        failRecovery = true
    }
}
