import XCTest

extension XCUIApplication {
    func openSyncDetails(timeout: TimeInterval = 15) {
        let details = buttons["notebook-sync-details"]
        XCTAssertTrue(
            details.waitForExistence(timeout: timeout),
            "Expected the notebook sync details button"
        )
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
    }

    func openOrCreateNotebookEditor(timeout: TimeInterval = 30) throws -> XCUIElement {
        let editor = textViews["markdown-editor"]
        if editor.waitForExistence(timeout: 1) { return editor }

        let sidebar = buttons["notebook-new-item"]
        XCTAssertTrue(
            sidebar.waitForExistence(timeout: timeout),
            "Expected the notebook sidebar to finish loading"
        )

        let canonicalNote = staticTexts["note.md"]
        let markdownName = staticTexts.matching(
            NSPredicate(
                format: "label MATCHES[c] %@ AND label != %@",
                ".*\\.(md|markdown)$", "meh.md"
            )
        ).firstMatch
        // The toolbar can appear before asynchronous placements finish loading.
        _ = markdownName.waitForExistence(timeout: timeout)
        if canonicalNote.exists {
            activate(canonicalNote)
        } else {
            if markdownName.exists {
                activate(markdownName)
            } else {
                activate(sidebar)

            }
        }

        XCTAssertTrue(
            editor.waitForExistence(timeout: timeout),
            "Expected a selected notebook note to open its editor"
        )
        return editor
    }

    private func activate(_ element: XCUIElement) {
#if os(macOS)
        element.click()
#else
        element.tap()
#endif
    }
}
