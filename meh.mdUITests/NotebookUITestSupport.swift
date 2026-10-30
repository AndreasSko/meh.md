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
        let files = buttons["notebook-tree-toggle"]
        let newNote = buttons["notebook-new-item"].firstMatch
        XCTAssertTrue(newNote.waitForExistence(timeout: timeout))
#if os(iOS)
        XCTAssertTrue(
            buttons["notebook-app-menu"].waitForExistence(timeout: 1)
                || (buttons["notebook-settings"].waitForExistence(timeout: timeout)
                    && buttons["notebook-trash-toggle"].exists),
            "Expected compact app actions or wide settings controls"
        )
#else
        let settings = buttons["notebook-settings"]
        let trash = buttons["notebook-trash-toggle"]
        XCTAssertTrue(settings.waitForExistence(timeout: timeout))
        XCTAssertTrue(trash.waitForExistence(timeout: timeout))
        XCTAssertGreaterThan(settings.frame.minY, files.frame.maxY)
        XCTAssertEqual(settings.frame.midY, trash.frame.midY, accuracy: 4)
        XCTAssertLessThan(settings.frame.midX, trash.frame.midX)
#endif
#if os(macOS)
        XCTAssertEqual(details.frame.midY, newNote.frame.midY, accuracy: 4)
        XCTAssertLessThan(details.frame.midX, newNote.frame.midX)
#endif
        let recents = buttons["notebook-recents-toggle"]
        if files.exists, recents.exists, textViews["markdown-editor"].exists {
            XCTAssertEqual(files.frame.minX, recents.frame.minX, accuracy: 4)
            XCTAssertEqual(files.frame.maxX, recents.frame.maxX, accuracy: 4)
        }
        activate(details)
        XCTAssertTrue(
            descendants(matching: .any)
                .matching(identifier: "note-sync-status")
                .firstMatch.waitForExistence(timeout: timeout),
            "Expected the sync status view to open"
        )
    }

    func closeSyncDetails(timeout: TimeInterval = 5) {
        let status = descendants(matching: .any)
            .matching(identifier: "note-sync-status").firstMatch
        guard status.exists else { return }
#if os(iOS)
        coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap()
#else
        typeKey(.escape, modifierFlags: [])
#endif
        let closed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: status
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

    func openNotebookSettings(timeout: TimeInterval = 15) {
#if os(iOS)
        revealNotebookSidebar(timeout: timeout)
#endif
        guard let settings = notebookMenuAction(
            identifier: "notebook-settings", timeout: timeout
        ) else { return }
        activate(settings)
#if os(iOS)
        let title = navigationBars["Settings"]
#else
        // A Mac sheet has no navigation bar; its title is plain text.
        let title = sheets.staticTexts.matching(
            NSPredicate(format: "value == %@", "Settings")
        ).firstMatch
#endif
        XCTAssertTrue(
            title.waitForExistence(timeout: timeout),
            "Expected notebook Settings to open"
        )
    }

    func openTrash(timeout: TimeInterval = 15) {
#if os(iOS)
        // An empty library has no sidebar to reveal; its menu opens Trash.
        if !buttons["notebook-start-writing"].exists {
            revealNotebookSidebar(timeout: timeout)
        }
#endif
        guard let trash = notebookMenuAction(
            identifier: "notebook-trash-toggle", timeout: timeout
        ) else { return }
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
#if os(iOS)
        XCTAssertTrue(
            buttons["notebook-app-menu"].waitForExistence(timeout: 1)
                || buttons["notebook-trash-toggle"].waitForExistence(
                    timeout: timeout
                ),
            "Expected to return to the notebook browser"
        )
#else
        XCTAssertTrue(
            buttons["notebook-trash-toggle"].waitForExistence(timeout: timeout),
            "Expected to return to the notebook browser"
        )
#endif
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
            titleField.tap()
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

    func openNotebookNote(withText expected: String) -> XCUIElement? {
        revealNotebookSidebar(timeout: 15)
        let files = buttons["notebook-tree-toggle"]
        if files.value as? String == "Collapsed" { activate(files) }
        // Native sidebar rows can be exposed as Other on iPad.
        let notes = descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "notebook-sidebar-note-"
            )
        )
        _ = notes.firstMatch.waitForExistence(timeout: 10)
        let identifiers = notes.allElementsBoundByIndex.map(\.identifier)
        for identifier in identifiers {
            revealNotebookSidebar(timeout: 15)
            let note = descendants(matching: .any)
                .matching(identifier: identifier).firstMatch
            guard note.waitForExistence(timeout: 5) else { continue }
            activate(note)
            let editor = textViews["markdown-editor"]
            guard editor.waitForExistence(timeout: 5) else { continue }
            let match = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", expected),
                object: editor
            )
            if XCTWaiter.wait(for: [match], timeout: 2) == .completed {
                return editor
            }
        }
        return nil
    }

    /// History's timeline has no step buttons. A tap left of its handle
    /// selects the nearest older version, a tap at its right end the newest.
    func tapHistoryTimeline(older: Bool) {
        let timeline = descendants(matching: .any)
            .matching(identifier: "note-history-timeline").firstMatch
        XCTAssertTrue(timeline.waitForExistence(timeout: 10))
        let point = timeline.coordinate(
            withNormalizedOffset: CGVector(dx: older ? 0.35 : 0.95, dy: 0.3)
        )
#if os(macOS)
        point.click()
#else
        point.tap()
#endif
    }

    func waitForHistoryIndex(timeout: TimeInterval) {
        let loading = descendants(matching: .any)
            .matching(identifier: "note-history-index-loading").firstMatch
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: loading
        )
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: timeout), .completed)
    }

    func revealNotebookSidebar(timeout: TimeInterval = 15) {
#if os(iOS)
        let files = buttons["notebook-tree-toggle"]
        guard !files.isHittable else { return }
        let back = navigationBars.buttons.firstMatch
        XCTAssertTrue(
            back.waitForExistence(timeout: timeout),
            "Expected a navigation control that reveals the sidebar"
        )
        back.tap()
        XCTAssertTrue(
            files.waitForExistence(timeout: timeout),
            "Expected the notebook sidebar to become visible"
        )
        let visible = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"),
            object: files
        )
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: timeout), .completed)
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

    private func notebookMenuAction(
        identifier: String, timeout: TimeInterval
    ) -> XCUIElement? {
        func waitUntilHittable(_ element: XCUIElement) -> Bool {
            let ready = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == true AND hittable == true"),
                object: element
            )
            return XCTWaiter.wait(for: [ready], timeout: timeout) == .completed
        }

        let action = buttons[identifier]
        if waitUntilHittable(action) { return action }
#if os(iOS)
        let menu = buttons["notebook-app-menu"]
        guard waitUntilHittable(menu) else {
            XCTFail("Expected a hittable notebook app menu")
            return nil
        }
        menu.tap()
        guard waitUntilHittable(action) else {
            XCTFail("Expected a hittable \(identifier) in the notebook app menu")
            return nil
        }
        return action
#else
        XCTFail("Expected a hittable \(identifier)")
        return nil
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

extension XCUIApplication {
    /// Runs `body` without XCUITest's wait for the app to go idle.
    ///
    /// While a context menu is open on a draggable sidebar row, UIKit keeps
    /// a paused drag-lift animation attached until the menu closes. The app
    /// is idle, but XCUITest never hears "animations complete" and waits 60
    /// seconds before and after every event. Callers wait for the next
    /// element explicitly instead.
    ///
    /// XCUITest has no public switch for this, so this calls its private
    /// interaction options (skip pre- and post-event waits). If they go
    /// away, `body` runs normally and is only slow again.
    func withoutIdleWait(_ body: () -> Void) {
        typealias Perform = @convention(c) (
            AnyObject, Selector, UInt, @convention(block) () -> Void
        ) -> Void
        let selector = NSSelectorFromString("_performWithInteractionOptions:block:")
        guard responds(to: selector) else { return body() }
        let skipPreAndPostEventWaits: UInt = 0b11
        withoutActuallyEscaping(body) { body in
            unsafeBitCast(method(for: selector), to: Perform.self)(
                self, selector, skipPreAndPostEventWaits, body
            )
        }
    }

    /// Long-presses a sidebar row and taps one of its menu actions without
    /// XCTest's idle waits, which stall while the row menu is open.
    func chooseRowAction(
        _ label: String, on row: XCUIElement, at verticalOffset: CGFloat = 0.5,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        withoutIdleWait {
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: verticalOffset))
                .press(forDuration: 1)
            // The toolbar New Note button shares the "New Note" label.
            let action = buttons.matching(NSPredicate(
                format: "label == %@ AND identifier != %@",
                label, "notebook-new-item"
            )).firstMatch
            guard action.waitForExistence(timeout: 5) else {
                return XCTFail("Row action \(label) missing", file: file, line: line)
            }
            action.tap()
        }
    }
}
