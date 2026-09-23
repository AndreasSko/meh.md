/// Four stable toolbar states; detailed progress stays in the sync popover.
nonisolated enum NotebookSyncIndicator: Equatable {
    case synced, syncing, failed, disabled

    init(
        isEnabled: Bool,
        isSyncing: Bool,
        isRetryPaused: Bool,
        hasError: Bool,
        hasPendingChanges: Bool
    ) {
        if !isEnabled {
            self = .disabled
        } else if isRetryPaused {
            self = .failed
        } else if isSyncing {
            self = .syncing
        } else if hasError {
            self = .failed
        } else if hasPendingChanges {
            self = .syncing
        } else {
            self = .synced
        }
    }

    var symbol: String {
        switch self {
        case .synced: "icloud"
        case .syncing: "arrow.triangle.2.circlepath.icloud"
        case .disabled: "icloud.slash"
        case .failed: "exclamationmark.icloud"
        }
    }
}
