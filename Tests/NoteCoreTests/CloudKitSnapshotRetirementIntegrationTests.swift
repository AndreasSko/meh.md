import CloudKit
import Foundation
import XCTest

@testable import NoteCore

/// Exercises retirement through the real transport and durable engine events.
final class CloudKitSnapshotRetirementIntegrationTests: XCTestCase {
    private var root: URL!
    private var server: FakeCloudKitServer!
    private let notebookID = UUID()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "SnapshotRetirement-\(UUID())"
        )
        server = try FakeCloudKitServer(directory: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testRetiredNoteAndCatalogKeepFullHistoryOnSurvivors() async throws {
        let fixture = try makeFixture()
        let writer = try await seed(fixture)
        let receiver = try await open("receiver")
        _ = try await receiver.bootstrap(proposing: fixture.catalog)
        let cursor = try await drain(receiver).cursor
        let catalog = try NotebookCatalogDocument(
            serializedData: fixture.catalog.snapshot.data
        )
        try catalog.setPinnedInRecents(true, for: fixture.old.snapshot.noteID)
        let oldCatalog = SyncRecord(catalog: catalog.snapshot())
        try catalog.recordRecentActivity(for: fixture.old.snapshot.noteID)
        let latestCatalog = SyncRecord(catalog: catalog.snapshot())
        try await publish(writer, [oldCatalog, latestCatalog])
        _ = try await drain(receiver, after: cursor)
        server.deleteRecord(named: fixture.old.id)
        server.deleteRecord(named: oldCatalog.id)

        let received = try await drain(receiver)
        XCTAssertTrue(received.records.contains(fixture.latest))
        XCTAssertTrue(received.records.contains(latestCatalog))
        XCTAssertFalse(server.recordNames.contains(fixture.old.id))
        XCTAssertFalse(server.recordNames.contains(oldCatalog.id))
        try assertHistory(fixture)
        let survivor = try NotebookCatalogDocument(
            serializedData: latestCatalog.snapshot.data
        )
        let ancestor = try NotebookCatalogDocument(
            serializedData: oldCatalog.snapshot.data
        )
        XCTAssertTrue(ancestor.historyHeads.isSubset(of: survivor.historyHeads))
        let halt = await receiver.haltStatus()
        XCTAssertNil(halt)
    }

    func testFreshReceiverBootstrapsWhenOlderBodiesAreAbsent() async throws {
        let fixture = try makeFixture()
        _ = try await seed(fixture)
        server.deleteRecord(named: fixture.old.id)
        let receiver = try await open("fresh")
        let canonical = try await receiver.bootstrap(proposing: fixture.catalog)
        XCTAssertEqual(canonical, fixture.catalog)
        let received = try await drain(receiver)
        XCTAssertTrue(received.records.contains(fixture.latest))
        XCTAssertFalse(received.records.contains { $0.id == fixture.old.id })
        try assertHistory(fixture)
    }

    func testOfflineConcurrentBranchMergesAfterOldBodyRetirement() async throws {
        let fixture = try makeFixture()
        _ = try await seed(fixture)
        let offline = try await open("offline")
        _ = try await offline.bootstrap(proposing: fixture.catalog)
        _ = try await drain(offline)
        let branch = try NoteDocument(snapshot: fixture.old.snapshot)
        try branch.replaceUTF16(range: NSRange(location: 0, length: 0),
                                with: "Offline branch\n")
        let branchRecord = record(branch)
        server.setOffline(true)
        do {
            _ = try await offline.publishBatch([branchRecord])
            XCTFail("Offline account preflight must reject the upload")
        } catch {
            XCTAssertEqual((error as? CKError)?.code, .networkUnavailable)
        }
        server.setOffline(false)
        server.deleteRecord(named: fixture.old.id)
        _ = try await drain(offline)
        try await publish(offline, [branchRecord])
        let fresh = try await open("merged")
        _ = try await fresh.bootstrap(proposing: fixture.catalog)
        let records = try await drain(fresh).records
        let merged = try NoteDocument(snapshot: fixture.old.snapshot)
        for value in records where value.kind == .note {
            try merged.merge(NoteDocument(snapshot: value.snapshot))
        }
        XCTAssertTrue(try merged.text.contains("Offline branch"))
        XCTAssertTrue(try merged.text.contains("Latest text"))
        XCTAssertTrue(branch.historyHeads.isSubset(of: merged.historyHeads))
        let latest = try NoteDocument(snapshot: fixture.latest.snapshot)
        XCTAssertTrue(latest.historyHeads.isSubset(of: merged.historyHeads))
    }

    func testDeletionEventSurvivesCrashBeforeReplacementArrives() async throws {
        let fixture = try makeFixture()
        let writer = try await open("writer")
        _ = try await writer.bootstrap(proposing: fixture.catalog)
        try await publish(writer, [fixture.old])
        let receiver = try await open("crashed")
        _ = try await receiver.bootstrap(proposing: fixture.catalog)
        let cursor = try await drain(receiver).cursor
        server.deleteRecord(named: fixture.old.id)
        server.inject(.crashAfterFetchedChanges)
        do {
            _ = try await receiver.fetch(after: cursor)
            XCTFail("The injected crash must interrupt the deletion fetch")
        } catch {
            XCTAssertTrue(error is FakeCloudKitCrash)
        }
        await receiver.retire()
        try await publish(writer, [fixture.latest])
        let restarted = try await open("crashed")
        let received = try await drain(restarted, after: cursor)
        XCTAssertTrue(received.records.contains { $0.id == fixture.latest.id })
        let halt = await restarted.haltStatus()
        XCTAssertNil(halt)
        try assertHistory(fixture)
    }

    func testCachedSurvivorGoneFromCloudDoesNotAuthorizeRetirement() async throws {
        let fixture = try makeFixture()
        _ = try await seed(fixture)
        let receiver = try await open("receiver")
        _ = try await receiver.bootstrap(proposing: fixture.catalog)
        let cursor = try await drain(receiver).cursor
        server.deleteRecord(named: fixture.old.id)
        // Its descendant was fetched above, but disappears after the engine
        // delivers the older deletion and before positive confirmation.
        server.inject(.deleteBeforeNextRead(fixture.latest.id))
        do {
            _ = try await receiver.fetch(after: cursor)
            XCTFail("Missing cloud history must halt sync")
        } catch {
            XCTAssertEqual(error as? CloudKitSyncTransportError,
                           .unexpectedDeletion)
        }
        await receiver.retire()
        let restarted = try await open("receiver")
        do {
            _ = try await restarted.fetch(after: cursor)
            XCTFail("Restart must retain unresolved deletion evidence")
        } catch {
            XCTAssertEqual(error as? CloudKitSyncTransportError,
                           .unexpectedDeletion)
        }
    }

    func testSurvivorReadFailureRetriesWithoutLosingDeletionEvidence() async throws {
        let fixture = try makeFixture()
        _ = try await seed(fixture)
        let receiver = try await open("receiver")
        _ = try await receiver.bootstrap(proposing: fixture.catalog)
        let cursor = try await drain(receiver).cursor
        server.deleteRecord(named: fixture.old.id)
        server.inject(.failNextRead)
        do {
            _ = try await receiver.fetch(after: cursor)
            XCTFail("A failed confirmation read must not approve retirement")
        } catch {
            XCTAssertNotEqual(error as? CloudKitSyncTransportError,
                              .unexpectedDeletion)
        }
        let halt = await receiver.haltStatus()
        XCTAssertNil(halt)
        await receiver.retire()
        let restarted = try await open("receiver")
        _ = try await drain(restarted, after: cursor)
        let received = try await drain(restarted)
        XCTAssertTrue(received.records.contains(fixture.latest))
        let finalHalt = await restarted.haltStatus()
        XCTAssertNil(finalHalt)
    }

    func testOfflinePendingOldSnapshotCanBeUploadedAfterRetirement() async throws {
        let fixture = try makeFixture()
        _ = try await seed(fixture)
        let receiver = try await open("pending")
        _ = try await receiver.bootstrap(proposing: fixture.catalog)
        _ = try await drain(receiver)
        server.inject(.failSave(.networkUnavailable) {
            $0.recordName == fixture.old.id
        })
        let pending = try await receiver.publishBatch([fixture.old])
        XCTAssertNotNil(pending.error)
        XCTAssertEqual(pending.acknowledgedIDs, [])
        server.deleteRecord(named: fixture.old.id)
        _ = try await drain(receiver)
        try await publish(receiver, [fixture.old])
        XCTAssertTrue(server.recordNames.contains(fixture.old.id))
        let fresh = try await open("reuploaded")
        _ = try await fresh.bootstrap(proposing: fixture.catalog)
        let records = try await drain(fresh).records
        XCTAssertTrue(records.contains(fixture.old))
        XCTAssertTrue(records.contains(fixture.latest))
        let halt = await fresh.haltStatus()
        XCTAssertNil(halt)
    }

    private struct Fixture {
        let catalog: SyncRecord
        let old: SyncRecord
        let latest: SyncRecord
    }

    private func makeFixture() throws -> Fixture {
        let document = try NoteDocument(text: "Original text\n")
        let old = record(document)
        try document.replaceAll(with: "Original text\nLatest text\n")
        let catalog = try NotebookCatalogDocument(notebookID: notebookID)
        _ = try catalog.add(id: document.noteID, kind: .note,
                            name: "Fictional retirement note")
        return Fixture(catalog: SyncRecord(catalog: catalog.snapshot()),
            old: old, latest: record(document))
    }

    private func record(_ document: NoteDocument) -> SyncRecord {
        SyncRecord(snapshot: document.snapshot(), notebookID: notebookID)
    }

    private func assertHistory(_ fixture: Fixture) throws {
        let old = try NoteDocument(snapshot: fixture.old.snapshot)
        let latest = try NoteDocument(snapshot: fixture.latest.snapshot)
        XCTAssertTrue(old.historyHeads.isSubset(of: latest.historyHeads))
        let texts = try latest.historyVersions().map(latest.historicalText(for:))
        XCTAssertTrue(texts.contains("Original text\n"))
    }

    private func seed(_ fixture: Fixture) async throws -> CloudKitSyncTransport {
        let writer = try await open("writer")
        _ = try await writer.bootstrap(proposing: fixture.catalog)
        try await publish(writer, [fixture.old, fixture.latest])
        return writer
    }

    private func publish(_ transport: CloudKitSyncTransport,
                         _ records: [SyncRecord]) async throws {
        let result = try await transport.publishBatch(records)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.acknowledgedIDs, Set(records.map(\.id)))
    }

    private func open(_ device: String) async throws -> CloudKitSyncTransport {
        try await CloudKitSyncTransport.makeNotebook(
            services: server.services,
            containerIdentifier: server.containerIdentifier,
            stateDirectory: root.appending(path: device)
        )
    }

    private func drain(_ transport: CloudKitSyncTransport,
                       after initial: String? = nil) async throws
        -> (records: [SyncRecord], cursor: String)
    {
        var cursor = initial
        var records: [SyncRecord] = []
        for _ in 0..<20 {
            let page = try await transport.fetch(after: cursor)
            records += page.records
            cursor = page.cursor
            if !page.hasMore { return (records, page.cursor) }
        }
        throw SyncError.unavailable("Fake fetch exceeded its page bound")
    }
}
