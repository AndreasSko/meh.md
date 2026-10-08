import XCTest

extension XCUIApplication {
    var notebookNewItemButton: XCUIElement {
#if os(macOS)
        // macOS exposes the split-button container under this identifier.
        descendants(matching: .any)
            .matching(identifier: "notebook-new-item").firstMatch.buttons.firstMatch
#else
        buttons["notebook-new-item"].firstMatch
#endif
    }

#if os(macOS)
    var notebookVisibleMacSidebar: XCUIElement {
        let expanded = outlines.matching(identifier: "notebook-all-recents").firstMatch
        if expanded.exists && expanded.isHittable { return expanded }
        // The empty library outline need not itself offer a hit target.
        // Its distinct scope still excludes the retained expanded-list rows.
        let library = outlines.matching(NSPredicate(
            format: "identifier != %@", "notebook-all-recents"
        )).allElementsBoundByIndex
        XCTAssertEqual(library.count, 1,
                       "Expected exactly one native notebook library outline")
        // Fail closed instead of targeting a duplicate from a different list.
        return library.first
            ?? outlines.matching(identifier: "notebook-missing-visible-sidebar").firstMatch
    }
#endif

    var notebookTitleField: XCUIElement {
#if os(macOS)
        descendants(matching: .any).matching(identifier: "title-field").firstMatch
#else
        textFields["title-field"]
#endif
    }

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
        let newNote = notebookNewItemButton
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
        // The native Mac toolbar places the cloud navigation item after the
        // sidebar's Add split control, rather than using the iOS ordering.
        XCTAssertGreaterThan(details.frame.minX, newNote.frame.maxX)
#endif
        let recents = buttons["notebook-recents-toggle"]
        if files.exists, recents.exists {
#if os(iOS)
            // Native hit rectangles differ; compare the visible header edges.
            let filesLabel = files.staticTexts["Files"]
            let recentsLabel = recents.staticTexts["Recents"]
            let filesChevron = files.images.firstMatch
            let recentsChevron = recents.images.firstMatch
            XCTAssertTrue(filesLabel.exists && recentsLabel.exists)
            XCTAssertTrue(filesChevron.exists && recentsChevron.exists)
            XCTAssertEqual(filesLabel.frame.minX, recentsLabel.frame.minX, accuracy: 4)
            XCTAssertEqual(filesChevron.frame.maxX, recentsChevron.frame.maxX, accuracy: 4)
#else
            XCTAssertEqual(files.frame.minX, recents.frame.minX, accuracy: 4)
            XCTAssertEqual(files.frame.maxX, recents.frame.maxX, accuracy: 4)
#endif
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

#if os(macOS)
        let sidebarButtons = notebookVisibleMacSidebar.descendants(matching: .any)
#else
        let sidebarButtons = buttons
#endif
        let currentRecent = sidebarButtons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@", "notebook-recent-"
            )
        ).firstMatch
        #if os(macOS)
        let original = currentRecent.exists ? currentRecent
            : notebookMacFileRow(named: title)
        #else
        let currentSidebarNote = sidebarButtons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label == %@",
                "notebook-sidebar-note-", title
            )
        ).firstMatch
        let original = currentRecent.exists ? currentRecent : currentSidebarNote
        #endif
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
        let other = sidebarButtons.matching(
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
            let newNote = notebookNewItemButton
            XCTAssertTrue(newNote.waitForExistence(timeout: timeout))
            activate(newNote)
            let titleField = notebookTitleField
            XCTAssertTrue(titleField.waitForExistence(timeout: timeout))
#if os(macOS)
            titleField.click()
            titleField.typeKey(.return, modifierFlags: [])
#else
            titleField.tap()
            titleField.typeText("\n")
#endif
        }

#if os(iOS)
        revealNotebookSidebar(timeout: timeout)
#endif
#if os(macOS)
        let persistedNote = notebookVisibleMacSidebar.descendants(matching: .any)
            .matching(identifier: originalIdentifier).firstMatch
#else
        let persistedNote = buttons[originalIdentifier]
#endif
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

        let sidebar = notebookNewItemButton
        XCTAssertTrue(
            sidebar.waitForExistence(timeout: timeout),
            "Expected the notebook sidebar to finish loading"
        )

#if os(macOS)
        let sidebarButtons = notebookVisibleMacSidebar.buttons
#else
        let sidebarButtons = buttons
#endif
        let notebookNote = sidebarButtons.matching(
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
#if os(macOS)
        let sidebarElements = notebookVisibleMacSidebar.descendants(matching: .any)
#else
        let sidebarElements = descendants(matching: .any)
#endif
        let notes = sidebarElements.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "notebook-sidebar-note-"
            )
        )
        _ = notes.firstMatch.waitForExistence(timeout: 10)
        let identifiers = notes.allElementsBoundByIndex.map(\.identifier)
        for identifier in identifiers {
            revealNotebookSidebar(timeout: 15)
#if os(macOS)
            let note = notebookVisibleMacSidebar.descendants(matching: .any)
                .matching(identifier: identifier).firstMatch
#else
            let note = descendants(matching: .any)
                .matching(identifier: identifier).firstMatch
#endif
            guard note.waitForExistence(timeout: 5) else { continue }
#if os(iOS)
            // Native collection rows expose a focus-only Other container.
            // Activate their visible title, the actual navigation target.
            let titleIdentifier = identifier.replacingOccurrences(
                of: "notebook-sidebar-note-", with: "notebook-sidebar-title-"
            )
            let title = staticTexts[titleIdentifier]
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            let hittable = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "hittable == true"), object: title
            )
            XCTAssertEqual(XCTWaiter.wait(for: [hittable], timeout: 5), .completed)
            activate(title)
#else
            activate(note)
#endif
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

    func revealNotebookSidebar(timeout: TimeInterval) {
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

#if os(macOS)
extension XCUIApplication {
    func notebookMacFileRow(
        named name: String,
        identifierPrefix: String = "notebook-sidebar-note-",
        timeout: TimeInterval = 5
    ) -> XCUIElement {
        let sidebar = notebookVisibleMacSidebar
        // AppKit exposes a SwiftUI Text's exact string as AXValue. Scope to
        // the visible outline so retained Recents cannot satisfy Files queries.
        let title = sidebar.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND (label == %@ OR value == %@)",
            "notebook-sidebar-title-", name, name
        )).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: timeout))
        let id = title.identifier.replacingOccurrences(
            of: "notebook-sidebar-title-", with: ""
        )
        // Native sidebar rows are Groups on Mac, with their Text as a child.
        return sidebar.descendants(matching: .any)
            .matching(identifier: identifierPrefix + id).firstMatch
    }
}
#endif

// xctestrun treats values containing slashes as paths. Carry only the port
// through the test-host environment and construct the loopback URL in XCTest.
extension ProcessInfo {
    var ciLoopbackURL: String? {
        guard let value = environment["MEH_CI_SYNC_PORT"],
              let port = Int(value), (1...65_535).contains(port) else {
            return nil
        }
        return "http://127.0.0.1:\(port)"
    }
}
