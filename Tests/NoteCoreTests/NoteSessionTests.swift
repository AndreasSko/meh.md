import Foundation
import XCTest

@testable import NoteCore

@MainActor
final class NoteSessionTests: XCTestCase {
    func testSlowWriteDoesNotAcknowledgeOrOverwriteLaterTyping() async throws {
        let initial = try NoteDocument(text: "initial").snapshot()
        let storage = ControlledStorage(loadResult: .current(initial))
        await storage.setPaused(true)
        let session = NoteSession(storage: storage, saveScheduling: .immediate)
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
        let session = NoteSession(storage: storage, saveScheduling: .immediate)
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
        let session = NoteSession(storage: storage, saveScheduling: .immediate)
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
        let session = NoteSession(storage: storage, saveScheduling: .immediate)
        await session.load()
        try session.replaceAll(with: "editing")
        await waitUntil { await storage.saveCount == 1 }

        await session.load()

        XCTAssertEqual(session.text, "editing")
        XCTAssertEqual(session.status, .saving)
        await storage.releaseOneSave()
        await waitUntil { session.status == .saved }
    }

    func testEditorCommitOfIdenticalBytesDoesNotSaveOrChangeDate()
        async throws
    {
        let initial = try NoteDocument(
            text: "unchanged",
            metadata: .now(Date(timeIntervalSince1970: 100))
        ).snapshot()
        let storage = ControlledStorage(loadResult: .current(initial))
        let session = NoteSession(storage: storage, saveScheduling: .immediate)
        await session.load()

        let revision = try XCTUnwrap(session.editorRevision)
        let result = try session.commitEditorText(
            "unchanged",
            basedOn: revision
        )
        let saveCount = await storage.saveCount

        XCTAssertEqual(result, revision)
        XCTAssertEqual(session.currentSnapshot, initial)
        XCTAssertEqual(session.status, .saved)
        XCTAssertEqual(saveCount, 0)
        XCTAssertEqual(
            try XCTUnwrap(session.currentSnapshot).metadata.modifiedAt,
            Date(timeIntervalSince1970: 100)
        )
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
        let session = NoteSession(storage: storage, saveScheduling: .immediate)
        await session.load()

        await session.recoverFromPrevious()
        XCTAssertFalse(session.isEditingEnabled)
        XCTAssertNotNil(session.recoveryErrorMessage)

        await session.recoverFromPrevious()
        XCTAssertEqual(session.text, "known good")
        XCTAssertEqual(session.status, .saved)
        XCTAssertTrue(session.isEditingEnabled)
    }

    func testEditsCoalesceAfterOneSecondIdle() async throws {
        let initial = try NoteDocument(text: "initial").snapshot()
        let clock = TestClock()
        let sleeper = ManualSleeper()
        let storage = ControlledStorage(loadResult: .current(initial))
        let session = NoteSession(
            storage: storage,
            saveScheduling: .manual(clock: clock, sleeper: sleeper)
        )
        await session.load()

        try session.replaceAll(with: "first")
        await waitUntil { await sleeper.requestCount == 1 }
        clock.advance(by: 300_000_000)
        try session.replaceAll(with: "latest")
        await waitUntil { await sleeper.requestCount == 2 }

        let requestedDelays = await sleeper.requestedDelays
        XCTAssertEqual(requestedDelays, [.seconds(1), .seconds(1)])
        await sleeper.releaseAll()
        await waitUntil { session.status == .saved }
        let saved = await storage.savedSnapshots
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(try NoteDocument(snapshot: saved[0]).text, "latest")
    }

    func testContinuousTypingUsesFiveSecondDeadline() async throws {
        let initial = try NoteDocument(text: "initial").snapshot()
        let clock = TestClock()
        let sleeper = ManualSleeper()
        let storage = ControlledStorage(loadResult: .current(initial))
        let session = NoteSession(
            storage: storage,
            saveScheduling: .manual(clock: clock, sleeper: sleeper)
        )
        await session.load()

        try session.replaceAll(with: "first")
        await waitUntil { await sleeper.requestCount == 1 }
        clock.advance(by: 4_500_000_000)
        try session.replaceAll(with: "latest")
        await waitUntil { await sleeper.requestCount == 2 }

        let requestedDelays = await sleeper.requestedDelays
        XCTAssertEqual(
            requestedDelays,
            [.seconds(1), .milliseconds(500)]
        )
        await sleeper.releaseAll()
        await waitUntil { session.status == .saved }
        let saved = await storage.savedSnapshots
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(try NoteDocument(snapshot: saved[0]).text, "latest")
    }

    func testFlushBypassesDelayedSaveAndWaitsForLatestText() async throws {
        let initial = try NoteDocument(text: "initial").snapshot()
        let clock = TestClock()
        let sleeper = ManualSleeper()
        let storage = ControlledStorage(loadResult: .current(initial))
        let session = NoteSession(
            storage: storage,
            saveScheduling: .manual(clock: clock, sleeper: sleeper)
        )
        await session.load()
        try session.replaceAll(with: "latest")
        await waitUntil { await sleeper.requestCount == 1 }

        try await session.flush()

        let saveCount = await storage.saveCount
        XCTAssertEqual(saveCount, 1)
        let saved = await storage.savedSnapshots
        XCTAssertEqual(try NoteDocument(snapshot: XCTUnwrap(saved.first)).text, "latest")
    }

    func testDeletionCancelsDelayedSave() async throws {
        let initial = try NoteDocument(text: "initial").snapshot()
        let clock = TestClock()
        let sleeper = ManualSleeper()
        let storage = ControlledStorage(loadResult: .current(initial))
        let session = NoteSession(
            storage: storage,
            saveScheduling: .manual(clock: clock, sleeper: sleeper)
        )
        await session.load()
        try session.replaceAll(with: "pending")
        await waitUntil { await sleeper.requestCount == 1 }

        session.markPermanentlyDeleted()
        await session.waitForPendingSave()
        await sleeper.releaseAll()
        await Task.yield()

        let saveCount = await storage.saveCount
        XCTAssertEqual(saveCount, 0)
        session.discardPermanentlyDeletedContent()
        XCTAssertEqual(session.text, "")
    }

    func testFirstLaunchSavesImmediately() async throws {
        let clock = TestClock()
        let sleeper = ManualSleeper()
        let storage = ControlledStorage(loadResult: .firstLaunch)
        let session = NoteSession(
            storage: storage,
            saveScheduling: .manual(clock: clock, sleeper: sleeper)
        )

        await session.load()
        await waitUntil { session.status == .saved }

        let saveCount = await storage.saveCount
        let requestCount = await sleeper.requestCount
        XCTAssertEqual(saveCount, 1)
        XCTAssertEqual(requestCount, 0)
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

private final class TestClock: @unchecked Sendable {
    private(set) var now: UInt64 = 0

    func advance(by nanoseconds: UInt64) {
        now += nanoseconds
    }
}

private actor ManualSleeper {
    private var delays: [Duration] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []

    var requestCount: Int { delays.count }
    var requestedDelays: [Duration] { delays }

    func sleep(for delay: Duration) async {
        delays.append(delay)
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func releaseAll() {
        let pending = continuations
        continuations.removeAll()
        for continuation in pending { continuation.resume() }
    }
}

private extension NoteSaveSchedulingPolicy {
    static func manual(
        clock: TestClock,
        sleeper: ManualSleeper
    ) -> NoteSaveSchedulingPolicy {
        NoteSaveSchedulingPolicy(
            idleDelay: .seconds(1),
            maximumDelay: .seconds(5),
            now: { clock.now },
            sleep: { delay in await sleeper.sleep(for: delay) }
        )
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
