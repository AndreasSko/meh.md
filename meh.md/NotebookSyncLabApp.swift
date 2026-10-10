#if SYNC_LAB
#if !DEBUG || !ICLOUD_DEV
#error("The sync lab requires the Debug-iCloud configuration.")
#endif

import CloudKit
import Foundation
@_spi(SyncLab) import NoteCore
import SwiftUI

/// Built explicitly by the lab runner. It has no normal app delegate,
/// shared workspace, backup scheduler, or production notebook access.
#if os(macOS)
@main struct NotebookSyncLabApp {
    static func main() async {
        await NotebookSyncLab.run { value in
            print(value)
            fflush(stdout)
        }
    }
}
#else
@main struct NotebookSyncLabApp: App {
    var body: some Scene {
        WindowGroup {
            NotebookSyncLabView()
        }
    }
}
#endif

private struct NotebookSyncLabView: View {
    @State private var status = "Synthetic sync lab"
    @State private var started = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Sync Lab").font(.title)
            Text("Fictional data · isolated Development zone")
            Text(status).accessibilityIdentifier("sync-lab-status")
        }
        .padding(32)
        .task {
            guard !started else { return }
            started = true
            await NotebookSyncLab.run { status = $0 }
            // This entry point exists only in an explicitly built lab app.
            // Ending it lets device automation collect the completed report.
            exit(0)
        }
    }
}

@MainActor private enum NotebookSyncLab {
    static let container = "iCloud.de.andreas-sk.meh-md"
    static var hasRun = false

    struct Report: Codable {
        let runID: UUID
        let phase: String
        let startedAt = Date()
        var status = "running"
        var stage = "starting"
        var accountStatus: Int?
        var measurementsMS: [String: [Double]] = [:]
        var errorCode: String?
        var finishedAt: Date?
        var events: [String: [NotebookSyncEventLog.Entry]] = [:]
        var requestTimingsMS: [String: [String: [Double]]] = [:]
        var noteID: UUID?
        var expectedText: String?
        var observedText: String?
        var observedHeadsCount: Int?
        var cleanup: CleanupMeasurements?
        var notebookID: UUID?
        var notes: [ObservedNote]?
    }

    struct CleanupMeasurements: Codable {
        let snapshotsBefore: Int
        let snapshotsAfter: Int
        let compressedBytesBefore: Int
        let compressedBytesAfter: Int
        let deletedSnapshots: Int
        let deletedCompressedBytes: Int
        let preservedPastVersions: Int
    }

    struct ObservedNote: Codable {
        let id: UUID
        let name: String
        let text: String
        let heads: Set<String>
    }

    struct FixtureManifest: Codable {
        let runID: UUID
        let firstNoteID: UUID
        let baseText: String
    }

    enum LabError: String, Error {
        case invalidLaunch, syncFailed, convergenceFailed
        case existingFixture, missingFixture, unexpectedContent
    }

    static func synchronize(_ coordinator: NotebookSyncCoordinator) async throws {
        await coordinator.synchronize()
        if let error = coordinator.lastError { throw error }
        guard case .exchanged = coordinator.status else { throw LabError.syncFailed }
    }

    static func saveManifest(_ manifest: FixtureManifest, at url: URL) throws {
        try JSONEncoder().encode(manifest).write(to: url, options: .atomic)
    }

    static func loadManifest(at url: URL, runID: UUID) throws -> FixtureManifest {
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(FixtureManifest.self, from: data),
              manifest.runID == runID else { throw LabError.missingFixture }
        return manifest
    }

    static func run(update: (String) -> Void) async {
        guard !hasRun else { return }
        hasRun = true
        let environment = ProcessInfo.processInfo.environment
        guard environment["MEH_SYNC_LAB_ALLOW_DEVELOPMENT"] == "1",
              let rawRun = environment["MEH_SYNC_LAB_RUN"],
              let runID = UUID(uuidString: rawRun),
              let phase = environment["MEH_SYNC_LAB_PHASE"],
              ["account", "exchange", "offline-join", "offline-ui-seed",
               "offline-ui-verify", "publish", "receive", "edit", "verify", "cleanup"]
                .contains(phase) else {
            update("Stopped: explicit lab launch configuration required")
            return
        }
        // The runner verifies the signed Development entitlement before
        // installing or launching this binary. UUID paths never use Notebook.
        let runRoot = URL.documentsDirectory.appending(
            path: "SyncLab/\(runID.uuidString.lowercased())"
        )
        let root = runRoot.appending(path: phase)
        let sourceRoot = runRoot.appending(path: "source")
        let receiverRoot = runRoot.appending(path: "receiver")
        var report = Report(runID: runID, phase: phase)
        var diagnostics: [String: NotebookSyncEventLog] = [:]
        var transports: [String: CloudKitSyncTransport] = [:]
        func save() throws {
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(report).write(
                to: root.appending(path: "report.json"), options: .atomic
            )
            // Export only this run's synthetic report through the process
            // pipe; the runner needs no access to protected app containers.
            let output = try JSONEncoder().encode(report)
            FileHandle.standardOutput.write(
                Data("SYNC_LAB_REPORT ".utf8) + output + Data("\n".utf8)
            )
            update(report.status + ": " + report.stage)
        }
        func measure<T>(_ phase: String, _ action: () async throws -> T)
            async throws -> T {
            report.stage = phase
            try save()
            let start = ContinuousClock.now
            let result = try await action()
            let duration = start.duration(to: .now).components
            let ms = Double(duration.seconds) * 1_000
                + Double(duration.attoseconds) / 1_000_000_000_000_000
            report.measurementsMS[phase, default: []].append(ms)
            try save()
            return result
        }
        do {
            if ["publish", "offline-ui-seed"].contains(phase),
               FileManager.default.fileExists(atPath: sourceRoot.path)
                || FileManager.default.fileExists(atPath: receiverRoot.path) {
                throw LabError.existingFixture
            }
            try save()
            let account = try await measure("account_status") {
                try await CKContainer(identifier: container).accountStatus()
            }
            report.accountStatus = account.rawValue
            guard account == .available else {
                throw CloudKitSyncTransportError.accountUnavailable
            }
            if phase == "cleanup" {
                // Only this fresh run's fictional zone and stores are opened.
                // Each edit publishes a full-history immutable snapshot.
                guard !FileManager.default.fileExists(
                    atPath: root.appending(path: "source").path
                ) else { throw LabError.existingFixture }
                let source = NotebookReplica(
                    directory: root.appending(path: "source")
                )
                try await source.createLocalNotebook()
                let noteID = try await source.createNote(
                    name: "Fictional cleanup journal.md",
                    text: "Fictional cleanup journal\n"
                )
                let editor = try await source.openNote(noteID)
                guard let catalog = source.catalogSnapshot,
                      let first = editor.currentSnapshot else {
                    throw LabError.missingFixture
                }
                let notebookID = catalog.notebookID
                let seed = SyncRecord(catalog: catalog)
                var snapshots = [SyncRecord(snapshot: first, notebookID: notebookID)]
                for index in 0..<24 {
                    try editor.replaceAll(
                        with: "Fictional revision \(index): a preserved edit.\n"
                            + editor.text
                    )
                    try await editor.flush()
                    guard let snapshot = editor.currentSnapshot else {
                        throw LabError.missingFixture
                    }
                    snapshots.append(SyncRecord(
                        snapshot: snapshot, notebookID: notebookID
                    ))
                }
                let writer = try await measure("cleanup_writer_transport") {
                    try await CloudKitSyncTransport.makeIsolatedNotebookLab(
                        containerIdentifier: container,
                        stateDirectory: root.appending(path: "writer/transport"),
                        runID: runID
                    )
                }
                transports["writer"] = writer
                guard try await writer.bootstrap(proposing: seed) == seed else {
                    throw LabError.existingFixture
                }
                try await measure("cleanup_fixture_upload") {
                    let result = try await writer.publishBatch(snapshots + [seed])
                    if let error = result.error { throw error }
                    guard result.acknowledgedIDs
                        == Set((snapshots + [seed]).map(\.id)) else {
                        throw LabError.syncFailed
                    }
                }
                let before = try await CloudKitSyncTransport.makeIsolatedNotebookLab(
                    containerIdentifier: container,
                    stateDirectory: root.appending(path: "before/transport"),
                    runID: runID
                )
                transports["before"] = before
                _ = try await before.bootstrap(proposing: seed)
                let beforeRecords = try await measure("cleanup_fresh_fetch_before") {
                    try await drain(before)
                }
                let result = try await measure("cleanup_delete") {
                    try await writer.cleanupRedundantSnapshots(notebookID: notebookID)
                }
                let after = try await CloudKitSyncTransport.makeIsolatedNotebookLab(
                    containerIdentifier: container,
                    stateDirectory: root.appending(path: "after/transport"),
                    runID: runID
                )
                transports["after"] = after
                let confirmedSeed = try await after.bootstrap(proposing: seed)
                guard confirmedSeed == seed else { throw LabError.convergenceFailed }
                let afterRecords = try await measure("cleanup_fresh_fetch_after") {
                    try await drain(after)
                }
                guard let latest = snapshots.last,
                      afterRecords.contains(latest),
                      afterRecords.count < beforeRecords.count,
                      result.deletedSnapshotCount == snapshots.count - 1 else {
                    throw LabError.convergenceFailed
                }
                guard let received = afterRecords.first(where: { $0.id == latest.id })
                else { throw LabError.convergenceFailed }
                let preserved = try await history(received.snapshot)
                let expected = try await history(latest.snapshot)
                guard preserved.versions == expected.versions,
                      preserved.texts == expected.texts,
                      preserved.versions.count == 24 else {
                    throw LabError.convergenceFailed
                }
                report.cleanup = CleanupMeasurements(
                    snapshotsBefore: beforeRecords.count,
                    snapshotsAfter: afterRecords.count,
                    compressedBytesBefore: beforeRecords.reduce(0) {
                        $0 + $1.snapshot.data.count
                    },
                    compressedBytesAfter: afterRecords.reduce(0) {
                        $0 + $1.snapshot.data.count
                    },
                    deletedSnapshots: result.deletedSnapshotCount,
                    deletedCompressedBytes: result.deletedCompressedPayloadBytes,
                    preservedPastVersions: preserved.versions.count
                )
            } else if phase == "exchange" {
                let senderTransport = try await measure("sender_transport") {
                    try await CloudKitSyncTransport.makeIsolatedNotebookLab(
                        containerIdentifier: container,
                        stateDirectory: root.appending(path: "sender/transport"),
                        runID: runID
                    )
                }
                transports["sender"] = senderTransport
                let receiverTransport = try await measure("receiver_transport") {
                    try await CloudKitSyncTransport.makeIsolatedNotebookLab(
                        containerIdentifier: container,
                        stateDirectory: root.appending(path: "receiver/transport"),
                        runID: runID
                    )
                }
                transports["receiver"] = receiverTransport
                let source = NotebookReplica(directory: root.appending(path: "sender/notebook"))
                let destination = NotebookReplica(directory: root.appending(path: "receiver/notebook"))
                try await source.createLocalNotebook()
                var firstID: UUID?
                for index in 0..<10 {
                    let id = try await source.createNote(
                        name: "Fictional lab note \(index).md",
                        text: "Synthetic sync lab \(runID) note \(index)\n"
                    )
                    if firstID == nil { firstID = id }
                }
                let senderLog = NotebookSyncEventLog(directory: root.appending(path: "sender"))
                let receiverLog = NotebookSyncEventLog(directory: root.appending(path: "receiver"))
                diagnostics = ["sender": senderLog, "receiver": receiverLog]
                let sender = NotebookSyncCoordinator(
                    replica: source, transport: senderTransport,
                    diagnosticLog: senderLog
                )
                let receiver = NotebookSyncCoordinator(
                    replica: destination, transport: receiverTransport,
                    diagnosticLog: receiverLog
                )
                try await measure("initial_upload") { try await synchronize(sender) }
                try await measure("initial_download") { try await synchronize(receiver) }
                guard let firstID else { throw LabError.convergenceFailed }
                let editor = try await source.openNote(firstID)
                let receivingEditor = try await destination.openNote(firstID)
                // Opening both notes updates recent activity; settle metadata
                // and both durable catalog copies before character samples.
                for _ in 0..<2 {
                    try await measure("settle_sender") { try await synchronize(sender) }
                    try await measure("settle_receiver") { try await synchronize(receiver) }
                }
                for _ in 0..<3 {
                    let expected = editor.text + "x"
                    try await measure("edit_and_flush") {
                        try editor.replaceAll(with: expected)
                        try await editor.flush()
                    }
                    try await measure("character_upload") { try await synchronize(sender) }
                    try await measure("character_download") { try await synchronize(receiver) }
                    guard receivingEditor.text == expected else {
                        throw LabError.convergenceFailed
                    }
                }
            } else if phase == "offline-join" {
                let source = NotebookReplica(directory: root.appending(path: "source/notebook"))
                let destination = NotebookReplica(directory: root.appending(path: "destination/notebook"))
                try await source.createNotebookForSync()
                try await destination.createNotebookForSync()
                let cloudID = try await source.createNote(name: "Cloud example.md", text: "# Cloud example\n")
                let localID = try await destination.createNote(name: "Offline example.md", text: "# Offline example\r\n")
                let local = try await destination.openNote(localID)
                let originalHeads = local.currentSnapshot?.heads
                let publisher = NotebookMarkdownPublisher(directory: root.appending(path: "copies"))
                try await publisher.publish(catalog: destination.catalogSnapshot!,
                    placements: destination.placements, notes: destination.persistedNoteSnapshots())
                let sourceTransport = try await CloudKitSyncTransport.makeIsolatedNotebookLab(
                    containerIdentifier: container, stateDirectory: root.appending(path: "source/transport"), runID: runID)
                let destinationTransport = try await CloudKitSyncTransport.makeIsolatedNotebookLab(
                    containerIdentifier: container, stateDirectory: root.appending(path: "destination/transport"), runID: runID)
                transports = ["source": sourceTransport, "destination": destinationTransport]
                let sourceSync = NotebookSyncCoordinator(replica: source, transport: sourceTransport)
                let destinationSync = NotebookSyncCoordinator(replica: destination, transport: destinationTransport)
                try await measure("offline_first_cloud") { try await synchronize(sourceSync) }
                try await measure("offline_existing_cloud") { try await synchronize(destinationSync) }
                try await measure("offline_convergence") { try await synchronize(sourceSync) }
                try await destination.prepareMarkdownCopiesForFirstSync(publisher)
                try await publisher.publish(catalog: destination.catalogSnapshot!,
                    placements: destination.placements, notes: destination.persistedNoteSnapshots())
                let uploaded = try await source.openNote(localID)
                guard source.catalogSnapshot?.notebookID == destination.catalogSnapshot?.notebookID,
                      Set(source.placements.map { $0.item.id }) == [localID, cloudID],
                      Set(destination.placements.map { $0.item.id }) == [localID, cloudID],
                      uploaded.text == local.text, uploaded.currentSnapshot?.heads == originalHeads,
                      try Data(contentsOf: publisher.directory.appending(path: "Markdown/Offline example.md"))
                        == Data("# Offline example\r\n".utf8) else { throw LabError.convergenceFailed }
                let reopened = NotebookReplica(directory: destination.directory)
                try await reopened.load()
                try await synchronize(NotebookSyncCoordinator(replica: reopened, transport: destinationTransport))
                guard Set(reopened.placements.map { $0.item.id }) == [localID, cloudID] else {
                    throw LabError.convergenceFailed
                }
                report.noteID = localID
                report.expectedText = local.text
                report.observedText = uploaded.text
                report.observedHeadsCount = uploaded.currentSnapshot?.heads.count
            } else if phase == "publish" || phase == "offline-ui-seed" {
                let source = NotebookReplica(directory: sourceRoot.appending(path: "notebook"))
                try await measure("create_source_fixture") {
                    try await source.createLocalNotebook()
                    var firstID: UUID?
                    let interactiveSeed = phase == "offline-ui-seed"
                    let baseText = interactiveSeed
                        ? "# Already in iCloud\n\nThis note was here before the simulator connected.\n"
                        : "Synthetic sync lab \(runID) note 0\n"
                    for index in 0..<(interactiveSeed ? 1 : 10) {
                        let id = try await source.createNote(
                            name: interactiveSeed ? "Already in iCloud.md" : "Fictional lab note \(index).md",
                            text: interactiveSeed ? baseText : "Synthetic sync lab \(runID) note \(index)\n"
                        )
                        if firstID == nil { firstID = id }
                    }
                    guard let firstID else { throw LabError.missingFixture }
                    try saveManifest(FixtureManifest(
                        runID: runID, firstNoteID: firstID,
                        baseText: baseText
                    ), at: sourceRoot.appending(path: "manifest.json"))
                    report.noteID = firstID
                }
                let transport = try await measure("source_transport") {
                    try await CloudKitSyncTransport.makeIsolatedNotebookLab(
                        containerIdentifier: container,
                        stateDirectory: sourceRoot.appending(path: "transport"),
                        runID: runID
                    )
                }
                transports["source"] = transport
                let log = NotebookSyncEventLog(directory: sourceRoot)
                diagnostics["source"] = log
                let coordinator = NotebookSyncCoordinator(
                    replica: source, transport: transport, diagnosticLog: log
                )
                try await measure("initial_upload") { try await synchronize(coordinator) }
                let manifest = try loadManifest(
                    at: sourceRoot.appending(path: "manifest.json"), runID: runID
                )
                let editor = try await source.openNote(manifest.firstNoteID)
                guard editor.text == manifest.baseText else {
                    throw LabError.convergenceFailed
                }
                report.expectedText = manifest.baseText
                report.observedText = editor.text
                report.observedHeadsCount = editor.currentSnapshot?.heads.count
            } else if phase == "offline-ui-verify" {
                let manifest = try loadManifest(
                    at: sourceRoot.appending(path: "manifest.json"), runID: runID
                )
                let source = NotebookReplica(directory: sourceRoot.appending(path: "notebook"))
                try await source.load()
                let transport = try await CloudKitSyncTransport.makeIsolatedNotebookLab(
                    containerIdentifier: container,
                    stateDirectory: sourceRoot.appending(path: "transport"), runID: runID
                )
                transports["source"] = transport
                let log = NotebookSyncEventLog(directory: sourceRoot)
                diagnostics["source"] = log
                let coordinator = NotebookSyncCoordinator(
                    replica: source, transport: transport, diagnosticLog: log
                )
                try await measure("download_simulator_notes") { try await synchronize(coordinator) }
                var notes: [ObservedNote] = []
                for placement in source.placements where placement.item.kind == .note {
                    let editor = try await source.openNote(placement.item.id)
                    guard let snapshot = editor.currentSnapshot else {
                        throw LabError.convergenceFailed
                    }
                    notes.append(ObservedNote(
                        id: placement.item.id, name: placement.item.name,
                        text: editor.text, heads: snapshot.heads
                    ))
                }
                guard notes.contains(where: {
                    $0.id == manifest.firstNoteID && $0.text == manifest.baseText
                }) else { throw LabError.convergenceFailed }
                report.notebookID = source.catalogSnapshot?.notebookID
                report.notes = notes
            } else if phase == "receive" {
                let transport = try await measure("receiver_transport") {
                    try await CloudKitSyncTransport.makeIsolatedNotebookLab(
                        containerIdentifier: container,
                        stateDirectory: receiverRoot.appending(path: "transport"),
                        runID: runID
                    )
                }
                transports["receiver"] = transport
                let destination = NotebookReplica(
                    directory: receiverRoot.appending(path: "notebook")
                )
                let log = NotebookSyncEventLog(directory: receiverRoot)
                diagnostics["receiver"] = log
                let coordinator = NotebookSyncCoordinator(
                    replica: destination, transport: transport,
                    diagnosticLog: log
                )
                try await measure("initial_download") { try await synchronize(coordinator) }
                let notes = destination.placements.filter { $0.item.kind == .note }
                guard notes.count == 10,
                      let firstID = notes.first(where: {
                          $0.item.name == "Fictional lab note 0.md"
                      })?.item.id else { throw LabError.convergenceFailed }
                let editor = try await destination.openNote(firstID)
                let expected = "Synthetic sync lab \(runID) note 0\n"
                guard editor.text == expected,
                      let heads = editor.currentSnapshot?.heads, !heads.isEmpty else {
                    throw LabError.convergenceFailed
                }
                try saveManifest(FixtureManifest(
                    runID: runID, firstNoteID: firstID, baseText: expected
                ), at: receiverRoot.appending(path: "manifest.json"))
                report.noteID = firstID
                report.expectedText = expected
                report.observedText = editor.text
                report.observedHeadsCount = heads.count
            } else if phase == "edit" {
                let manifest = try loadManifest(
                    at: sourceRoot.appending(path: "manifest.json"), runID: runID
                )
                let source = NotebookReplica(directory: sourceRoot.appending(path: "notebook"))
                try await source.load()
                let transport = try await measure("source_transport") {
                    try await CloudKitSyncTransport.makeIsolatedNotebookLab(
                        containerIdentifier: container,
                        stateDirectory: sourceRoot.appending(path: "transport"),
                        runID: runID
                    )
                }
                transports["source"] = transport
                let editor = try await source.openNote(manifest.firstNoteID)
                guard editor.text == manifest.baseText else {
                    throw LabError.unexpectedContent
                }
                let expected = manifest.baseText + "x"
                try await measure("edit_and_flush") {
                    try editor.replaceAll(with: expected)
                    try await editor.flush()
                }
                let log = NotebookSyncEventLog(directory: sourceRoot)
                diagnostics["source"] = log
                let coordinator = NotebookSyncCoordinator(
                    replica: source, transport: transport, diagnosticLog: log
                )
                try await measure("character_upload") { try await synchronize(coordinator) }
                report.noteID = manifest.firstNoteID
                report.expectedText = expected
                report.observedText = editor.text
                report.observedHeadsCount = editor.currentSnapshot?.heads.count
            } else if phase == "verify" {
                let manifest = try loadManifest(
                    at: receiverRoot.appending(path: "manifest.json"), runID: runID
                )
                let destination = NotebookReplica(
                    directory: receiverRoot.appending(path: "notebook")
                )
                try await destination.load()
                let transport = try await measure("receiver_transport") {
                    try await CloudKitSyncTransport.makeIsolatedNotebookLab(
                        containerIdentifier: container,
                        stateDirectory: receiverRoot.appending(path: "transport"),
                        runID: runID
                    )
                }
                transports["receiver"] = transport
                // Open the live editor before fetching so the receive path
                // must merge into that session and durably flush it.
                let editor = try await destination.openNote(manifest.firstNoteID)
                guard editor.text == manifest.baseText else {
                    throw LabError.unexpectedContent
                }
                let log = NotebookSyncEventLog(directory: receiverRoot)
                diagnostics["receiver"] = log
                let coordinator = NotebookSyncCoordinator(
                    replica: destination, transport: transport,
                    diagnosticLog: log
                )
                try await measure("character_download") { try await synchronize(coordinator) }
                let expected = manifest.baseText + "x"
                guard editor.text == expected,
                      let heads = editor.currentSnapshot?.heads, !heads.isEmpty else {
                    throw LabError.convergenceFailed
                }
                report.noteID = manifest.firstNoteID
                report.expectedText = expected
                report.observedText = editor.text
                report.observedHeadsCount = heads.count
            }
            report.status = "passed"
            report.stage = "complete"
        } catch {
            report.status = "failed"
            if let labError = error as? LabError {
                report.errorCode = "LabError.\(labError.rawValue)"
            } else {
                report.errorCode = NotebookSyncEventLog.errorCode(error)
            }
        }
        report.finishedAt = Date()
        report.events = diagnostics.mapValues(\.entries)
        for (name, transport) in transports {
            report.requestTimingsMS[name] = await transport.labRequestTimings()
        }
        do { try save() }
        catch { update("Failed to save lab report") }
    }

    static func history(_ snapshot: NoteSnapshot) async throws -> (
        versions: [NoteHistoryVersion], texts: [String]
    ) {
        let reader = NoteHistoryReader(snapshot: snapshot)
        var versions: [NoteHistoryVersion] = []
        for try await update in await reader.updates() {
            if update.isComplete { versions = update.versions }
        }
        var texts: [String] = []
        for version in versions {
            texts.append(try await reader.historicalText(for: version))
        }
        return (versions, texts)
    }

    static func drain(_ transport: CloudKitSyncTransport) async throws -> [SyncRecord] {
        var records: [SyncRecord] = []
        var cursor: String?
        repeat {
            let page = try await transport.fetch(after: cursor)
            records.append(contentsOf: page.records)
            cursor = page.cursor
            if !page.hasMore { return records }
        } while true
    }
}
#endif
