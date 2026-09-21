import NoteCore

/// The compact control distinguishes queued work from an actual sync failure.
nonisolated enum NotebookSyncIndicator: Equatable {
    case idle, waiting, checking, uploading, receiving, paused, failed

    init(
        isSyncing: Bool,
        phase: NotebookSyncProgress.Phase?,
        isRetryPaused: Bool,
        hasError: Bool,
        hasPendingChanges: Bool
    ) {
        if isRetryPaused {
            self = .paused
        } else if isSyncing {
            switch phase {
            case .receiving: self = .receiving
            case .uploadingNotes, .uploadingCatalog: self = .uploading
            default: self = .checking
            }
        } else if hasError {
            self = .failed
        } else if hasPendingChanges {
            self = .waiting
        } else {
            self = .idle
        }
    }

    var symbol: String {
        switch self {
        case .idle: "icloud"
        case .waiting, .uploading: "icloud.and.arrow.up"
        case .checking: "arrow.triangle.2.circlepath.icloud"
        case .receiving: "icloud.and.arrow.down"
        case .paused: "icloud.slash"
        case .failed: "exclamationmark.icloud"
        }
    }
}
