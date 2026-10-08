import Foundation
import XCTest

@testable import NoteCore

final class NoteHistoryReaderTests: XCTestCase {
    func testProgressivePrefixMatchesCompleteUnicodeHistoryAndCaches() async throws {
        let bytes = try NoteHistoryPerformanceTests().makeFixture(lines: 30, edits: 160)
        let document = try NoteDocument(serializedData: bytes)
        let snapshot = document.snapshot()
        let expected = try NoteHistoryLegacyOracle(snapshot: snapshot).historyVersions()
        XCTAssertEqual(try document.historyVersions(), expected)
        let reader = NoteHistoryReader(snapshot: snapshot)
        var previous: [NoteHistoryVersion] = []
        var sawPartial = false
        var final: [NoteHistoryVersion] = []
        for try await update in await reader.updates(batchSize: 1) {
            XCTAssertEqual(Array(update.versions.prefix(previous.count)), previous)
            XCTAssertEqual(update.versions, Array(expected.prefix(update.versions.count)))
            if !update.isComplete && !update.versions.isEmpty { sawPartial = true }
            previous = update.versions
            if update.isComplete { final = update.versions }
        }
        XCTAssertTrue(sawPartial)
        XCTAssertEqual(final, expected)
        let scans = await reader.historyScanCount
        let loads = await reader.loadCount
        let replays = await reader.processedChangeCount
        XCTAssertEqual(scans, 1)
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(replays, document.historyCount)
        let hasReplay = await reader.hasActiveIndexBuilder
        XCTAssertFalse(hasReplay)
        assertAwaitedEqual(await reader.previewReadCount, 0)
        for index in [0, 40, 80, 120] {
            let actual = try await reader.historicalText(for: expected[index])
            XCTAssertEqual(actual, try document.historicalText(for: expected[index]))
        }
        assertAwaitedEqual(await reader.cachedPreviewCount, 3)
        let cacheBytes = await reader.cachedPreviewBytes
        XCTAssertLessThanOrEqual(cacheBytes, 4 * 1024 * 1024)
        let before = await reader.previewReadCount
        _ = try await reader.historicalText(for: expected[120])
        assertAwaitedEqual(await reader.previewReadCount, before)
        var repeatUpdates = 0
        for try await update in await reader.updates(batchSize: 1) {
            XCTAssertTrue(update.isComplete)
            XCTAssertEqual(update.versions, expected)
            repeatUpdates += 1
        }
        XCTAssertEqual(repeatUpdates, 1)
        assertAwaitedEqual(await reader.historyScanCount, scans)
        assertAwaitedEqual(await reader.processedChangeCount, replays)
        XCTAssertEqual(document.snapshot(), snapshot)
    }

    func testConcurrentHistoryRestoreAndMetadataMatchFrozenIndex() async throws {
        let start = Date(timeIntervalSince1970: 100)
        let base = try NoteDocument(text: "Café e\u{301} 👋🏽\n", metadata:
            NoteMetadata(createdAt: start, modifiedAt: start))
        _ = base.snapshot()
        var left = try base.fork()
        let right = try base.fork()
        try left.replaceAll(with: "LEFT 👋🏽\n", at: start.addingTimeInterval(1))
        _ = left.snapshot()
        try right.replaceAll(with: "RIGHT e\u{301}\n", at: start.addingTimeInterval(2))
        _ = right.snapshot()
        try left.merge(right)
        // Match the reader: resolve object identities from the frozen snapshot.
        left = try NoteDocument(snapshot: left.snapshot())
        let versions = try left.historyVersions()
        try left.restoreHistoryVersion(try XCTUnwrap(versions.first),
            at: start.addingTimeInterval(3))
        _ = left.snapshot()
        let snapshot = left.snapshot()
        let expected = try NoteHistoryLegacyOracle(snapshot: snapshot).historyVersions()
        XCTAssertEqual(try left.historyVersions(), expected)
        let reader = NoteHistoryReader(snapshot: snapshot)
        var final: [NoteHistoryVersion] = []
        for try await update in await reader.updates(batchSize: 2) {
            XCTAssertEqual(update.versions, Array(expected.prefix(update.versions.count)))
            if update.isComplete { final = update.versions }
        }
        XCTAssertEqual(final, expected)
        for version in final {
            let text = try await reader.historicalText(for: version)
            XCTAssertEqual(text, try left.historicalText(for: version))
        }
        XCTAssertEqual(left.snapshot(), snapshot)
    }

    @MainActor
    func testSessionReusesUnchangedReaderAndReleasesItAfterEdit() async throws {
        let source = try NoteDocument(text: "Fictional current text")
        let session = NoteSession(storage:
            HistoryRestoreTestStorage(snapshot: source.snapshot()))
        await session.load()
        var browser: NoteHistoryReader? = try session.makeHistoryReader()
        weak var original = browser
        XCTAssertTrue(browser === (try session.makeHistoryReader()))
        try session.replaceAll(with: "Fictional current text")
        XCTAssertTrue(browser === (try session.makeHistoryReader()))
        browser = nil
        XCTAssertNotNil(original, "The unchanged session retains its reusable reader")
        try session.replaceAll(with: "Fictional newer text")
        XCTAssertNil(original, "An edit must release the stale frozen snapshot")
    }

    @MainActor
    func testOpenBrowserKeepsFrozenPreviewAfterSessionEdit() async throws {
        let source = try NoteDocument(text: "Fictional earlier text")
        _ = source.snapshot()
        try source.replaceAll(with: "Fictional current text")
        let session = NoteSession(storage:
            HistoryRestoreTestStorage(snapshot: source.snapshot()))
        await session.load()
        var browser: NoteHistoryReader? = try session.makeHistoryReader()
        weak var original = browser
        let versions = try await Self.collect(try XCTUnwrap(browser))
        let version = try XCTUnwrap(versions.first)
        try session.replaceAll(with: "Fictional newer edit")
        XCTAssertNotNil(original, "The open browser owns its frozen reader")
        XCTAssertFalse(browser === (try session.makeHistoryReader()))
        let preview = try await browser?.historicalText(for: version)
        XCTAssertEqual(preview, "Fictional earlier text")
        XCTAssertEqual(session.text, "Fictional newer edit")
        browser = nil
        // Stream termination cleanup may briefly retain its actor invocation.
        for _ in 0..<100 where original != nil { await Task.yield() }
        XCTAssertNil(original, "Closing the browser releases its old frozen document")
    }

    @MainActor
    func testRemoteMergeReleasesStaleSessionReader() async throws {
        let source = try NoteDocument(text: "Fictional original text")
        let snapshot = source.snapshot()
        let session = NoteSession(storage: HistoryRestoreTestStorage(snapshot: snapshot))
        await session.load()
        weak var original: NoteHistoryReader?
        do { original = try session.makeHistoryReader() }
        XCTAssertNotNil(original)
        try session.mergeRemote(snapshot)
        XCTAssertNotNil(original, "An unchanged remote revision reuses the reader")
        let remote = try source.fork()
        try remote.replaceAll(with: "Fictional remote edit")
        try session.mergeRemote(remote.snapshot())
        XCTAssertNil(original, "A changed remote revision releases the reader")
    }

    @MainActor
    func testRestoreReleasesStaleSessionReader() async throws {
        let source = try NoteDocument(text: "Fictional earlier text")
        _ = source.snapshot()
        try source.replaceAll(with: "Fictional current text")
        let snapshot = source.snapshot()
        let session = NoteSession(storage: HistoryRestoreTestStorage(snapshot: snapshot),
            saveScheduling: .immediate)
        await session.load()
        var browser: NoteHistoryReader? = try session.makeHistoryReader()
        weak var original = browser
        let versions = try await Self.collect(try XCTUnwrap(browser))
        browser = nil
        try await session.restoreHistoryVersion(try XCTUnwrap(versions.first),
            expectedHeads: snapshot.heads)
        for _ in 0..<100 where original != nil { await Task.yield() }
        XCTAssertNil(original, "Restoring replaces the session's cached revision")
        XCTAssertEqual(session.text, "Fictional earlier text")
    }

    @MainActor
    func testLiveEditWhileRestoreAwaitsIndexRejectsReplacement() async throws {
        let bytes = try NoteHistoryPerformanceTests().makeFixture(lines: 15, edits: 500)
        let source = try NoteDocument(serializedData: bytes)
        let snapshot = source.snapshot()
        let version = try XCTUnwrap(source.historyVersions().first)
        let storage = HistoryRestoreTestStorage(snapshot: snapshot)
        let session = NoteSession(storage: storage, saveScheduling: .immediate)
        await session.load()
        let reader = try session.makeHistoryReader()
        let restore = Task { @MainActor in
            try await session.restoreHistoryVersion(version, expectedHeads: snapshot.heads)
        }
        var observedIndexing = false
        for _ in 0..<1_000 {
            if await reader.hasActiveIndexBuilder {
                observedIndexing = true
                break
            }
            if await reader.isIndexComplete { break }
            await Task.yield()
        }
        XCTAssertTrue(observedIndexing, "Restore must suspend while its index is built")
        try session.replaceAll(with: "New fictional edit during restore")
        do {
            try await restore.value
            XCTFail("An edit during the awaited index must reject replacement")
        } catch NoteHistoryError.currentChanged {
            XCTAssertEqual(session.text, "New fictional edit during restore")
        }
        let saved = await storage.saved
        for snapshot in saved {
            XCTAssertEqual(try NoteDocument(snapshot: snapshot).text,
                "New fictional edit during restore")
        }
    }

    func testConcurrentSubscribersShareOneIndexProducer() async throws {
        let bytes = try NoteHistoryPerformanceTests().makeFixture(lines: 3, edits: 120)
        let document = try NoteDocument(serializedData: bytes)
        let reader = NoteHistoryReader(snapshot: document.snapshot())
        async let first = Self.collect(reader)
        async let second = Self.collect(reader)
        let results = try await (first, second)
        let expected = try document.historyVersions()
        XCTAssertEqual(results.0, expected)
        XCTAssertEqual(results.1, expected)
        assertAwaitedEqual(await reader.historyScanCount, 1)
        assertAwaitedEqual(await reader.loadCount, 1)
        assertAwaitedEqual(await reader.processedChangeCount, document.historyCount)
    }

    private static func collect(_ reader: NoteHistoryReader)
        async throws -> [NoteHistoryVersion]
    {
        var result: [NoteHistoryVersion] = []
        for try await update in await reader.updates(batchSize: 1) {
            result = update.versions
        }
        return result
    }

    func testCancelledSubscriberCanResumeWithoutRepeatedReplay() async throws {
        let bytes = try NoteHistoryPerformanceTests().makeFixture(lines: 5, edits: 500)
        let document = try NoteDocument(serializedData: bytes)
        let reader = NoteHistoryReader(snapshot: document.snapshot())
        let started = expectation(description: "received initial stream update")
        let task = Task {
            for try await _ in await reader.updates(batchSize: 128) {
                started.fulfill()
                try await Task.sleep(for: .seconds(60))
            }
        }
        await fulfillment(of: [started], timeout: 10)
        task.cancel()
        do { try await task.value } catch is CancellationError { }
        var final: [NoteHistoryVersion] = []
        for try await update in await reader.updates(batchSize: 128) {
            if update.isComplete { final = update.versions }
        }
        XCTAssertEqual(final, try document.historyVersions())
        assertAwaitedEqual(await reader.loadCount, 1)
        assertAwaitedEqual(await reader.historyScanCount, 1)
        assertAwaitedEqual(await reader.processedChangeCount, document.historyCount)
    }

#if DEBUG
    func testDebugFixtureMatchesBenchmarkAndDoesNotOverwriteExistingCatalog()
        async throws
    {
        let expected = try NoteHistoryPerformanceTests().makeFixture(lines: 30, edits: 80)
        XCTAssertEqual(try NoteHistoryTestFixture.makeSnapshot(lines: 30, edits: 80).data,
            expected)
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "history-fixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory,
            withIntermediateDirectories: true)
        let existing = Data("existing catalog must remain untouched".utf8)
        let catalogURL = directory.appending(path: "catalog.automerge")
        try existing.write(to: catalogURL)
        try await NoteHistoryTestFixture.seed(directory: directory)
        XCTAssertEqual(try Data(contentsOf: catalogURL), existing)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path),
            ["catalog.automerge"])
    }
#endif

    private func assertAwaitedEqual<T: Equatable>(
        _ awaitValue: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(awaitValue, expected, file: file, line: line)
    }
}

private actor HistoryRestoreTestStorage: NoteStorage {
    let snapshot: NoteSnapshot
    private(set) var saved: [NoteSnapshot] = []
    init(snapshot: NoteSnapshot) { self.snapshot = snapshot }
    func load() -> NoteLoadResult { .current(snapshot) }
    func save(_ snapshot: NoteSnapshot) { saved.append(snapshot) }
    func recover(_ recovery: NoteRecovery) -> NoteSnapshot { snapshot }
}
