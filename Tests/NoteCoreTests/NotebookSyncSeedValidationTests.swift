import Foundation
import XCTest

@testable import NoteCore

@MainActor
final class NotebookSyncSeedValidationTests: XCTestCase {
    func testRejectedBootstrapSeedsLeaveFreshCheckpointUntouched() async throws {
        for fault in SeedFault.allCases {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let canonical = SyncRecord(catalog: try NotebookCatalogDocument().snapshot())
            let rejected = try fault.apply(to: canonical)
            let transport = SeedValidationTransport(seed: rejected)
            let replica = NotebookReplica(directory: root)
            let coordinator = NotebookSyncCoordinator(
                replica: replica, transport: transport)

            await coordinator.synchronize()

            assertFailed(coordinator, fault: fault, seed: rejected, warm: false)
            XCTAssertNil(replica.catalogSnapshot, "\(fault)")
            XCTAssertEqual(try checkpoint(at: root), .empty, "\(fault)")
            let calls = await transport.counts()
            XCTAssertEqual(
                calls,
                SeedValidationCounts(bootstraps: 1, fetches: 0, publishes: 0),
                "\(fault)"
            )
        }
    }

    func testRejectedBootstrapSeedsPreserveWarmCheckpointAndCatalog() async throws {
        for fault in SeedFault.allCases {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let canonical = SyncRecord(catalog: try NotebookCatalogDocument().snapshot())
            let transport = SeedValidationTransport(seed: canonical)
            let replica = NotebookReplica(directory: root)
            let coordinator = NotebookSyncCoordinator(
                replica: replica, transport: transport)
            for _ in 0..<3 { await coordinator.synchronize() }
            assertExchanged(coordinator)
            let before = try checkpoint(at: root)
            let installed = try XCTUnwrap(replica.catalogSnapshot)
            let currentURL = NotebookCatalogStorage(directory: root).currentURL
            let currentBytes = try Data(contentsOf: currentURL)
            let callsBefore = await transport.counts()
            let rejected = try fault.apply(to: canonical)
            await transport.setSeed(rejected)

            await coordinator.synchronize()

            assertFailed(coordinator, fault: fault, seed: rejected, warm: true)
            XCTAssertEqual(replica.catalogSnapshot, installed, "\(fault)")
            XCTAssertEqual(try Data(contentsOf: currentURL), currentBytes, "\(fault)")
            XCTAssertEqual(try checkpoint(at: root), before, "\(fault)")
            let calls = await transport.counts()
            XCTAssertEqual(
                calls,
                SeedValidationCounts(
                    bootstraps: callsBefore.bootstraps + 1,
                    fetches: callsBefore.fetches,
                    publishes: callsBefore.publishes
                ),
                "\(fault)"
            )
        }
    }

    func testExactAcceptedSeedReusesCatalogAfterDurableAcceptance() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = SyncRecord(catalog: try NotebookCatalogDocument().snapshot())
        let transport = SeedValidationTransport(seed: seed)
        let replica = NotebookReplica(directory: root)
        let coordinator = NotebookSyncCoordinator(
            replica: replica, transport: transport)
        for _ in 0..<3 { await coordinator.synchronize() }
        assertExchanged(coordinator)
        let before = try XCTUnwrap(replica.catalogSnapshot)
        let currentURL = NotebookCatalogStorage(directory: root).currentURL
        let currentBytes = try Data(contentsOf: currentURL)
        replica.catalogWriteSuspension = { throw SeedValidationSaveFailure.injected }

        await coordinator.synchronize()

        assertExchanged(coordinator)
        XCTAssertEqual(replica.catalogSnapshot, before)
        XCTAssertEqual(try Data(contentsOf: currentURL), currentBytes)
        replica.catalogWriteSuspension = nil
    }

    func testFailedCatalogPersistenceRetriesBeforeFetchOrCheckpoint() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = SyncRecord(catalog: try NotebookCatalogDocument().snapshot())
        let transport = SeedValidationTransport(seed: seed)
        let replica = NotebookReplica(directory: root)
        let coordinator = NotebookSyncCoordinator(
            replica: replica, transport: transport)
        replica.catalogWriteSuspension = { throw SeedValidationSaveFailure.injected }

        for attempt in 1...2 {
            await coordinator.synchronize()
            XCTAssertTrue(coordinator.lastError is SeedValidationSaveFailure)
            XCTAssertEqual(try checkpoint(at: root), .empty)
            XCTAssertNil(replica.catalogSnapshot)
            let calls = await transport.counts()
            XCTAssertEqual(
                calls,
                SeedValidationCounts(
                    bootstraps: attempt, fetches: 0, publishes: 0)
            )
        }

        replica.catalogWriteSuspension = nil
        await coordinator.synchronize()
        assertExchanged(coordinator)
        XCTAssertEqual(try checkpoint(at: root).notebookID, seed.notebookID)
        XCTAssertEqual(replica.catalogSnapshot?.notebookID, seed.notebookID)
    }

    func testFailedWarmCatalogPersistenceRetriesFullPath() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = try NotebookCatalogDocument()
        let initialSeed = SyncRecord(catalog: initial.snapshot())
        let transport = SeedValidationTransport(seed: initialSeed)
        let replica = NotebookReplica(directory: root)
        let coordinator = NotebookSyncCoordinator(
            replica: replica, transport: transport)
        for _ in 0..<3 { await coordinator.synchronize() }
        assertExchanged(coordinator)
        let before = try checkpoint(at: root)
        let installed = try XCTUnwrap(replica.catalogSnapshot)
        let callsBefore = await transport.counts()
        let updated = try initial.fork()
        let folderID = try updated.add(kind: .folder, name: "Remote")
        await transport.setSeed(SyncRecord(catalog: updated.snapshot()))
        replica.catalogWriteSuspension = { throw SeedValidationSaveFailure.injected }

        for attempt in 1...2 {
            await coordinator.synchronize()
            XCTAssertTrue(coordinator.lastError is SeedValidationSaveFailure)
            XCTAssertEqual(try checkpoint(at: root), before)
            XCTAssertEqual(replica.catalogSnapshot, installed)
            let calls = await transport.counts()
            XCTAssertEqual(
                calls,
                SeedValidationCounts(
                    bootstraps: callsBefore.bootstraps + attempt,
                    fetches: callsBefore.fetches,
                    publishes: callsBefore.publishes
                )
            )
        }

        replica.catalogWriteSuspension = nil
        await coordinator.synchronize()
        assertExchanged(coordinator)
        XCTAssertTrue(replica.placements.contains { $0.item.id == folderID })
    }

    private func assertFailed(
        _ coordinator: NotebookSyncCoordinator,
        fault: SeedFault,
        seed: SyncRecord,
        warm: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .failed = coordinator.status else {
            return XCTFail(
                "Expected \(fault) to fail, got \(coordinator.status)",
                file: file, line: line)
        }
        guard let received = coordinator.lastError else {
            return XCTFail("Missing error for \(fault)", file: file, line: line)
        }
        switch fault {
        case .forgedID, .wrongKind, .wrongProtocol:
            XCTAssertEqual(received as? SyncError, .invalidRecord,
                file: file, line: line)
        case .forgedHeads, .forgedBytes:
            XCTAssertEqual(received as? NotebookCatalogError, .identityMismatch,
                file: file, line: line)
        case .wrongNotebook:
            XCTAssertEqual(received as? SyncError,
                warm ? .identityConflict : .invalidRecord,
                file: file, line: line)
        case .malformedBytes:
            do {
                try seed.validate()
                XCTFail("Malformed seed unexpectedly validated", file: file, line: line)
            } catch {
                XCTAssertEqual(
                    String(reflecting: received),
                    String(reflecting: error),
                    file: file, line: line)
            }
        }
    }

    private func assertExchanged(
        _ coordinator: NotebookSyncCoordinator,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .exchanged = coordinator.status else {
            return XCTFail(
                "Expected exchange, got \(coordinator.status)",
                file: file, line: line)
        }
    }

    private func checkpoint(at root: URL) throws -> SeedCheckpoint {
        let state = try JSONDecoder().decode(
            NotebookSyncState.self,
            from: Data(contentsOf: root.appending(path: "notebook-sync-state.json"))
        )
        return SeedCheckpoint(state)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "NotebookSyncSeedValidationTests-\(UUID().uuidString)")
    }
}

private enum SeedFault: String, CaseIterable {
    case forgedID, forgedHeads, forgedBytes, malformedBytes
    case wrongKind, wrongProtocol, wrongNotebook

    func apply(to seed: SyncRecord) throws -> SyncRecord {
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(seed))
                as? [String: Any])
        var snapshot = try XCTUnwrap(json["snapshot"] as? [String: Any])
        switch self {
        case .forgedID:
            json["id"] = String(repeating: "0", count: 64)
        case .forgedHeads:
            snapshot["heads"] = ["forged-head"]
        case .forgedBytes:
            let catalog = try NotebookCatalogDocument(
                snapshot: try XCTUnwrap(seed.catalogSnapshot))
            _ = try catalog.add(kind: .folder, name: "Forged")
            snapshot["data"] = catalog.snapshot().data.base64EncodedString()
        case .malformedBytes:
            snapshot["data"] = Data("invalid Automerge bytes".utf8)
                .base64EncodedString()
        case .wrongKind:
            json["kind"] = SyncDocumentKind.note.rawValue
        case .wrongProtocol:
            json["protocolVersion"] = 99
        case .wrongNotebook:
            json["notebookID"] = UUID().uuidString
        }
        json["snapshot"] = snapshot
        return try JSONDecoder().decode(
            SyncRecord.self,
            from: JSONSerialization.data(withJSONObject: json))
    }
}

private struct SeedCheckpoint: Equatable, Sendable {
    let notebookID: UUID?
    let cursor: String?
    let appliedHeads: [String: Set<String>]
    let acknowledgedHeads: [String: Set<String>]
    let deletedIDs: Set<UUID>

    init(_ state: NotebookSyncState) {
        notebookID = state.notebookID
        cursor = state.cursor
        appliedHeads = state.appliedHeads
        acknowledgedHeads = state.acknowledgedHeads
        deletedIDs = state.deletedIDs
    }

    static let empty = Self(NotebookSyncState(scope: "seed-validation"))
}

private struct SeedValidationCounts: Equatable, Sendable {
    let bootstraps: Int
    let fetches: Int
    let publishes: Int
}

private enum SeedValidationSaveFailure: Error {
    case injected
}

private actor SeedValidationTransport: SyncTransport {
    nonisolated let scope = "seed-validation"
    private var seed: SyncRecord
    private var bootstraps = 0
    private var fetches = 0
    private var publishes = 0

    init(seed: SyncRecord) { self.seed = seed }

    func setSeed(_ newSeed: SyncRecord) { seed = newSeed }

    func counts() -> SeedValidationCounts {
        SeedValidationCounts(
            bootstraps: bootstraps,
            fetches: fetches,
            publishes: publishes)
    }

    func bootstrap(proposing record: SyncRecord) -> SyncRecord {
        bootstraps += 1
        return seed
    }

    func fetch(after cursor: String?) -> SyncPage {
        fetches += 1
        return SyncPage(records: [], cursor: "done", hasMore: false)
    }

    func publish(_ record: SyncRecord) {
        publishes += 1
    }
}
