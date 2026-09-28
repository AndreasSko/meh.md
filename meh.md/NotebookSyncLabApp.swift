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
              ["account", "exchange", "publish", "receive", "edit", "verify"]
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
            if phase == "publish",
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
            if phase == "exchange" {
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
            } else if phase == "publish" {
                let source = NotebookReplica(directory: sourceRoot.appending(path: "notebook"))
                try await measure("create_source_fixture") {
                    try await source.createLocalNotebook()
                    var firstID: UUID?
                    for index in 0..<10 {
                        let id = try await source.createNote(
                            name: "Fictional lab note \(index).md",
                            text: "Synthetic sync lab \(runID) note \(index)\n"
                        )
                        if firstID == nil { firstID = id }
                    }
                    guard let firstID else { throw LabError.missingFixture }
                    try saveManifest(FixtureManifest(
                        runID: runID, firstNoteID: firstID,
                        baseText: "Synthetic sync lab \(runID) note 0\n"
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
}
#endif
