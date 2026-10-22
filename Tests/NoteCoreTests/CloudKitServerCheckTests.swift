import CloudKit
import Foundation
import XCTest

@testable import NoteCore

/// CKSyncEngine only fetches after a push. When a push is lost, a requested
/// server check must still bring in the other device's changes.
@MainActor
final class CloudKitServerCheckTests: XCTestCase {
    private var root: URL!
    private var server: FakeCloudKitServer!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "ServerCheck-\(UUID())"
        )
        server = try FakeCloudKitServer(directory: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testRequestedCheckFindsNoteWhosePushWasLost() async throws {
        let (mac, phone) = try await openSyncedPair()
        server.losesPushes = true
        let note = try await mac.replica.createNote(name: "new.md", text: "new\n")
        await mac.coordinator.synchronize()

        await phone.coordinator.synchronize()
        XCTAssertFalse(phone.replica.placements.contains { $0.item.id == note })

        let reads = server.zoneChangeReadCount
        await phone.transport.requestServerCheck()
        await phone.coordinator.synchronize()

        assertExchanged(phone.coordinator.status)
        XCTAssertEqual(server.zoneChangeReadCount, reads + 1)
        let text = try await phone.replica.openNote(note).text
        XCTAssertEqual(text, "new\n")
        let fetched = try XCTUnwrap(
            phone.log.entries.last { $0.event == "server_check_fetched" }
        )
        XCTAssertEqual(fetched.counts["notes"], 1)
    }

    func testCheckRunsOncePerRequest() async throws {
        let (mac, phone) = try await openSyncedPair()
        server.losesPushes = true
        await phone.transport.requestServerCheck()
        await phone.coordinator.synchronize()
        let reads = server.zoneChangeReadCount

        _ = try await mac.replica.createNote(name: "new.md", text: "new\n")
        await mac.coordinator.synchronize()
        await phone.coordinator.synchronize()

        XCTAssertEqual(server.zoneChangeReadCount, reads)
    }

    func testRelaunchedAppChecksServer() async throws {
        var (mac, phone) = try await openSyncedPair()
        server.losesPushes = true
        let note = try await mac.replica.createNote(name: "new.md", text: "new\n")
        await mac.coordinator.synchronize()

        phone = try await phone.restarted(server: server)
        await phone.coordinator.synchronize()

        assertExchanged(phone.coordinator.status)
        XCTAssertTrue(phone.replica.placements.contains { $0.item.id == note })
        _ = mac
    }

    func testExpiredChangeTokenRereadsWholeZone() async throws {
        let (mac, phone) = try await openSyncedPair()
        server.losesPushes = true
        let note = try await mac.replica.createNote(name: "new.md", text: "new\n")
        await mac.coordinator.synchronize()

        server.inject(.failNextZoneChanges(.changeTokenExpired))
        await phone.transport.requestServerCheck()
        await phone.coordinator.synchronize()

        assertExchanged(phone.coordinator.status)
        XCTAssertTrue(phone.replica.placements.contains { $0.item.id == note })
    }

    /// A direct read repeats deletions the engine already delivered. Those
    /// must not reopen the retirement that resolved them.
    func testCheckDoesNotReopenResolvedDeletions() async throws {
        let (mac, phone) = try await openSyncedPair()
        let note = try await mac.replica.createNote(name: "new.md", text: "new\n")
        await mac.coordinator.synchronize()
        await phone.coordinator.synchronize()
        let session = try await mac.replica.openNote(note)
        try session.replaceText(
            in: NSRange(location: session.text.utf16.count, length: 0),
            with: "edited\n"
        )
        try await session.flush()
        await mac.coordinator.synchronize()
        _ = try await mac.coordinator.cleanupSnapshots()
        await phone.coordinator.synchronize()
        XCTAssertTrue(phone.log.entries.contains {
            $0.event == "retirement_plan_start"
        }, "The engine should have delivered the cleanup's deletions")

        phone.log.clear()
        await phone.transport.requestServerCheck()
        await phone.coordinator.synchronize()

        assertExchanged(phone.coordinator.status)
        let fetched = try XCTUnwrap(
            phone.log.entries.last { $0.event == "server_check_fetched" }
        )
        XCTAssertGreaterThan(fetched.counts["deletions"] ?? 0, 0)
        XCTAssertFalse(phone.log.entries.contains {
            $0.event == "retirement_plan_start"
        })
        let text = try await phone.replica.openNote(note).text
        XCTAssertEqual(text, "new\nedited\n")
    }

    func testCheckFailureKeepsRequestForNextPass() async throws {
        let (mac, phone) = try await openSyncedPair()
        server.losesPushes = true
        let note = try await mac.replica.createNote(name: "new.md", text: "new\n")
        await mac.coordinator.synchronize()
        server.inject(.failNextZoneChanges(.zoneBusy))

        await phone.transport.requestServerCheck()
        await phone.coordinator.synchronize()
        guard case .failed = phone.coordinator.status else {
            return XCTFail("Expected failure, got \(phone.coordinator.status)")
        }
        let halt = await phone.transport.haltStatus()
        XCTAssertNil(halt)
        await phone.coordinator.synchronize()

        assertExchanged(phone.coordinator.status)
        XCTAssertTrue(phone.replica.placements.contains { $0.item.id == note })
    }

    /// Recreating the zone would re-seed iCloud from this device, so a zone
    /// deleted after this device joined stops sync instead.
    func testZoneDeletedBeforeCheckHaltsSync() async throws {
        let (_, phone) = try await openSyncedPair()
        server.inject(.deleteZoneBeforeNextZoneChanges)

        await phone.transport.requestServerCheck()
        await phone.coordinator.synchronize()

        let halt = await phone.transport.haltStatus()
        XCTAssertEqual(halt?.reason, .unexpectedDeletion)
    }

    /// A full read lists IDs and downloads only what the inbox lacks, so a
    /// fresh device does not download the zone a second time.
    func testFreshDeviceDownloadsZoneOnce() async throws {
        let mac = try await FakeCloudKitDevice.open(
            root.appending(path: "mac"), server: server
        )
        await mac.coordinator.synchronize()
        for index in 0..<3 {
            _ = try await mac.replica.createNote(
                name: "note \(index).md", text: "note \(index)\n"
            )
        }
        await mac.coordinator.synchronize()
        let stored = server.storedAssetBytes
        server.resetFetchMeasurements()

        let phone = try await FakeCloudKitDevice.open(
            root.appending(path: "phone"), server: server
        )
        await phone.coordinator.synchronize()

        assertExchanged(phone.coordinator.status)
        XCTAssertEqual(phone.replica.placements.count, 3)
        XCTAssertLessThanOrEqual(server.fetchMeasurements.assetBytes, stored)
        let check = try XCTUnwrap(
            phone.log.entries.last { $0.event == "server_check_fetched" }
        )
        XCTAssertEqual(check.counts["notes"], 0)
    }

    func testCheckReadsAllPages() async throws {
        let (mac, phone) = try await openSyncedPair()
        server.losesPushes = true
        server.zoneChangesPageSize = 1
        let first = try await mac.replica.createNote(name: "a.md", text: "a\n")
        let second = try await mac.replica.createNote(name: "b.md", text: "b\n")
        await mac.coordinator.synchronize()

        let reads = server.zoneChangeReadCount
        await phone.transport.requestServerCheck()
        await phone.coordinator.synchronize()

        assertExchanged(phone.coordinator.status)
        let ids = Set(phone.replica.placements.map(\.item.id))
        XCTAssertTrue(ids.isSuperset(of: [first, second]))
        XCTAssertGreaterThan(server.zoneChangeReadCount, reads + 1)

        phone.log.clear()
        server.zoneChangesPageSize = nil
        await phone.transport.requestServerCheck()
        await phone.coordinator.synchronize()
        let unchanged = try XCTUnwrap(
            phone.log.entries.last { $0.event == "server_check_fetched" }
        )
        XCTAssertEqual(unchanged.counts["notes"], 0)
    }

    /// When the push arrives after a check, the engine delivers the same
    /// deletions again. Those must not reopen the retirement either.
    func testEngineDoesNotReopenDeletionsResolvedByCheck() async throws {
        let (mac, phone) = try await openSyncedPair()
        server.losesPushes = true
        let note = try await mac.replica.createNote(name: "new.md", text: "new\n")
        await mac.coordinator.synchronize()
        await phone.transport.requestServerCheck()
        await phone.coordinator.synchronize()
        let session = try await mac.replica.openNote(note)
        try session.replaceText(
            in: NSRange(location: session.text.utf16.count, length: 0),
            with: "edited\n"
        )
        try await session.flush()
        await mac.coordinator.synchronize()
        _ = try await mac.coordinator.cleanupSnapshots()
        await phone.transport.requestServerCheck()
        await phone.coordinator.synchronize()
        XCTAssertTrue(phone.log.entries.contains {
            $0.event == "retirement_plan_start"
        }, "The check should have delivered the cleanup's deletions")

        phone.log.clear()
        server.losesPushes = false
        await phone.coordinator.synchronize()

        assertExchanged(phone.coordinator.status)
        let fetched = try XCTUnwrap(
            phone.log.entries.last { $0.event == "engine_fetched" }
        )
        XCTAssertGreaterThan(fetched.counts["deletions"] ?? 0, 0)
        XCTAssertFalse(phone.log.entries.contains {
            $0.event == "retirement_plan_start"
        })
    }

    /// Deleting the iCloud data and seeding it again from another device
    /// replaces the notebook. Sync stops instead of mixing the two.
    func testCheckHaltsWhenZoneHoldsAnotherNotebook() async throws {
        let (_, phone) = try await openSyncedPair()
        server.losesPushes = true
        server.deleteZone()
        let tablet = try await FakeCloudKitDevice.open(
            root.appending(path: "tablet"), server: server
        )
        await tablet.coordinator.synchronize()
        _ = try await tablet.replica.createNote(name: "other.md", text: "other\n")
        await tablet.coordinator.synchronize()
        assertExchanged(tablet.coordinator.status)
        let notes = phone.replica.placements.count

        // The pass's bootstrap notices the new notebook first.
        await phone.transport.requestServerCheck()
        await phone.coordinator.synchronize()
        XCTAssertEqual(phone.coordinator.lastError as? SyncError, .identityConflict)
        XCTAssertEqual(phone.replica.placements.count, notes)

        // The direct read checks on its own as well.
        var cursor: String?
        do {
            while true {
                let page = try await phone.transport.fetch(after: cursor)
                guard page.hasMore else { break }
                cursor = page.cursor
            }
            XCTFail("Expected the check to stop sync")
        } catch {}
        let halt = await phone.transport.haltStatus()
        XCTAssertEqual(halt?.reason, .unexpectedDeletion)
    }

    /// Both devices have synced once, which also used up the server check
    /// each new transport starts with.
    private func openSyncedPair() async throws -> (
        FakeCloudKitDevice, FakeCloudKitDevice
    ) {
        let mac = try await FakeCloudKitDevice.open(
            root.appending(path: "mac"), server: server
        )
        let phone = try await FakeCloudKitDevice.open(
            root.appending(path: "phone"), server: server
        )
        await mac.coordinator.synchronize()
        await phone.coordinator.synchronize()
        assertExchanged(phone.coordinator.status)
        return (mac, phone)
    }

    private func assertExchanged(
        _ status: NotebookSyncCoordinator.Status,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case .exchanged = status else {
            return XCTFail("Expected exchanged, got \(status)", file: file, line: line)
        }
    }
}
