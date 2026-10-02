import Foundation
import NoteCore
import Observation

struct NotebookIncomingImport: Identifiable, Equatable {
    let plan: NotebookImportPlan
    var id: UUID { plan.id }
}

/// Read a document handoff while its security-scoped URL is still available.
/// The destination sheet works with the copied plan, never the original file.
@MainActor
@Observable
final class NotebookIncomingImportRequests {
    private(set) var requests: [NotebookIncomingImport] = []
    private(set) var readingCount = 0
    var errorMessage: String?

    func receive(_ url: URL) {
        guard url.isFileURL else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        readingCount += 1
        Task { @MainActor in
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
                readingCount -= 1
            }
            do {
                let plan = try await NotebookImportScanner().scan(urls: [url])
                guard !plan.entries.isEmpty else {
                    errorMessage = String(localized: "No Markdown files or ordinary folders were found. Hidden items, links, packages, and other file types are skipped.")
                    return
                }
                requests.append(NotebookIncomingImport(plan: plan))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func finish(_ request: NotebookIncomingImport) {
        requests.removeAll { $0.id == request.id }
    }
}
