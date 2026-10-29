import Foundation
import NoteCore

/// Snippets and templates: the editor's snippet menu, editing a snippet
/// from it, and creating notes from templates.
extension NotebookSceneState {
    func setSnippetSource(_ id: UUID, enabled: Bool) {
        perform { [self] in
            try await replica.setSnippetSource(id, enabled: enabled)
        }
    }

    func updateSnippetMenu() {
        snippetSourceNoteIDs = Set(replica.snippets.map(\.id))
        editorNavigation.snippetMenu.update(replica.snippets, sources: replica.snippetSources)
        if variableCompletion != nil && !canCompleteSnippetVariable { dismissEditorCompletion() }
        editorNavigation.snippetMenu.isEnabled = !busy && historyBrowser == nil
            && session?.isEditingEnabled == true
    }

    func configureSnippetNavigation() {
        let navigation = editorNavigation
        updateSnippetMenu()
        navigation.editSnippet = { [weak self, weak navigation] id in
            guard let self, let navigation, navigation === editorNavigation else { return }
            editSnippet(id)
        }
        navigation.insertSnippet = { [weak self, weak navigation] id in
            guard let self, let navigation, navigation === editorNavigation,
                  !busy, historyBrowser == nil, let targetID = selectedID,
                  session?.isEditingEnabled == true else { return }
            guard let insert = navigation.prepareSnippetInsertion?() else {
                errorMessage = String(localized:
                    "Place the cursor in the note before inserting a snippet. For a table cell, switch to Markdown Source.")
                return
            }
            let title = selectedPlacement.map {
                NotebookNoteName.title(from: $0.displayName)
            } ?? ""
            let date = Date()
            Task { @MainActor in
                do {
                    let source = try await replica.snippetText(id)
                    guard selectedID == targetID, navigation === editorNavigation,
                          !busy, historyBrowser == nil,
                          session?.isEditingEnabled == true else { return }
                    let text = NotebookSnippetText.expand(
                        text: source, title: title, date: date
                    )
                    guard insert(text) else {
                        errorMessage = String(localized:
                            "The note or cursor changed while the snippet was loading. Choose the snippet again.")
                        return
                    }
                } catch {
                    guard selectedID == targetID, navigation === editorNavigation else { return }
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func editSnippet(_ id: UUID) {
        guard !busy, historyBrowser == nil, let noteID = selectedID else { return }
        guard noteID != id else {
            editorNavigation.focusEditor?()
            return
        }
        perform { [self] in
            try await visitLinkedNote(id, fragment: nil)
            navigationState.beginSnippetEdit(id, from: noteID)
        }
    }

    /// Offered while editing a snippet opened from a note, until leaving it.
    var visibleSnippetReturn: NotebookSnippetReturn? {
        guard let snippetReturn = navigationState.snippetReturn,
              historyBrowser == nil, session?.isEditingEnabled == true,
              linkHistory.backTarget?.noteID == snippetReturn.noteID,
              replica.snippets.contains(where: { $0.id == snippetReturn.snippetID })
        else { return nil }
        return snippetReturn
    }

    func snippetReturnTitle(_ snippetReturn: NotebookSnippetReturn) -> String {
        replica.placements.first { $0.item.id == snippetReturn.noteID }
            .map { NotebookNoteName.title(from: $0.displayName) } ?? ""
    }

    func returnAndInsertSnippet(_ snippetReturn: NotebookSnippetReturn) {
        guard !busy, linkHistory.backTarget?.noteID == snippetReturn.noteID else { return }
        let navigationState = navigationState
        let onReturn: @MainActor () -> Void = { [self] in
            navigationState.pendingSnippetInsertion = snippetReturn
            insertPendingSnippet()
        }
        navigateLinkHistory(back: true, onReturn: onReturn)
    }

    /// Inserting needs the returned note's editor and an idle notebook, which
    /// may arrive in either order.
    func insertPendingSnippet() {
        guard let pending = navigationState.pendingSnippetInsertion, !busy else { return }
        navigationState.pendingSnippetInsertion = nil
        guard selectedID == pending.noteID else { return }
        editorNavigation.focusEditor?()
        editorNavigation.insertSnippet?(pending.snippetID)
    }

    // MARK: Templates

    func showTemplates() {
        perform { [self] in
            try await flushEditor()
            showingTemplates = true
        }
    }

    func setTemplateSource(_ id: UUID, enabled: Bool) {
        perform { [self] in
            try await flushEditor()
            try await replica.setTemplateSource(id, enabled: enabled)
        }
    }

    func createTemplateNote(_ sourceID: UUID) async throws {
        guard !busy else { throw NotebookReplicaError.busy }
        busy = true
        defer { busy = false }
        try await flushEditor()
        let id = try await replica.createNoteFromTemplate(sourceID)
        if showingTemplates {
            pendingPresentedItemID = id
        } else {
            // A completed write must still open its note if presentation
            // ended while storage was saving; never leave a stale route.
            reveal(id)
            try await selectNote(id)
        }
    }

    func openReusableSource(_ id: UUID) {
        pendingPresentedItemID = id
        showingSettings = false
        showingTemplates = false
    }
}
