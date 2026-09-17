import CryptoKit
import NoteCore
import Observation
import SwiftUI

@MainActor
@Observable
final class AppWorkspace {
    private(set) var session: NoteSession?
    private(set) var markdownCopy: MarkdownCopyController?
    private(set) var sync: NoteSyncCoordinator?
    private(set) var configurationError: String?
    private(set) var syncSetupError: String?
    private(set) var label: String?
    private(set) var automaticSync = true
    private var started = false
    private var retrying = false

    func start() async {
        guard !started else { return }
        started = true
        do {
            var directory = URL.applicationSupportDirectory.appending(path: "Notes")
            var documents = URL.documentsDirectory
            var transport: (any SyncTransport)?
            let environment = ProcessInfo.processInfo.environment
            automaticSync = environment["MEH_SYNC_AUTOMATIC"] != "0"
#if ICLOUD_ENABLED
            #if ICLOUD_DEV
            label = "iCloud Dev"
            #else
            label = "iCloud"
            #endif
            if hasExistingNote(in: directory) {
                // An established iCloud workspace remains editable when the
                // account or network is temporarily unavailable.
                session = NoteSession(storage: NoteFileStorage(directory: directory))
                markdownCopy = MarkdownCopyController(
                    applicationSupportDirectory: directory.appending(path: "MarkdownCopy"),
                    documentsDirectory: documents
                )
            }
            do {
                transport = try await CloudKitSyncTransport.make(
                    containerIdentifier: "iCloud.de.andreas-sk.meh-md",
                    stateDirectory: directory.appending(path: "CloudKit")
                )
            } catch {
                syncSetupError = error.localizedDescription
            }
#elseif DEBUG
            if let endpoint = environment["MEH_SYNC_URL"] {
                guard let url = URL(string: endpoint),
                      let workspace = environment["MEH_SYNC_WORKSPACE"],
                      workspace.range(
                        of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression
                      ) != nil else {
                    throw SyncError.unavailable("Set a local sync URL and a workspace name containing letters, numbers, dashes, or underscores.")
                }
                let local = LocalSyncTransport(baseURL: url, workspace: workspace)
                transport = local
                // A provider change never points at another workspace's note.
                let key = SHA256.hash(data: Data(local.scope.utf8)).map {
                    String(format: "%02x", $0)
                }.joined()
                directory = URL.applicationSupportDirectory
                    .appending(path: "SyncWorkspaces/\(key)/Notes")
                documents = URL.documentsDirectory
                    .appending(path: "SyncWorkspaces/\(workspace)")
                label = "Local sync · \(workspace)"
                try FileManager.default.createDirectory(
                    at: documents, withIntermediateDirectories: true
                )
            } else if environment["MEH_SYNC_CLOUDKIT"] == "1" {
                // Explicit development opt-in; no network access by default.
                label = "iCloud sync prototype"
                if hasExistingNote(in: directory) {
                    // Publish the existing local workspace before awaiting
                    // account discovery. Offline reopening must not wait for
                    // CloudKit to respond.
                    session = NoteSession(storage: NoteFileStorage(directory: directory))
                    markdownCopy = MarkdownCopyController(
                        applicationSupportDirectory: directory.appending(path: "MarkdownCopy"),
                        documentsDirectory: documents
                    )
                }
                do {
                    transport = try await CloudKitSyncTransport.make(
                        containerIdentifier: "iCloud.de.andreas-sk.meh-md",
                        stateDirectory: directory.appending(path: "CloudKit")
                    )
                } catch {
                    // Signing/account/network failures must not lock the
                    // existing local note behind a CloudKit setup screen.
                    syncSetupError = error.localizedDescription
                }
            }
#endif
#if DEBUG
            if environment["MEH_SYNC_SIMULATE_OFFLINE"] == "1", let connected = transport {
                // Test a transport outage without changing the device's
                // network or the durable account/workspace identity.
                transport = UnavailableDevelopmentTransport(scope: connected.scope)
            }
#endif
            let fileStore = NoteFileStorage(directory: directory)
            let storage: any NoteStorage
            var bootstrapStorage: SyncBootstrapStorage?
#if ICLOUD_ENABLED
            let allowsOfflineFirstLaunch = false
#else
            let allowsOfflineFirstLaunch = true
#endif
            if let transport {
                let bootstrap = SyncBootstrapStorage(
                    storage: fileStore, transport: transport,
                    proposalURL: directory.appending(path: "bootstrap-proposal.json"),
                    allowsOfflineFirstLaunch: allowsOfflineFirstLaunch
                )
                bootstrapStorage = bootstrap
                storage = bootstrap
            } else {
                storage = fileStore
            }
#if ICLOUD_ENABLED
            guard transport != nil || session != nil else { return }
#endif
            let note = session ?? NoteSession(storage: storage)
#if ICLOUD_ENABLED
            if session == nil, let bootstrapStorage {
                await note.load()
                guard note.isEditingEnabled else {
                    syncSetupError = await bootstrapStorage
                        .bootstrapErrorDescription()
                        ?? "The canonical iCloud note is not available yet."
                    return
                }
            }
#endif
            session = note
            if markdownCopy == nil {
                markdownCopy = MarkdownCopyController(
                    applicationSupportDirectory: directory.appending(path: "MarkdownCopy"),
                    documentsDirectory: documents
                )
            }
            if let transport {
                sync = NoteSyncCoordinator(
                    session: note, transport: transport,
                    stateURL: directory.appending(path: "sync-state.json")
                )
            }
        } catch {
            configurationError = error.localizedDescription
        }
    }

    func retryCloudSync() async {
        guard !retrying else { return }
        retrying = true
        defer { retrying = false }
#if ICLOUD_ENABLED
        if session == nil {
            started = false
            syncSetupError = nil
            await start()
            return
        }
#endif
        guard let session, sync == nil else { return }
        do {
            let directory = URL.applicationSupportDirectory.appending(path: "Notes")
            let transport = try await CloudKitSyncTransport.make(
                containerIdentifier: "iCloud.de.andreas-sk.meh-md",
                stateDirectory: directory.appending(path: "CloudKit")
            )
            sync = NoteSyncCoordinator(
                session: session, transport: transport,
                stateURL: directory.appending(path: "sync-state.json")
            )
            syncSetupError = nil
            await sync?.synchronize()
        } catch { syncSetupError = error.localizedDescription }
    }

    private func hasExistingNote(in directory: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: directory.appending(path: "note.automerge").path
        ) || FileManager.default.fileExists(
            atPath: directory.appending(path: "note.previous.automerge").path
        )
    }
}

struct WorkspaceView: View {
    let workspace: AppWorkspace

    var body: some View {
        Group {
            if let session = workspace.session,
               let copy = workspace.markdownCopy {
                ContentView(
                    session: session, markdownCopy: copy,
                    sync: workspace.sync, workspaceLabel: workspace.label,
                    automaticSync: workspace.automaticSync,
                    syncSetupError: workspace.syncSetupError,
                    retrySyncSetup: { await workspace.retryCloudSync() }
                )
            } else if let error = workspace.syncSetupError {
                ContentUnavailableView {
                    Label("iCloud unavailable", systemImage: "icloud.slash")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry iCloud Setup") {
                        Task { await workspace.retryCloudSync() }
                    }
                }
            } else if let error = workspace.configurationError {
                ContentUnavailableView(
                    "Workspace unavailable", systemImage: "exclamationmark.icloud",
                    description: Text(error)
                )
            } else {
                ProgressView("Opening workspace…")
            }
        }
        .task { await workspace.start() }
    }
}
