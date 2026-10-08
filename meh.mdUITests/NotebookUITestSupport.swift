import XCTest

extension XCUIApplication {
    func assertNotebookEditor(
        title: String, source: String, timeout: TimeInterval = 5
    ) {
        let editor = textViews["markdown-editor"]
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                guard self.buttons["note-title"].label == title,
                      editor.exists, let actual = editor.value as? String else { return false }
                return actual.utf8.elementsEqual(source.utf8)
            }, object: self
        )
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: timeout), .completed,
                       "Expected displayed note \(title) with its exact literal source")
    }

#if os(iOS)
    func coordinate(atScreenPoint point: CGPoint) -> XCUICoordinate {
        coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: point.x - frame.minX, dy: point.y - frame.minY
        ))
    }
#endif

    private func finishNotebookNaming(timeout: TimeInterval) {
        let title = notebookTitleField
        guard title.exists else { return }
        activate(title)
#if os(macOS)
        title.typeKey(.return, modifierFlags: [])
#else
        title.typeText("\n")
#endif
        let committed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: title
        )
        XCTAssertEqual(XCTWaiter.wait(for: [committed], timeout: timeout), .completed,
                       "Expected native naming to finish before editor navigation")
    }

    private func notebookNoteID(displayedTitle title: String) -> String? {
#if os(macOS)
        let elements = notebookVisibleMacSidebar.descendants(matching: .any)
#else
        let elements = descendants(matching: .any)
#endif
        let current = elements.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND value CONTAINS %@",
            "notebook-recent-", "Current note"
        )).allElementsBoundByIndex
        if current.count == 1 {
            let candidate = current[0]
            // The caller captures the detail title before revealing the
            // browser: compact iPhone navigation hides that detail's AX tree.
            guard candidate.label == title || candidate.label.hasPrefix(title + ",")
                else { return nil }
            return String(candidate.identifier.dropFirst("notebook-recent-".count))
        }
        let titles = elements.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND (label == %@ OR value == %@)",
            "notebook-sidebar-title-", title, title
        )).allElementsBoundByIndex
        guard titles.count == 1 else { return nil }
        return String(titles[0].identifier.dropFirst("notebook-sidebar-title-".count))
    }

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
        let collapse = buttons["notebook-recents-collapse"]
        // The expanded native outline may not itself report a hit target.
        // Its enabled, visible footer identifies the active Recents surface.
        if expanded.exists && collapse.exists && collapse.isEnabled
            && collapse.isHittable {
            return expanded
        }
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
        finishNotebookNaming(timeout: timeout)
        let originalSource = editor.value as? String
        XCTAssertNotNil(originalSource, "Expected literal source before the save boundary")
        let originalTitle = buttons["note-title"].label
        revealNotebookSidebar(timeout: timeout)
        let files = buttons["notebook-tree-toggle"]
        if files.value as? String == "Collapsed" { activate(files) }
        guard let originalID = notebookNoteID(displayedTitle: originalTitle) else {
            XCTFail("Expected an unambiguous current note UUID")
            return editor
        }
#if os(macOS)
        let sidebarButtons = notebookVisibleMacSidebar.descendants(matching: .any)
#else
        let sidebarButtons = descendants(matching: .any)
#endif
        let recentIdentifier = "notebook-recent-" + originalID
        let fileIdentifier = "notebook-sidebar-note-" + originalID
        let currentRecent = sidebarButtons.matching(identifier: recentIdentifier).firstMatch
        let originalIdentifier = currentRecent.exists ? recentIdentifier : fileIdentifier
        let alternateOriginalIdentifier = currentRecent.exists ? fileIdentifier : recentIdentifier
        let other = sidebarButtons.matching(
            NSPredicate(
                format: "(identifier BEGINSWITH %@ OR identifier BEGINSWITH %@)"
                    + " AND identifier != %@ AND identifier != %@",
                "notebook-sidebar-note-", "notebook-recent-",
                originalIdentifier, alternateOriginalIdentifier
            )
        ).allElementsBoundByIndex.first { element in
            let id = element.identifier.replacingOccurrences(
                of: "notebook-sidebar-note-", with: ""
            ).replacingOccurrences(of: "notebook-recent-", with: "")
            return UUID(uuidString: id) != nil && element.isHittable
        }
        var alternateID: String?
        var alternateTitle: String?
        var createdAlternate = false
        if let other {
            let otherID = other.identifier.replacingOccurrences(
                of: "notebook-sidebar-note-", with: ""
            ).replacingOccurrences(of: "notebook-recent-", with: "")
            alternateID = otherID
            let otherTitle = sidebarButtons.matching(
                identifier: "notebook-sidebar-title-" + otherID
            ).firstMatch
            XCTAssertTrue(otherTitle.exists, "Expected the alternate note's visible Files title")
#if os(macOS)
            alternateTitle = otherTitle.value as? String ?? otherTitle.label
#else
            alternateTitle = otherTitle.label
#endif
#if os(iOS)
            if other.identifier.hasPrefix("notebook-sidebar-note-") {
                activate(staticTexts["notebook-sidebar-title-" + otherID])
            } else { activate(other) }
#else
            activate(other)
#endif
        } else {
            let newNote = notebookNewItemButton
            XCTAssertTrue(newNote.waitForExistence(timeout: timeout))
            activate(newNote)
            XCTAssertTrue(notebookTitleField.waitForExistence(timeout: timeout))
            finishNotebookNaming(timeout: timeout)
            alternateTitle = buttons["note-title"].label
            createdAlternate = true
        }
        let departed = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                let displayedTitle = self.buttons["note-title"].label
                return displayedTitle == alternateTitle && displayedTitle != originalTitle
                    && editor.exists
            }, object: self
        )
        XCTAssertEqual(XCTWaiter.wait(for: [departed], timeout: timeout), .completed,
                       "Expected to open a different note before reopening the original")
        XCTAssertTrue(editor.waitForExistence(timeout: timeout))
        if createdAlternate {
            XCTAssertEqual(editor.value as? String, "",
                           "Expected the new alternate note's empty source")
        }

#if os(iOS)
        revealNotebookSidebar(timeout: timeout)
#endif
        guard let alternateTitle,
              let observedAlternateID = notebookNoteID(displayedTitle: alternateTitle) else {
            XCTFail("Expected the displayed alternate note's unique visible UUID")
            return editor
        }
        XCTAssertNotEqual(observedAlternateID, originalID)
        if let alternateID { XCTAssertEqual(observedAlternateID, alternateID) }
#if os(macOS)
        let persistedNote = notebookVisibleMacSidebar.descendants(matching: .any)
            .matching(identifier: originalIdentifier).firstMatch
#else
        let persistedNote = descendants(matching: .any)
            .matching(identifier: originalIdentifier).firstMatch
#endif
        XCTAssertTrue(
            persistedNote.waitForExistence(timeout: timeout),
            "Expected the original note after crossing a save boundary"
        )
#if os(iOS)
        if originalIdentifier.hasPrefix("notebook-sidebar-note-") {
            activate(staticTexts["notebook-sidebar-title-" + originalID])
        } else { activate(persistedNote) }
#else
        activate(persistedNote)
#endif
        let reopened = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                guard self.buttons["note-title"].label == originalTitle,
                      let observed = editor.value as? String,
                      let originalSource else { return false }
                return observed.utf8.elementsEqual(originalSource.utf8)
            }, object: self
        )
        XCTAssertEqual(XCTWaiter.wait(for: [reopened], timeout: timeout), .completed,
                       "Expected the original UUID and exact source after the save boundary")
        XCTAssertTrue(
            editor.waitForExistence(timeout: timeout),
            "Expected the original note to reopen after flushing"
        )
        return editor
    }

    func openOrCreateNotebookEditor(timeout: TimeInterval = 30) throws -> XCUIElement {
        let editor = textViews["markdown-editor"]
        if editor.waitForExistence(timeout: 1) {
            finishNotebookNaming(timeout: timeout)
            return editor
        }

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
        finishNotebookNaming(timeout: timeout)
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

    func returnFromNotebookLink(to expectedTitle: String, timeout: TimeInterval = 10) {
        let previous = buttons["note-link-back"]
        if previous.exists && previous.isHittable {
            activate(previous)
        } else {
            let back = navigationBars.buttons.matching(NSPredicate(
                format: "label == %@ OR label CONTAINS[c] %@ OR label == %@",
                expectedTitle, "Back", "meh.md"
            )).firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: timeout),
                          "Expected native Back returning to \(expectedTitle)")
            activate(back)
        }
    }

    func assertNotebookTrashIsPresented(timeout: TimeInterval = 5) {
        let trash = descendants(matching: .any)
            .matching(identifier: "notebook-trash-view").firstMatch
        XCTAssertTrue(trash.waitForExistence(timeout: timeout))
        let navigationTitle = navigationBars["Trash"].staticTexts["Trash"]
        let active = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"), object: navigationTitle
        )
        XCTAssertEqual(XCTWaiter.wait(for: [active], timeout: timeout), .completed,
                       "Expected Trash's native navigation title to stay visible above the sheet")
    }

    func revealNotebookSidebar(timeout: TimeInterval) {
#if os(iOS)
        let files = buttons["notebook-tree-toggle"]
        let expandedRecents = buttons["notebook-recents-close"]
        // Expanded Recents intentionally hides the compact Files toggle.
        // Its visible Close control already proves the browser is presented.
        guard !files.isHittable && !expandedRecents.isHittable else { return }
        let back = navigationBars.buttons.firstMatch
        XCTAssertTrue(
            back.waitForExistence(timeout: timeout),
            "Expected a navigation control that reveals the sidebar"
        )
        back.tap()
        let visible = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                files.isHittable || expandedRecents.isHittable
            }, object: self
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
