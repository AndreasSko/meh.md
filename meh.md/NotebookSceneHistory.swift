import Foundation
import NoteCore

/// Opening a note's Version History and restoring from it.
extension NotebookSceneState {
    func openHistory() {
        guard historyBrowser == nil, !isLoadingHistory, !busy,
              let session, let selectedID else { return }
        isLoadingHistory = true
        busy = true
        let loadID = UUID()
        historyLoadID = loadID
        historyLoadTask = Task { @MainActor in
            var isOpening = true
            defer {
                if historyLoadID == loadID {
                    isLoadingHistory = false
                    if isOpening { busy = false }
                    historyLoadTask = nil
                }
            }
            do {
                try await flushEditor()
                try Task.checkCancellation()
                guard self.selectedID == selectedID,
                      self.session === session,
                      let heads = session.currentSnapshot?.heads else { return }
                let reader = try session.makeHistoryReader()
                let browser = NoteHistoryBrowserState(
                    noteID: selectedID,
                    versions: [],
                    expectedHeads: heads,
                    originalPosition: editorNavigation.capturePosition?(),
                    text: session.text,
                    reader: reader
                )
                historyBrowser = browser
                browser.loadDetails(near: nil)
                editorNavigation.invalidate()
                // History can be closed while its frozen index is building.
                // Subsequent live edits are checked again before restoration.
                isOpening = false
                busy = false
                for try await update in await reader.updates() {
                    try Task.checkCancellation()
                    guard historyBrowser === browser else { return }
                    browser.apply(update)
                }
            } catch is CancellationError {
                if historyLoadID == loadID {
                    editorNavigation.resumeEditing?()
                }
            } catch {
                if historyLoadID == loadID {
                    closeHistory()
                    editorNavigation.resumeEditing?()
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    func cancelHistoryLoading() {
        let ownsBusy = isLoadingHistory && historyBrowser == nil
        historyLoadID = UUID()
        historyLoadTask?.cancel()
        historyLoadTask = nil
        isLoadingHistory = false
        if ownsBusy {
            busy = false
            editorNavigation.resumeEditing?()
        }
    }

    func closeHistory() {
        cancelHistoryLoading()
        guard let historyBrowser else { return }
        historyBrowser.cancel()
        historyBrowser.navigation.invalidate()
        self.historyBrowser = nil
        editorNavigation = MarkdownEditorNavigation()
    }

    func restoreHistoryInPlace() {
        guard let historyBrowser,
              !historyBrowser.isLoadingPreview,
              let version = historyBrowser.selectedVersion,
              let session else { return }
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            do {
                try await session.restoreHistoryVersion(
                    version, expectedHeads: historyBrowser.expectedHeads
                )
                if self.historyBrowser === historyBrowser { closeHistory() }
                workspace?.contentDidSave(trigger: "note restored")
                workspace?.noteDidEdit()
            } catch NoteHistoryError.currentChanged {
                if self.historyBrowser === historyBrowser {
                    closeHistory()
                    busy = false
                    openHistory()
                    errorMessage = String(localized:
                        "This note changed while History was open. Review the current version before restoring.")
                    return
                }
            } catch {
                if case .saveFailed = session.status,
                   self.historyBrowser === historyBrowser {
                    // The live text changed, but persistence failed. Show
                    // that text and the editor's Retry action.
                    closeHistory()
                }
                errorMessage = error.localizedDescription
            }
            busy = false
        }
    }

    func restoreHistoryAsNewNote() {
        guard let historyBrowser,
              !historyBrowser.isLoadingPreview,
              let version = historyBrowser.selectedVersion,
              let placement = selectedPlacement else { return }
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            do {
                let text = try await historyBrowser.reader.historicalText(for: version)
                let title = NotebookNoteName.title(from: placement.displayName)
                let siblings = replica.placements.compactMap { item in
                    item.parentID == placement.parentID && !item.isInTrash
                        ? item.item.name : nil
                }
                let name = NotebookNoteName.restoredFilename(
                    for: title, existingNames: siblings
                )
                let id = try await replica.createNote(
                    name: name, text: text, parentID: placement.parentID
                )
                if self.historyBrowser === historyBrowser { closeHistory() }
                try await selectNote(id)
            } catch {
                errorMessage = error.localizedDescription
            }
            busy = false
        }
    }
}
