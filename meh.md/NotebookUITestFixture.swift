import Foundation
import NoteCore

#if DEBUG
/// Fictional data is created only in an explicitly isolated preview run.
/// Catalog UUIDs are generated once and remain stable when the run relaunches.
enum NotebookUITestFixture: String, CaseIterable {
    case writing
    case historyRestore = "history-restore"
    case dragOrder = "drag-order"
    case dragNested = "drag-nested"
    case dragSubtree = "drag-subtree"
    case dragLongList = "drag-long-list"

    static let historyOriginalSource = "Morning light over the ridge."
    static let historyCurrentSource = "Morning light over the ridge.\nClear."

    static let literalSource =
        "# Fictional voyage\n\nLiteral **Markdown** stays intact."

    static func requested(
        environment: [String: String], isPreview: Bool, directory: URL
    ) -> Self? {
        guard isPreview, environment["MEH_NOTEBOOK_PREVIEW"] == "1",
              environment["MEH_SYNC_TEST_TRANSPORT"] == nil,
              environment["MEH_SYNC_URL"] == nil,
              environment["MEH_SYNC_CLOUDKIT"] != "1",
              let run = environment["MEH_NOTEBOOK_PREVIEW_RUN"],
              run.range(of: "^[A-Za-z0-9_-]{1,64}$",
                        options: .regularExpression) != nil,
              directory.lastPathComponent == run,
              directory.deletingLastPathComponent().lastPathComponent
                == "NotebookPreviewTests" else { return nil }
        if let name = environment["MEH_NOTEBOOK_TEST_FIXTURE"] {
            guard let fixture = Self(rawValue: name) else {
                print("Unknown MEH_NOTEBOOK_TEST_FIXTURE: \(name)")
                return nil
            }
            return fixture
        }
        switch environment["MEH_NOTEBOOK_DRAG_FIXTURE"] {
        case "long-list": return .dragLongList
        default: return nil
        }
    }

    static func seedIfRequested(
        _ replica: NotebookReplica, isPreview: Bool, directory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws {
        guard let fixture = requested(
            environment: environment, isPreview: isPreview, directory: directory
        ) else { return }
        // Reopening the same run must retain IDs and any scenario edits.
        guard replica.orderedChildren(parentID: nil).isEmpty else { return }
        try await fixture.seed(replica)
    }

    private func seed(_ replica: NotebookReplica) async throws {
        switch self {
        case .historyRestore:
            let id = try await replica.createNote(
                name: "Recovery Sketch.md", text: Self.historyOriginalSource)
            let session = try await replica.openNote(id)
            try session.replaceAll(with: Self.historyCurrentSource)
            try await session.flush()
        case .writing:
            _ = try await replica.createNote(
                name: "Fictional field notes.md", text: Self.literalSource)
            _ = try await replica.createNote(
                name: "Save boundary.md", text: "# Save boundary\n\nFictional notes.")
        case .dragOrder:
            for name in ["Charlie", "Alpha", "Bravo"] {
                _ = try await replica.createNote(
                    name: "\(name).md",
                    text: name == "Bravo" ? Self.literalSource : "# Fictional \(name)")
            }
            let journeys = try await replica.createFolder(name: "Journeys")
            _ = try await replica.createFolder(name: "Weekend", parentID: journeys)
        case .dragNested, .dragLongList:
            if self == .dragLongList {
                for number in 1 ... 48 {
                    _ = try await replica.createNote(
                        name: String(format: "%02d Field observation.md", number),
                        text: "# Fictional observation \(number)\n\nSample voyage notes.\n")
                }
            } else {
                _ = try await replica.createNote(
                    name: "Travel checklist.md",
                    text: "# Fictional voyage\n\nSample checklist.\n")
            }
            let journeys = try await replica.createFolder(name: "Journeys")
            let weekend = try await replica.createFolder(
                name: "Weekend", parentID: journeys)
            if self == .dragLongList {
                _ = try await replica.createNote(
                    name: "Island.md",
                    text: "# Fictional island\n\nA sample itinerary.\n",
                    parentID: weekend)
            }
        case .dragSubtree:
            _ = try await replica.createNote(
                name: "Packing list.md", text: Self.literalSource)
            let trips = try await replica.createFolder(name: "Trips")
            _ = try await replica.createFolder(name: "Island", parentID: trips)
            _ = try await replica.createFolder(name: "Archive")
        }
    }
}
#endif
