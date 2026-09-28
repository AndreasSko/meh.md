import CloudKit
import Foundation
@testable import NoteCore
import XCTest

/// Opt-in synthetic benchmark for the repeated CloudKit bootstrap validation
/// path. It creates no CloudKit container and uses only fictional catalog data.
final class CloudKitBootstrapValidationPerformanceTests: XCTestCase {
    private let clock = ContinuousClock()
    private let notebookID = UUID(
        uuidString: "11111111-1111-4111-8111-111111111111"
    )!

    func testRepeatedBootstrapValidation() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment[
                "MEH_BOOTSTRAP_VALIDATION_BENCHMARK"
            ] == "1",
            "Set MEH_BOOTSTRAP_VALIDATION_BENCHMARK=1 to run this benchmark."
        )

        for itemCount in [100, 1_000] {
            try measureCase(itemCount: itemCount)
        }
    }

    private func measureCase(itemCount: Int) throws {
        let fixture = try makeFixture(itemCount: itemCount)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var state = CloudKitTransportState(
            accountRecordName: "synthetic-benchmark-account",
            zoneName: CloudKitTransportMode.notebook.zoneName,
            protocolVersion: 2
        )
        var cache = CloudKitBootstrapValidationCache()
        try state.appendToInbox(fixture.proposal)

        // Warm the exact production path before collecting three samples.
        let warmed = try runPath(
            fixture: fixture, state: &state, cache: &cache
        )
        XCTAssertEqual(warmed, fixture.proposal)
        XCTAssertEqual(state.inbox.count, 1)

        var proposalSamples: [Double] = []
        var decodeSamples: [Double] = []
        var appendSamples: [Double] = []
        var completeSamples: [Double] = []
        for _ in 0..<3 {
            let completeStart = clock.now

            let proposalStart = clock.now
            let proposal = try cache.validate(
                fixture.proposal, mode: .notebook
            )
            proposalSamples.append(milliseconds(since: proposalStart))

            let decodeStart = clock.now
            let decoded = try fixture.codec.decodeBootstrap(
                fixture.canonicalCKRecord, using: &cache
            )
            decodeSamples.append(milliseconds(since: decodeStart))

            let appendStart = clock.now
            try state.appendToInbox(decoded)
            appendSamples.append(milliseconds(since: appendStart))
            completeSamples.append(milliseconds(since: completeStart))

            XCTAssertEqual(proposal.record, fixture.proposal)
            XCTAssertEqual(decoded.record, fixture.proposal)
            XCTAssertEqual(state.inbox.count, 1)
            XCTAssertEqual(state.inbox.first, fixture.proposal)
        }

        let report: [String: Any] = [
            "benchmark": "cloudkit_bootstrap_validation",
            "fixture_version": 1,
            "fixture_label": "synthetic_worst_case_canonical_catalog",
            "protocol_version": 2,
            "catalog_item_count": itemCount,
            "record_count": state.inbox.count,
            "snapshot_bytes": fixture.proposal.snapshot.data.count,
            "asset_bytes": fixture.assetBytes,
            "repetitions": 3,
            "phases_ms": [
                "proposal_validation_cache": proposalSamples,
                "canonical_decode_and_cache_match": decodeSamples,
                "validated_duplicate_inbox_append": appendSamples,
                "complete_path": completeSamples,
            ],
        ]
        let data = try JSONSerialization.data(
            withJSONObject: report, options: [.sortedKeys]
        )
        FileHandle.standardOutput.write(
            Data("BOOTSTRAP_BENCHMARK ".utf8) + data + Data("\n".utf8)
        )
    }

    private func runPath(
        fixture: Fixture,
        state: inout CloudKitTransportState,
        cache: inout CloudKitBootstrapValidationCache
    ) throws -> SyncRecord {
        let proposal = try cache.validate(fixture.proposal, mode: .notebook)
        let decoded = try fixture.codec.decodeBootstrap(
            fixture.canonicalCKRecord, using: &cache
        )
        try state.appendToInbox(decoded)
        return proposal.record
    }

    private func makeFixture(itemCount: Int) throws -> Fixture {
        let catalog = try NotebookCatalogDocument(notebookID: notebookID)
        for index in 0..<itemCount {
            try catalog.add(
                id: noteID(for: index),
                kind: .note,
                name: "Fictional Note \(index + 1).md"
            )
        }
        let proposal = SyncRecord(catalog: catalog.snapshot())
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CloudKitBootstrapBenchmark-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let assetURL = directory.appendingPathComponent("catalog.snapshot")
        try proposal.snapshot.data.write(to: assetURL, options: .atomic)
        let codec = CloudKitRecordCodec(
            mode: .notebook,
            zoneID: CKRecordZone.ID(zoneName: CloudKitTransportMode.notebook.zoneName)
        )
        let canonicalCKRecord = try codec.encode(
            proposal,
            id: CKRecord.ID(
                recordName: CloudKitTransportMode.notebook.bootstrapName,
                zoneID: codec.zoneID
            ),
            assetURL: assetURL
        )
        let assetBytes = proposal.snapshot.data.count
        return Fixture(
            proposal: proposal,
            canonicalCKRecord: canonicalCKRecord,
            codec: codec,
            directory: directory,
            assetBytes: assetBytes
        )
    }

    private func noteID(for index: Int) -> UUID {
        UUID(
            uuidString: String(format:
                "00000000-0000-4000-8000-%012x", index + 1)
        )!
    }

    private func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: clock.now).components
        return Double(duration.seconds) * 1_000
            + Double(duration.attoseconds) / 1_000_000_000_000_000
    }
}

private struct Fixture {
    let proposal: SyncRecord
    let canonicalCKRecord: CKRecord
    let codec: CloudKitRecordCodec
    let directory: URL
    let assetBytes: Int
}
