import Foundation
import NoteCore

/// Stable toolbar states keep idle and waiting distinct from active work.
nonisolated enum NotebookSyncIndicator: Equatable {
    case synced, syncing, waiting, failed, disabled

    init(
        isEnabled: Bool,
        isSyncing: Bool,
        isRetryPaused: Bool,
        hasError: Bool,
        hasPendingChanges: Bool,
        isWaitingForLocalSave: Bool = false
    ) {
        if !isEnabled {
            self = .disabled
        } else if isWaitingForLocalSave && !hasError {
            self = isSyncing && !isRetryPaused ? .syncing : .waiting
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
        case .synced, .waiting: "icloud"
        case .syncing: "arrow.triangle.2.circlepath.icloud"
        case .disabled: "icloud.slash"
        case .failed: "exclamationmark.icloud"
        }
    }
}

/// Only an active pass may expose progress or filenames. A retained failure
/// snapshot is useful for diagnostics, but must not appear to be live work.
nonisolated struct NotebookSyncActivityPresentation {
    let progress: NotebookSyncProgress?

    init(isActive: Bool, progress: NotebookSyncProgress?) {
        self.progress = isActive ? progress : nil
    }

    var fraction: Double? {
        if let fraction = progress?.overallFraction {
            return fraction.isFinite ? min(1, max(0, fraction)) : nil
        }
        guard let progress, progress.phase == .uploadingNotes,
              progress.totalNotes > 0 else { return nil }
        return min(1, max(0, Double(progress.completedNotes)
                          / Double(progress.totalNotes)))
    }

    var activeNoteIDs: [UUID] { progress?.activeNoteIDs ?? [] }

    var title: LocalizedStringResource {
        guard let progress else { return "Checking for changes…" }
        if progress.waitingSince != nil { return "Waiting for iCloud…" }
        switch progress.phase {
        case .verifyingSavedState: return "Verifying saved sync data…"
        case .checking: return "Checking for changes…"
        case .checkingRemoteHistory: return "Checking iCloud history…"
        case .receiving:
            return progress.activeNoteIDs.isEmpty
                ? "Receiving changes…" : "Updating this device…"
        case .uploadingNotes:
            let count = progress.activeNoteIDs.count
            return count > 1 ? "Sending \(count) notes…" : "Sending changes…"
        case .uploadingCatalog: return "Updating your notebook…"
        case .cleaningUp, .cleaningUpSnapshots: return "Cleaning up…"
        case .comparing: return "Checking local changes…"
        case .finalizing: return "Finishing sync…"
        }
    }

    var hint: LocalizedStringResource? {
        guard let progress else { return nil }
        switch progress.phase {
        case .uploadingCatalog: return "Folder names, note details and order"
        case .cleaningUp:
            let count = progress.cleanupItemCount
            if count == 1 { return "Removing copies of 1 deleted note" }
            return count > 0 ? "Removing copies of \(count) deleted notes"
                : "Removing copies of deleted notes"
        case .cleaningUpSnapshots: return "Removing extra sync copies from iCloud"
        case .verifyingSavedState:
            return "Usually once after an app update, before sync starts"
        case .checking, .checkingRemoteHistory, .receiving, .uploadingNotes,
             .comparing, .finalizing: return nil
        }
    }

    func detail(at now: Date) -> LocalizedStringResource? {
        guard let progress else { return nil }
        if let started = progress.waitingSince {
            let seconds = max(0, Int(now.timeIntervalSince(started)))
            return "Waiting for \(seconds) seconds"
        }
        guard let completed = progress.completedUnits,
              let total = progress.totalUnits, total > 0 else { return nil }
        switch progress.phase {
        case .verifyingSavedState:
            return "\(completed) of \(total) saved items verified"
        case .checking, .comparing, .finalizing:
            return "\(completed) of \(total) documents checked"
        case .receiving: return "\(completed) of \(total) changes in this batch"
        case .uploadingNotes:
            return "\(progress.completedNotes) of \(progress.totalNotes) notes sent"
        case .cleaningUp, .cleaningUpSnapshots:
            return "\(completed) of \(total) items processed"
        case .uploadingCatalog, .checkingRemoteHistory: return nil
        }
    }
}

nonisolated struct NotebookSyncActiveFile: Identifiable, Equatable {
    let id: UUID
    let name: String?
    let folder: String?

    static func resolve(
        ids: [UUID], placements: [NotebookPlacement]
    ) -> [Self] {
        let byID = Dictionary(uniqueKeysWithValues: placements.map { ($0.item.id, $0) })
        let names = ids.compactMap { byID[$0]?.displayName }
        var seen: Set<UUID> = []
        return ids.filter { seen.insert($0).inserted }.map { id in
            guard let placement = byID[id] else {
                return Self(id: id, name: nil, folder: nil)
            }
            var folder: String?
            if names.filter({ $0 == placement.displayName }).count > 1 {
                var ancestors: [String] = []
                var parent = placement.parentID
                var visited: Set<UUID> = [id]
                while let current = parent, visited.insert(current).inserted,
                      let entry = byID[current] {
                    ancestors.append(entry.displayName)
                    parent = entry.parentID
                }
                folder = ancestors.reversed().joined(separator: " / ")
            }
            return Self(id: id, name: placement.displayName, folder: folder)
        }
    }
}
