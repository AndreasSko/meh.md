import Foundation
import NoteCore
import Observation

/// Activates the local notebook used by the early navigation preview.
///
/// The existing workspace remains the default until the app explicitly opts
/// into this model with `MEH_NOTEBOOK_PREVIEW=1` in a Debug build.
@MainActor
@Observable
final class NotebookWorkspace {
    static var isPreviewEnabled: Bool {
        #if DEBUG && !ICLOUD_DEV
            let environment = ProcessInfo.processInfo.environment
            return environment["MEH_NOTEBOOK_PREVIEW"] == "1"
                && environment["MEH_SYNC_URL"] == nil
                && environment["MEH_SYNC_CLOUDKIT"] != "1"
        #else
            false
        #endif
    }

    private(set) var replica: NotebookReplica?
    private(set) var errorMessage: String?
    private(set) var isLoading = false

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let legacyDirectory: URL

    init(
        directory: URL = URL.applicationSupportDirectory
            .appending(path: "NotebookPreview"),
        legacyDirectory: URL = URL.applicationSupportDirectory
            .appending(path: "Notes")
    ) {
        self.directory = directory
        self.legacyDirectory = legacyDirectory
    }

    /// Migrates the legacy note without removing its files, then opens the
    /// durable local catalog. Calling this again retries a failed activation.
    func start() async {
        guard replica == nil, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            _ = try await NotebookMigration(directory: directory)
                .migrateLegacyNote(from: legacyDirectory)
            let replica = NotebookReplica(directory: directory)
            try await replica.load()
            self.replica = replica
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
