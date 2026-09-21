import XCTest

extension XCUIApplication {
    func openSyncDetails(timeout: TimeInterval = 15) {
#if os(iOS)
        revealNotebookSidebar(timeout: timeout)
#endif
        let details = buttons["notebook-sync-details"]
        XCTAssertTrue(
            details.waitForExistence(timeout: timeout),
            "Expected the notebook sync details button"
        )
        let settings = buttons["notebook-settings"]
        let files = buttons["notebook-tree-toggle"]
        let trash = buttons["notebook-trash-toggle"]
        let newNote = buttons["notebook-new-item"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: timeout))
        XCTAssertTrue(trash.waitForExistence(timeout: timeout))
        XCTAssertTrue(newNote.waitForExistence(timeout: timeout))
        XCTAssertGreaterThan(settings.frame.minY, files.frame.maxY)
        XCTAssertEqual(settings.frame.midY, trash.frame.midY, accuracy: 4)
        XCTAssertLessThan(settings.frame.midX, trash.frame.midX)
        XCTAssertEqual(details.frame.midY, newNote.frame.midY, accuracy: 4)
        XCTAssertLessThan(details.frame.midX, newNote.frame.midX)
        let disclosure = buttons["notebook-tree-disclosure"]
        let recents = buttons["notebook-recents-toggle"]
        if disclosure.exists, recents.exists {
            XCTAssertEqual(disclosure.frame.maxX, recents.frame.maxX, accuracy: 4)
        }
        activate(details)
        XCTAssertTrue(
            buttons["sync-now"].waitForExistence(timeout: timeout),
            "Expected sync details to contain the Sync Now button"
        )
    }

    func closeSyncDetails(timeout: TimeInterval = 5) {
        let syncNow = buttons["sync-now"]
        guard syncNow.exists else { return }
        let close = buttons["notebook-sync-details-close"]
        XCTAssertTrue(
            close.waitForExistence(timeout: timeout),
            "Expected notebook sync details to contain a Close button"
        )
        activate(close)
        let closed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: syncNow
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [closed], timeout: timeout),
            .completed,
            "Expected notebook sync details to close"
        )
#if os(iOS)
        restoreNotebookEditorFromSidebar(timeout: timeout)
#endif
    }

    func openTrash(timeout: TimeInterval = 15) {
#if os(iOS)
        revealNotebookSidebar(timeout: timeout)
#endif
        let trash = buttons["notebook-trash-toggle"]
        XCTAssertTrue(
            trash.waitForExistence(timeout: timeout),
            "Expected the Trash button in the notebook sidebar"
        )
        XCTAssertFalse(
            ["Expanded", "Collapsed"].contains(trash.value as? String ?? ""),
            "Trash opens a separate view instead of expanding inline"
        )
        activate(trash)
        let trashView = descendants(matching: .any)
            .matching(identifier: "notebook-trash-view").firstMatch
        XCTAssertTrue(
            trashView.waitForExistence(timeout: timeout),
            "Expected the dedicated Trash view"
        )
    }

    func closeTrash(timeout: TimeInterval = 5) {
        let close = buttons["notebook-trash-close"]
        if close.exists {
            activate(close)
        } else {
#if os(iOS)
            let back = navigationBars["Trash"].buttons.firstMatch
            XCTAssertTrue(
                back.waitForExistence(timeout: timeout),
                "Expected native Back navigation from Trash"
            )
            back.tap()
#else
            XCTFail("Expected the Trash sheet to provide Done")
#endif
        }
        XCTAssertTrue(
            buttons["notebook-trash-toggle"].waitForExistence(timeout: timeout),
            "Expected to return to the notebook browser"
        )
        XCTAssertFalse(
            descendants(matching: .any)
                .matching(identifier: "notebook-trash-view").firstMatch.exists
        )
    }

    @discardableResult
    func flushCurrentEditorBySwitchingNotes(
        timeout: TimeInterval = 15
    ) -> XCUIElement {
        let editor = textViews["markdown-editor"]
        XCTAssertTrue(
            editor.waitForExistence(timeout: timeout),
            "Expected an editor before flushing through note navigation"
        )
        let title = buttons["note-title"].label
        revealNotebookSidebar(timeout: timeout)

        let currentRecent = buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@", "notebook-recent-"
            )
        ).firstMatch
        let currentSidebarNote = buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label == %@",
                "notebook-sidebar-note-", title
            )
        ).firstMatch
        let original = currentRecent.exists ? currentRecent : currentSidebarNote
        XCTAssertTrue(
            original.waitForExistence(timeout: timeout),
            "Expected the current note in the sidebar or Recents"
        )
        let originalIdentifier = original.identifier
        let alternateOriginalIdentifier: String
        if originalIdentifier.hasPrefix("notebook-recent-") {
            alternateOriginalIdentifier = originalIdentifier.replacingOccurrences(
                of: "notebook-recent-", with: "notebook-sidebar-note-"
            )
        } else {
            alternateOriginalIdentifier = originalIdentifier.replacingOccurrences(
                of: "notebook-sidebar-note-", with: "notebook-recent-"
            )
        }
        let other = buttons.matching(
            NSPredicate(
                format: "(identifier BEGINSWITH %@ OR identifier BEGINSWITH %@)"
                    + " AND identifier != %@ AND identifier != %@",
                "notebook-sidebar-note-", "notebook-recent-",
                originalIdentifier, alternateOriginalIdentifier
            )
        ).firstMatch
        if other.exists {
            activate(other)
        } else {
            let newNote = buttons["notebook-new-item"].firstMatch
            XCTAssertTrue(newNote.waitForExistence(timeout: timeout))
            activate(newNote)
            let titleField = textFields["title-field"]
            XCTAssertTrue(titleField.waitForExistence(timeout: timeout))
#if os(macOS)
            titleField.typeKey(.return, modifierFlags: [])
#else
            titleField.typeText("\n")
#endif
        }

#if os(iOS)
        revealNotebookSidebar(timeout: timeout)
#endif
        let persistedNote = buttons[originalIdentifier]
        XCTAssertTrue(
            persistedNote.waitForExistence(timeout: timeout),
            "Expected the original note after crossing a save boundary"
        )
        activate(persistedNote)
        XCTAssertTrue(
            editor.waitForExistence(timeout: timeout),
            "Expected the original note to reopen after flushing"
        )
        return editor
    }

    func openOrCreateNotebookEditor(timeout: TimeInterval = 30) throws -> XCUIElement {
        let editor = textViews["markdown-editor"]
        if editor.waitForExistence(timeout: 1) { return editor }

        let sidebar = buttons["notebook-new-item"]
        XCTAssertTrue(
            sidebar.waitForExistence(timeout: timeout),
            "Expected the notebook sidebar to finish loading"
        )

        let notebookNote = buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "notebook-sidebar-note-"
            )
        ).firstMatch
        // The toolbar can appear before asynchronous placements finish loading.
        _ = notebookNote.waitForExistence(timeout: timeout)
        if notebookNote.exists {
            activate(notebookNote)
        } else {
            activate(sidebar)
        }

        XCTAssertTrue(
            editor.waitForExistence(timeout: timeout),
            "Expected a selected notebook note to open its editor"
        )
        return editor
    }

    private func revealNotebookSidebar(timeout: TimeInterval) {
#if os(iOS)
        let cloud = buttons["notebook-sync-details"]
        let files = buttons["notebook-files-menu"]
        guard !cloud.isHittable && !files.isHittable else { return }
        let back = navigationBars.buttons.firstMatch
        XCTAssertTrue(
            back.waitForExistence(timeout: timeout),
            "Expected a navigation control that reveals the sidebar"
        )
        back.tap()
        XCTAssertTrue(
            buttons["notebook-new-item"].firstMatch.waitForExistence(
                timeout: timeout
            ),
            "Expected the notebook sidebar to become visible"
        )
#endif
    }

    private func restoreNotebookEditorFromSidebar(timeout: TimeInterval) {
#if os(iOS)
        guard !textViews["markdown-editor"].exists else { return }
        let recent = buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@", "notebook-recent-"
            )
        ).firstMatch
        let note = buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@", "notebook-sidebar-note-"
            )
        ).firstMatch
        let destination = recent.exists ? recent : note
        XCTAssertTrue(
            destination.waitForExistence(timeout: timeout),
            "Expected a note to restore the compact editor"
        )
        destination.tap()
        XCTAssertTrue(
            textViews["markdown-editor"].waitForExistence(timeout: timeout),
            "Expected the editor after closing sync details"
        )
#endif
    }

    private func activate(_ element: XCUIElement) {
#if os(macOS)
        element.click()
#else
        element.tap()
#endif
    }
}
