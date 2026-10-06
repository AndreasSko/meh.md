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
        var scenario: String?
        var noteCount: Int?
        var localNoteID: UUID?
        var expectedLocalText: String?
        var observedLocalText: String?
        var engineAutomaticallySync: Bool?
        var diagnosticChecks: [String: Bool] = [:]
        var directReadbackErrorCode: String?
        var remoteFixturePublisher: String?
    }

    struct FixtureManifest: Codable {
        let runID: UUID
        let firstNoteID: UUID
        let baseText: String
    }

    struct ActivationManifest: Codable {
        let runID: UUID
        let noteIDs: [UUID]
        let remoteBaseText: String
        let localBaseText: String
        let remoteSuffix: String
        let foregroundRemoteSuffix: String
        let localSuffix: String
        let foregroundLocalSuffix: String
    }

    struct ExternalForegroundReady: Codable {
        let runID: UUID
        let phase: String
        let expectedText: String
    }

    static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) * 1_000
            + Double(duration.attoseconds) / 1_000_000_000_000_000
    }

    /// Opens this workspace's session once local loading exposes the replica.
    /// Polling only measures model visibility; it makes no screen/APNs claim.
    static func waitForVisibleText(
        workspace: NotebookWorkspace, noteID: UUID, expected: String,
        since start: ContinuousClock.Instant
    ) async throws -> Double {
        let deadline = start.advanced(by: .seconds(120))
        var editor: NoteSession?
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if editor == nil, let replica = workspace.replica {
                editor = try await replica.openNote(noteID)
            }
            if editor?.text == expected { return milliseconds(since: start) }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw LabError.convergenceFailed
    }

    static func serverRecordChecks(
        _ cloudRecord: CKRecord, expected: SyncRecord
    ) throws -> [String: Bool] {
        let asset = cloudRecord["document"] as? CKAsset
        let data = try asset?.fileURL.map { try Data(contentsOf: $0) }
        let encodedHeads = cloudRecord["heads"] as? Data
        let heads = try encodedHeads.map {
            try JSONDecoder().decode(Set<String>.self, from: $0)
        }
        return [
            "serverAssetBytesMatch": data == expected.snapshot.data,
            "serverHeadsMatch": heads == expected.snapshot.heads,
            "serverMetadataMatch": cloudRecord.recordType == "AutomergeNotebookSnapshotV2"
                && cloudRecord.recordID.recordName == expected.id
                && cloudRecord["snapshotID"] as? String == expected.id
                && cloudRecord["documentID"] as? String == expected.snapshot.noteID.uuidString
                && cloudRecord["notebookID"] as? String == expected.notebookID?.uuidString
                && cloudRecord["kind"] as? String == "note"
                && (cloudRecord["protocolVersion"] as? NSNumber)?.intValue == 2,
        ]
    }

    /// Synthetic remote fixture writer only. Production receiver operations
    /// still use their ordinary transport; this avoids a second logical
    /// CKSyncEngine sender sharing the same simulator's system cache.
    static func publishRemoteFixture(
        source: NotebookReplica, noteID: UUID, runID: UUID, activationRoot: URL
    ) async throws {
        let snapshots = try await source.persistedNoteSnapshots()
        guard let snapshot = snapshots.first(where: { $0.noteID == noteID }),
              let notebookID = source.catalogSnapshot?.notebookID else {
            throw LabError.missingFixture
        }
        let value = SyncRecord(snapshot: snapshot, notebookID: notebookID)
        try value.validate()
        let assets = activationRoot.appending(path: "fixtureAssets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let assetURL = assets.appending(path: value.id + ".automerge")
        try snapshot.data.write(to: assetURL, options: .atomic)
        let zoneID = CKRecordZone.ID(
            zoneName: "meh-md-notebook-lab-v2-" + runID.uuidString.lowercased(),
            ownerName: CKCurrentUserDefaultName
        )
        let recordID = CKRecord.ID(recordName: value.id, zoneID: zoneID)
        let record = CKRecord(recordType: "AutomergeNotebookSnapshotV2", recordID: recordID)
        record["snapshotID"] = value.id
        record["protocolVersion"] = NSNumber(value: value.protocolVersion)
        record["kind"] = value.kind.rawValue
        record["notebookID"] = notebookID.uuidString
        record["documentID"] = snapshot.noteID.uuidString
        record["heads"] = try JSONEncoder().encode(snapshot.heads)
        record["document"] = CKAsset(fileURL: assetURL)
        let database = CKContainer(identifier: container).privateCloudDatabase
        _ = try await database.save(record)
        let saved = try await database.record(for: recordID)
        guard try serverRecordChecks(saved, expected: value).values.allSatisfy({ $0 }) else {
            throw LabError.convergenceFailed
        }
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
              ["account", "exchange", "publish", "receive", "edit", "verify",
               "activation-prepare", "activation-update", "activation-startup",
               "activation-foreground", "activation-readback",
               "activation-publish-startup", "activation-publish-foreground"]
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
            if phase.hasPrefix("activation-") {
                // A reused Dev container may carry normal app preferences.
                // Do not let a pending normal reset reach Workspace.start().
                guard !UserDefaults.standard.bool(forKey: "meh.md.resetLocalStorage") else {
                    throw LabError.invalidLaunch
                }
                let externalPublisher = environment["MEH_SYNC_LAB_EXTERNAL_PUBLISHER"] == "1"
                let activationRoot = runRoot.appending(path: "activation")
                let manifestURL = activationRoot.appending(path: "manifest.json")
                let sourceDirectory = activationRoot.appending(path: "source/notebook")
                func baseText(_ index: Int) -> String {
                    "Fictional activation lab \(runID) note \(index)\n"
                }
                func sourceCoordinator() async throws
                    -> (NotebookReplica, NotebookSyncCoordinator) {
                    let replica = NotebookReplica(directory: sourceDirectory)
                    try await replica.load()
                    let transport = try await measure("activation_source_transport") {
                        try await CloudKitSyncTransport.makeIsolatedNotebookLab(
                            containerIdentifier: container,
                            stateDirectory: activationRoot.appending(path: "source/transport"),
                            runID: runID
                        )
                    }
                    transports["activation-source"] = transport
                    let log = NotebookSyncEventLog(
                        directory: activationRoot.appending(path: "source")
                    )
                    diagnostics["activation-source"] = log
                    return (replica, NotebookSyncCoordinator(
                        replica: replica, transport: transport, diagnosticLog: log
                    ))
                }
                func workspace(
                    role: String, engineAutomatic: Bool, workspaceAutomatic: Bool = true
                ) -> NotebookWorkspace {
                    let roleRoot = activationRoot.appending(path: role)
                    let workspace = NotebookWorkspace(
                        directory: roleRoot.appending(path: "notebook"),
                        documentsDirectory: roleRoot.appending(path: "documents"),
                        transport: nil, automaticSync: workspaceAutomatic, mode: .cloud,
                        transportFactory: { expectedScope in
                            let transport = try await CloudKitSyncTransport
                                .makeIsolatedNotebookLab(
                                    containerIdentifier: container,
                                    stateDirectory: roleRoot.appending(path: "transport"),
                                    runID: runID, automaticallySync: engineAutomatic
                                )
                            if let expectedScope, transport.scope != expectedScope {
                                await transport.retire()
                                throw SyncError.scopeChanged
                            }
                            transports[role] = transport
                            return transport
                        }
                    )
                    diagnostics[role] = workspace.syncEventLog
                    return workspace
                }
                func loadActivationManifest() throws -> ActivationManifest {
                    guard let data = try? Data(contentsOf: manifestURL),
                          let manifest = try? JSONDecoder().decode(
                            ActivationManifest.self, from: data
                          ), manifest.runID == runID,
                          (2...1_000).contains(manifest.noteIDs.count) else {
                        throw LabError.missingFixture
                    }
                    return manifest
                }
                func validateWorkspace(_ workspace: NotebookWorkspace) throws {
                    if let error = workspace.sync?.lastError { throw error }
                    guard workspace.sync != nil, workspace.syncSetupError == nil else {
                        throw LabError.syncFailed
                    }
                }
                func dirtyLocalNotes(
                    replica: NotebookReplica, manifest: ActivationManifest,
                    notify: NotebookWorkspace? = nil, foreground: Bool = false
                ) async throws {
                    for index in 1..<manifest.noteIDs.count {
                        let editor = try await replica.openNote(manifest.noteIDs[index])
                        let before = baseText(index) + (foreground ? manifest.localSuffix : "")
                        let suffix = foreground ? manifest.foregroundLocalSuffix : manifest.localSuffix
                        let expected = before + suffix
                        guard editor.text == before else {
                            throw LabError.unexpectedContent
                        }
                        try editor.replaceAll(with: expected)
                        notify?.noteDidEdit()
                        try await editor.flush()
                    }
                    notify?.contentDidSave(trigger: "fictional lab local backlog")
                }
                if phase == "activation-prepare" {
                    guard !FileManager.default.fileExists(atPath: activationRoot.path) else {
                        throw LabError.existingFixture
                    }
                    let count = Int(environment["MEH_SYNC_LAB_NOTE_COUNT"] ?? "100") ?? 0
                    guard (2...1_000).contains(count) else { throw LabError.invalidLaunch }
                    report.noteCount = count
                    let source = NotebookReplica(directory: sourceDirectory)
                    try await source.createLocalNotebook()
                    var ids: [UUID] = []
                    for index in 0..<count {
                        ids.append(try await source.createNote(
                            name: "Fictional activation note \(index).md", text: baseText(index)
                        ))
                    }
                    let manifest = ActivationManifest(
                        runID: runID, noteIDs: ids,
                        remoteBaseText: baseText(0), localBaseText: baseText(1),
                        remoteSuffix: "Remote startup update \(runID)\n",
                        foregroundRemoteSuffix: "Remote foreground update \(runID)\n",
                        localSuffix: "Concurrent local edit \(runID)\n",
                        foregroundLocalSuffix: "Concurrent foreground local edit \(runID)\n"
                    )
                    let (_, coordinator) = try await sourceCoordinator()
                    try await measure("activation_fixture_upload") {
                        try await synchronize(coordinator)
                    }
                    for role in ["receiver-startup"] {
                        let receiver = workspace(role: role, engineAutomatic: false,
                                                 workspaceAutomatic: false)
                        receiver.backupFrequency = .off
                        try await measure("activation_fixture_join_" + role) {
                            await receiver.start()
                            try validateWorkspace(receiver)
                        }
                        guard receiver.replica?.placements.filter({
                            $0.item.kind == .note
                        }).count == count else { throw LabError.convergenceFailed }
                        if let transport = transports[role] { await transport.retire() }
                    }
                    try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
                } else {
                    let manifest = try loadActivationManifest()
                    report.noteCount = manifest.noteIDs.count
                    report.noteID = manifest.noteIDs[0]
                    report.localNoteID = manifest.noteIDs[1]
                    report.expectedLocalText = manifest.localBaseText + manifest.localSuffix
                    let publisherURL = activationRoot.appending(path: "fixture-publisher.json")
                    report.remoteFixturePublisher = (try? Data(contentsOf: publisherURL))
                        .flatMap { try? JSONDecoder().decode(String.self, from: $0) }
                        ?? "direct_CKDatabase_verified_immutable_snapshot"
                    if phase == "activation-update" {
                        let expected = manifest.remoteBaseText + manifest.remoteSuffix
                        if externalPublisher {
                            // Runner contract: the verified Mac publisher
                            // completed before this local-backlog phase.
                            report.remoteFixturePublisher = "external_host_CKDatabase_verified_before_phase"
                            report.expectedText = expected
                            report.observedText = expected
                        } else {
                            let source = NotebookReplica(directory: sourceDirectory)
                            try await source.load()
                            let editor = try await source.openNote(manifest.noteIDs[0])
                            guard editor.text == manifest.remoteBaseText else {
                                throw LabError.unexpectedContent
                            }
                            try editor.replaceAll(with: expected)
                            try await editor.flush()
                            try await measure("activation_remote_upload") {
                                try await publishRemoteFixture(
                                    source: source, noteID: manifest.noteIDs[0],
                                    runID: runID, activationRoot: activationRoot
                                )
                            }
                            report.expectedText = expected
                            report.observedText = editor.text
                        }
                        try JSONEncoder().encode(report.remoteFixturePublisher).write(
                            to: publisherURL, options: .atomic
                        )
                        // A different note carries the local backlog so exact
                        // text proves both independent edits survive the pass.
                        let destination = NotebookReplica(directory: activationRoot.appending(
                            path: "receiver-startup/notebook"
                        ))
                        try await destination.load()
                        try await measure("activation_local_backlog") {
                            try await dirtyLocalNotes(replica: destination, manifest: manifest)
                        }
                    } else if phase == "activation-publish-startup"
                        || phase == "activation-publish-foreground" {
                        report.scenario = "external_host_synthetic_fixture_publisher"
                        report.remoteFixturePublisher = "external_host_CKDatabase_verified_immutable_snapshot"
                        let source = NotebookReplica(directory: sourceDirectory)
                        try await source.load()
                        let editor = try await source.openNote(manifest.noteIDs[0])
                        let isForegroundPublisher = phase == "activation-publish-foreground"
                        let before = manifest.remoteBaseText
                            + (isForegroundPublisher ? manifest.remoteSuffix : "")
                        let suffix = isForegroundPublisher
                            ? manifest.foregroundRemoteSuffix : manifest.remoteSuffix
                        guard editor.text == before else { throw LabError.unexpectedContent }
                        let expected = before + suffix
                        try editor.replaceAll(with: expected)
                        try await editor.flush()
                        try await measure("activation_external_remote_upload") {
                            try await publishRemoteFixture(
                                source: source, noteID: manifest.noteIDs[0],
                                runID: runID, activationRoot: activationRoot
                            )
                        }
                        report.expectedText = expected
                        report.observedText = editor.text
                        report.observedHeadsCount = editor.currentSnapshot?.heads.count
                    } else if phase == "activation-readback" {
                        report.scenario = "isolated_backend_readback_and_fresh_receiver"
                        report.engineAutomaticallySync = false
                        let source = NotebookReplica(directory: sourceDirectory)
                        try await source.load()
                        let snapshots = try await source.persistedNoteSnapshots()
                        guard let snapshot = snapshots.first(where: {
                            $0.noteID == manifest.noteIDs[0]
                        }), let notebookID = source.catalogSnapshot?.notebookID else {
                            throw LabError.missingFixture
                        }
                        let editor = try await source.openNote(manifest.noteIDs[0])
                        let initialRemote = manifest.remoteBaseText + manifest.remoteSuffix
                        guard editor.text == initialRemote
                            || editor.text == initialRemote + manifest.foregroundRemoteSuffix else {
                            throw LabError.unexpectedContent
                        }
                        report.expectedText = editor.text
                        let expectedRecord = SyncRecord(snapshot: snapshot, notebookID: notebookID)
                        let zoneID = CKRecordZone.ID(
                            zoneName: "meh-md-notebook-lab-v2-" + runID.uuidString.lowercased(),
                            ownerName: CKCurrentUserDefaultName
                        )
                        let recordID = CKRecord.ID(recordName: expectedRecord.id, zoneID: zoneID)
                        report.stage = "direct_source_readback"
                        try save()
                        let readbackStarted = ContinuousClock.now
                        do {
                            let cloudRecord = try await CKContainer(identifier: container)
                                .privateCloudDatabase.record(for: recordID)
                            report.diagnosticChecks.merge(
                                try serverRecordChecks(cloudRecord, expected: expectedRecord)
                            ) { _, current in current }
                        } catch {
                            report.directReadbackErrorCode = NotebookSyncEventLog.errorCode(error)
                            report.diagnosticChecks["serverAssetBytesMatch"] = false
                            report.diagnosticChecks["serverHeadsMatch"] = false
                            report.diagnosticChecks["serverMetadataMatch"] = false
                        }
                        report.measurementsMS["direct_source_readback"] = [
                            milliseconds(since: readbackStarted)
                        ]
                        try save()
                        let freshRoot = activationRoot.appending(path: "receiver-readback")
                        guard !FileManager.default.fileExists(atPath: freshRoot.path) else {
                            throw LabError.existingFixture
                        }
                        let transport = try await CloudKitSyncTransport.makeIsolatedNotebookLab(
                            containerIdentifier: container,
                            stateDirectory: freshRoot.appending(path: "transport"),
                            runID: runID, automaticallySync: false
                        )
                        transports["receiver-readback"] = transport
                        let destination = NotebookReplica(directory: freshRoot.appending(path: "notebook"))
                        let log = NotebookSyncEventLog(directory: freshRoot)
                        diagnostics["receiver-readback"] = log
                        let coordinator = NotebookSyncCoordinator(
                            replica: destination, transport: transport, diagnosticLog: log
                        )
                        try await measure("diagnostic_fresh_receiver_fetch") {
                            try await synchronize(coordinator)
                        }
                        let received = try await destination.openNote(manifest.noteIDs[0])
                        report.observedText = received.text
                        report.observedHeadsCount = received.currentSnapshot?.heads.count
                        report.diagnosticChecks["freshReceiverTextMatch"] = received.text == editor.text
                        report.diagnosticChecks["freshReceiverContainsSourceHeads"] =
                            received.currentSnapshot?.heads.isSuperset(of: snapshot.heads) == true
                        guard report.diagnosticChecks.values.allSatisfy({ $0 }) else {
                            throw LabError.convergenceFailed
                        }
                    } else {
                        let isStartup = phase == "activation-startup"
                        // Reopen the same durable receiver after its startup
                        // sample, retaining its own acknowledged local edits.
                        let role = "receiver-startup"
                        let receiver = workspace(role: role, engineAutomatic: isStartup)
                        report.engineAutomaticallySync = isStartup
                        report.scenario = isStartup ? "cold_process_workspace_start"
                            : "controlled_workspace_foreground"
                        // Keep the due backup in the cold-start workload; the
                        // fixture preparation deliberately created no backup.
                        receiver.backupFrequency = isStartup ? .daily : .off
                        var expected = manifest.remoteBaseText + manifest.remoteSuffix
                        if !isStartup {
                            try await measure("activation_foreground_preload") {
                                await receiver.start()
                                try validateWorkspace(receiver)
                            }
                            if externalPublisher {
                                expected += manifest.foregroundRemoteSuffix
                                report.stage = "awaiting_external_foreground_publisher"
                                report.expectedText = expected
                                report.remoteFixturePublisher = "external_host_CKDatabase_verified_handoff"
                                try save()
                                let handoffURL = activationRoot.appending(
                                    path: "external-foreground-ready.json"
                                )
                                let handoffDeadline = ContinuousClock.now.advanced(by: .seconds(120))
                                while !FileManager.default.fileExists(atPath: handoffURL.path) {
                                    guard ContinuousClock.now < handoffDeadline else {
                                        throw LabError.missingFixture
                                    }
                                    try await Task.sleep(for: .milliseconds(50))
                                }
                                let handoff = try JSONDecoder().decode(
                                    ExternalForegroundReady.self,
                                    from: Data(contentsOf: handoffURL)
                                )
                                guard handoff.runID == runID,
                                      handoff.phase == "activation-publish-foreground",
                                      handoff.expectedText == expected else {
                                    throw LabError.unexpectedContent
                                }
                            } else {
                                let source = NotebookReplica(directory: sourceDirectory)
                                try await source.load()
                                let editor = try await source.openNote(manifest.noteIDs[0])
                                guard editor.text == expected else { throw LabError.unexpectedContent }
                                expected += manifest.foregroundRemoteSuffix
                                try editor.replaceAll(with: expected)
                                try await editor.flush()
                                try await measure("activation_foreground_remote_upload") {
                                    try await publishRemoteFixture(
                                        source: source, noteID: manifest.noteIDs[0],
                                        runID: runID, activationRoot: activationRoot
                                    )
                                }
                            }
                            guard let replica = receiver.replica else { throw LabError.missingFixture }
                            report.expectedLocalText = manifest.localBaseText
                                + manifest.localSuffix + manifest.foregroundLocalSuffix
                            try await dirtyLocalNotes(replica: replica, manifest: manifest,
                                                      notify: receiver, foreground: true)
                        }
                        report.expectedText = expected
                        report.stage = "activation_measuring"
                        try save()
                        let started = ContinuousClock.now
                        let visibility = Task { @MainActor in
                            try await waitForVisibleText(
                                workspace: receiver, noteID: manifest.noteIDs[0],
                                expected: expected, since: started
                            )
                        }
                        defer { visibility.cancel() }
                        func captureObservedContent() async {
                            guard let replica = receiver.replica else { return }
                            if let editor = try? await replica.openNote(manifest.noteIDs[0]) {
                                report.observedText = editor.text
                                report.observedHeadsCount = editor.currentSnapshot?.heads.count
                            }
                            if let editor = try? await replica.openNote(manifest.noteIDs[1]) {
                                report.observedLocalText = editor.text
                            }
                        }
                        do {
                            if isStartup {
                                await receiver.start()
                                report.measurementsMS["activation_initial_start"] = [
                                    milliseconds(since: started)
                                ]
                                // Deliver the initial foreground callback once
                                // loading ends, so the same old/new lifecycle
                                // cannot discard it through its loading guard.
                                // Both startup and activation remain timed.
                                report.scenario = "cold_process_workspace_start_then_foreground"
                            }
                            let refreshStartsBeforeActivation = receiver.syncEventLog.entries
                                .filter { $0.event.hasPrefix("refresh started:") }.count
                            receiver.sceneActivityChanged(id: UUID(), isActive: true)
                            report.measurementsMS["activation_foreground_dispatch"] = [
                                milliseconds(since: started)
                            ]
                            // Require the target text before testing idle: the
                            // old foreground timer can be pending while the
                            // workspace still reports no active refresh.
                            report.measurementsMS["activation_visible"] = [
                                try await visibility.value
                            ]
                            let deadline = started.advanced(by: .seconds(120))
                            while receiver.isRefreshing || receiver.isSyncing
                                || receiver.syncEventLog.entries.filter({
                                    $0.event.hasPrefix("refresh started:")
                                }).count <= refreshStartsBeforeActivation {
                                guard ContinuousClock.now < deadline else {
                                    throw LabError.syncFailed
                                }
                                try await Task.sleep(for: .milliseconds(10))
                            }
                            report.measurementsMS["activation_complete"] = [
                                milliseconds(since: started)
                            ]
                            await captureObservedContent()
                            try validateWorkspace(receiver)
                            guard let replica = receiver.replica,
                                  report.observedText == expected,
                                  report.observedLocalText == report.expectedLocalText,
                                  replica.placements.filter({ $0.item.kind == .note }).count
                                    == manifest.noteIDs.count else {
                                throw LabError.convergenceFailed
                            }
                        } catch {
                            // A timeout is evidence about what actually
                            // remained visible, not just a missing metric.
                            await captureObservedContent()
                            report.measurementsMS["activation_elapsed_at_failure"] = [
                                milliseconds(since: started)
                            ]
                            throw error
                        }
                    }
                }
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
