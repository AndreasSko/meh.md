import Foundation
import XCTest

@testable import NoteCore

@MainActor
final class NotebookSyncStressTests: XCTestCase {
    private static let defaultSeeds: [UInt64] = [0x5EED, 0xC0FFEE, 0xBAD5EED]

    func testSeededThreeReplicaDisruptionScenarios() async throws {
        for seed in configuredSeeds() {
            try await runDisruptionScenario(seed: seed)
        }
    }

    func testSyntheticNotebookScale() async throws {
        for count in configuredScaleCounts() {
            try await runScaleScenario(noteCount: count)
        }
    }

    private func runScaleScenario(noteCount: Int) async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "notebook-sync-scale-\(noteCount)-\(UUID())"
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDirectory = root.appending(path: "source")
        let destinationDirectory = root.appending(path: "destination")
        let folderCount = max(1, noteCount / 20)
        let folderIDs = (0..<folderCount).map {
            deterministicID(1_000_000 + $0)
        }
        let folders = folderIDs.enumerated().map { index, id in
            NotebookImportEntry(
                id: id,
                kind: .folder,
                name: String(format: "folder-%03d", index),
                parentID: nil,
                text: nil
            )
        }
        let expected = Dictionary(uniqueKeysWithValues: (0..<noteCount).map {
            index in
            let lengths = [0, 31, 257, 2_048]
            let text = "note \(index)\n" + String(
                repeating: Character(UnicodeScalar(97 + index % 26)!),
                count: lengths[index % lengths.count]
            )
            return (deterministicID(index), text)
        })
        let notes = (0..<noteCount).map { index in
            NotebookImportEntry(
                id: deterministicID(index),
                kind: .note,
                name: String(format: "note-%04d.md", index),
                parentID: folderIDs[index % folderIDs.count],
                text: expected[deterministicID(index)]!
            )
        }
        let plan = NotebookImportPlan(
            id: deterministicID(2_000_000),
            entries: folders + notes,
            skippedPaths: []
        )

        let source = NotebookReplica(directory: sourceDirectory)
        try await source.createLocalNotebook()
        let importStart = ContinuousClock.now
        try await source.importMarkdown(plan)
        let importTime = importStart.duration(to: .now)
        reportScale(noteCount, phase: "import", duration: importTime)

        let reopenStart = ContinuousClock.now
        let reopened = NotebookReplica(directory: sourceDirectory)
        try await reopened.load()
        let reopenTime = reopenStart.duration(to: .now)
        reportScale(noteCount, phase: "reopen", duration: reopenTime)
        XCTAssertEqual(
            reopened.placements.filter { $0.item.kind == .note }.count,
            noteCount
        )
        XCTAssertEqual(
            reopened.placements.filter { $0.item.kind == .folder }.count,
            folderCount
        )

        let transport = InMemorySyncTransport(scope: "scale-\(noteCount)")
        let sourceSync = NotebookSyncCoordinator(
            replica: reopened,
            transport: transport
        )
        let destination = NotebookReplica(directory: destinationDirectory)
        let destinationSync = NotebookSyncCoordinator(
            replica: destination,
            transport: transport
        )
        let initialSyncStart = ContinuousClock.now
        await sourceSync.synchronize()
        await destinationSync.synchronize()
        await sourceSync.synchronize()
        let initialSyncTime = initialSyncStart.duration(to: .now)
        reportScale(noteCount, phase: "initialSync", duration: initialSyncTime)
        try assertSuccessful(sourceSync)
        try assertSuccessful(destinationSync)
        XCTAssertEqual(destination.placements, reopened.placements)

        let receivedRecords = try await destination.records()
        let receivedBodies = receivedRecords.filter { $0.kind == .note }
        XCTAssertEqual(receivedBodies.count, noteCount)
        for record in receivedBodies {
            let document = try NoteDocument(snapshot: record.snapshot)
            let bodyText = try document.text
            XCTAssertEqual(bodyText, expected[document.noteID])
        }

        let editedID = deterministicID(noteCount / 2)
        let marker = "\nincremental-\(noteCount)"
        let incrementalStart = ContinuousClock.now
        let edited = try await reopened.openNote(editedID)
        try edited.replaceText(
            in: NSRange(location: edited.text.utf16.count, length: 0),
            with: marker
        )
        try await edited.flush()
        await sourceSync.synchronize()
        await destinationSync.synchronize()
        let incrementalTime = incrementalStart.duration(to: .now)
        reportScale(noteCount, phase: "incremental", duration: incrementalTime)
        try assertSuccessful(sourceSync)
        try assertSuccessful(destinationSync)
        let receivedEdit = try await destination.openNote(editedID)
        XCTAssertEqual(receivedEdit.text, expected[editedID]! + marker)
        XCTAssertEqual(
            destination.placements.filter { $0.item.kind == .note }.count,
            noteCount
        )

    }

    private func reportScale(
        _ noteCount: Int,
        phase: String,
        duration: Duration
    ) {
        let line = "Notebook scale \(noteCount): \(phase)=\(duration)\n"
        FileHandle.standardOutput.write(Data(line.utf8))
    }

    private func runDisruptionScenario(seed: UInt64) async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "notebook-sync-stress-\(String(seed, radix: 16))-\(UUID())"
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let store = InMemorySyncStore()
        let chaos = DeliveryChaos(seed: seed)
        let base = InMemorySyncTransport(
            scope: "stress-\(String(seed, radix: 16))",
            store: store,
            pageSize: 1_000
        )
        let transport = ReorderedDuplicateTransport(base: base, chaos: chaos)
        let directories = (0..<3).map { root.appending(path: "replica-\($0)") }
        var replicas = directories.map(NotebookReplica.init(directory:))
        var coordinators = replicas.map {
            NotebookSyncCoordinator(replica: $0, transport: transport)
        }

        for coordinator in coordinators { await coordinator.synchronize() }

        let sharedFolder = try await replicas[0].createFolder(name: "Shared")
        let sharedNote = try await replicas[0].createNote(
            name: "shared.md",
            text: "base\n",
            parentID: sharedFolder
        )
        let removedFolder = try await replicas[0].createFolder(name: "Removed")
        let removedNote = try await replicas[0].createNote(
            name: "old.md",
            text: "old",
            parentID: removedFolder
        )
        await synchronizeAll(coordinators, rounds: 2)

        let staleRecords = try await replicas[2].records()
        let staleBody = try XCTUnwrap(
            staleRecords.first {
                $0.kind == .note && $0.snapshot.noteID == removedNote
            }
        )
        await store.setOffline(true)

        var generator = SeededGenerator(seed: seed)
        var expectedNotes: [(UUID, String)] = []
        var editMarkers: [String] = []
        for replicaIndex in replicas.indices {
            let marker = "seed-\(String(seed, radix: 16))-r\(replicaIndex)"
            editMarkers.append(marker)
            let session = try await replicas[replicaIndex].openNote(sharedNote)
            try session.replaceText(
                in: NSRange(location: session.text.utf16.count, length: 0),
                with: marker + "\n"
            )
            try await session.flush()

            for operation in 0..<2 {
                let token = generator.next()
                let text = "durable-\(replicaIndex)-\(operation)-\(token)"
                let id = try await replicas[replicaIndex].createNote(
                    name: "\(replicaIndex)-\(operation)-\(token).md",
                    text: text
                )
                expectedNotes.append((id, text))
            }
        }

        let survivor = try await replicas[2].createNote(
            name: "unknown-child.md",
            text: "survives",
            parentID: removedFolder
        )
        let staleSession = try await replicas[2].openNote(removedNote)
        try staleSession.replaceAll(with: "offline stale edit")
        try await staleSession.flush()

        try await replicas[0].setTrashed(removedFolder, true)
        try await replicas[0].permanentlyDelete(
            replicas[0].deletionSelection(rootID: removedFolder)
        )

        replicas = directories.map(NotebookReplica.init(directory:))
        coordinators = replicas.map {
            NotebookSyncCoordinator(replica: $0, transport: transport)
        }
        for index in replicas.indices {
            try await replicas[index].load()
            let session = try await replicas[index].openNote(sharedNote)
            XCTAssertTrue(
                session.text.contains(editMarkers[index]),
                "Seed \(seed) replica \(index) lost its durable offline edit"
            )
        }

        await store.setOffline(false)
        await store.loseNextAcknowledgement()
        await coordinators[0].synchronize()
        await coordinators[0].synchronize()
        try await transport.publish(staleBody)

        for _ in 0..<6 {
            for index in generator.shuffled(Array(replicas.indices)) {
                await coordinators[index].synchronize()
            }
        }
        await synchronizeAll(coordinators, rounds: 2)

        for coordinator in coordinators { try assertSuccessful(coordinator) }
        let expectedPlacements = replicas[0].placements
        XCTAssertTrue(expectedPlacements.contains { $0.item.id == survivor })
        let recovered = try XCTUnwrap(
            expectedPlacements.first { $0.item.id == survivor }
        )
        XCTAssertNil(recovered.parentID)
        XCTAssertTrue(recovered.issues.contains(.missingParent))
        XCTAssertFalse(expectedPlacements.contains { $0.item.id == removedNote })
        XCTAssertFalse(expectedPlacements.contains { $0.item.id == removedFolder })

        let convergedShared = try await replicas[0].openNote(sharedNote)
        let convergedSharedText = convergedShared.text
        for replica in replicas {
            XCTAssertEqual(replica.placements, expectedPlacements)
            let shared = try await replica.openNote(sharedNote)
            XCTAssertEqual(shared.text, convergedSharedText)
            for marker in editMarkers {
                XCTAssertTrue(shared.text.contains(marker))
            }
            let survivorSession = try await replica.openNote(survivor)
            XCTAssertEqual(survivorSession.text, "survives")
            for (id, text) in expectedNotes {
                let session = try await replica.openNote(id)
                XCTAssertEqual(session.text, text)
            }
            XCTAssertTrue(try replica.deletedIDs.contains(removedNote))
        }

        let finalReplicas = directories.map(NotebookReplica.init(directory:))
        for replica in finalReplicas {
            try await replica.load()
            XCTAssertEqual(replica.placements, expectedPlacements)
            let survivorSession = try await replica.openNote(survivor)
            XCTAssertEqual(survivorSession.text, "survives")
            do {
                _ = try await replica.openNote(removedNote)
                XCTFail("Seed \(seed) resurrected a permanently deleted note")
            } catch let error as NotebookReplicaError {
                XCTAssertEqual(error, .permanentlyDeleted(removedNote))
            }
        }

        let delivery = await chaos.statistics()
        XCTAssertGreaterThan(delivery.reorderedPages, 0)
        XCTAssertGreaterThan(delivery.duplicateRecords, 0)
    }

    private func synchronizeAll(
        _ coordinators: [NotebookSyncCoordinator],
        rounds: Int
    ) async {
        for _ in 0..<rounds {
            for coordinator in coordinators { await coordinator.synchronize() }
        }
    }

    private func assertSuccessful(_ coordinator: NotebookSyncCoordinator) throws {
        if case .failed(let message) = coordinator.status {
            XCTFail(message)
            throw SyncError.unavailable(message)
        }
    }

    private func configuredSeeds() -> [UInt64] {
        guard let value = ProcessInfo.processInfo.environment[
            "MEH_NOTEBOOK_STRESS_SEEDS"
        ] else { return Self.defaultSeeds }
        let seeds = value.split(separator: ",").compactMap {
            UInt64($0.trimmingCharacters(in: .whitespaces))
        }
        return Array(seeds.prefix(12)).isEmpty ? Self.defaultSeeds : Array(
            seeds.prefix(12)
        )
    }

    private func configuredScaleCounts() -> [Int] {
        guard let value = ProcessInfo.processInfo.environment[
            "MEH_NOTEBOOK_SCALE_COUNTS"
        ] else { return [100] }
        let counts = value.split(separator: ",").compactMap {
            Int($0.trimmingCharacters(in: .whitespaces))
        }.filter { (1...1_000).contains($0) }
        let selected = Array(Set(counts)).sorted()
        return selected.isEmpty ? [100] : selected
    }

    private func deterministicID(_ index: Int) -> UUID {
        UUID(
            uuidString: String(
                format: "00000000-0000-0000-0000-%012llX",
                UInt64(index + 1)
            )
        )!
    }
}

private struct ReorderedDuplicateTransport: SyncTransport, Sendable {
    nonisolated let scope: String
    let base: InMemorySyncTransport
    let chaos: DeliveryChaos

    init(base: InMemorySyncTransport, chaos: DeliveryChaos) {
        scope = base.scope
        self.base = base
        self.chaos = chaos
    }

    func bootstrap(proposing record: SyncRecord) async throws -> SyncRecord {
        try await base.bootstrap(proposing: record)
    }

    func publish(_ record: SyncRecord) async throws {
        try await base.publish(record)
    }

    func fetch(after cursor: String?) async throws -> SyncPage {
        let page = try await base.fetch(after: cursor)
        return await chaos.transform(page)
    }

    func purgeDeletedNotes(
        _ noteIDs: Set<UUID>,
        notebookID: UUID
    ) async throws {
        try await base.purgeDeletedNotes(noteIDs, notebookID: notebookID)
    }
}

private actor DeliveryChaos {
    private var generator: SeededGenerator
    private var reorderedPages = 0
    private var duplicateRecords = 0

    init(seed: UInt64) {
        generator = SeededGenerator(seed: seed ^ 0xD311_73A5)
    }

    func transform(_ page: SyncPage) -> SyncPage {
        guard !page.records.isEmpty else { return page }
        var records = generator.shuffled(page.records)
        if records.count > 1 { reorderedPages += 1 }
        let duplicate = records[Int(generator.next() % UInt64(records.count))]
        records.insert(duplicate, at: Int(generator.next() % UInt64(records.count + 1)))
        duplicateRecords += 1
        return SyncPage(
            records: records,
            cursor: page.cursor,
            hasMore: page.hasMore
        )
    }

    func statistics() -> (reorderedPages: Int, duplicateRecords: Int) {
        (reorderedPages, duplicateRecords)
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func shuffled<Element>(_ values: [Element]) -> [Element] {
        values.shuffled(using: &self)
    }
}
