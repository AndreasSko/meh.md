import XCTest

@MainActor
final class NotebookAttachmentUITests: XCTestCase {
    func testImportedFileOpensAndPreviewsWithoutEditingItsBytes() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] =
            UUID().uuidString
        app.launchEnvironment["MEH_NOTEBOOK_ATTACHMENT_TEST"] = "1"
        app.launchEnvironment["MEH_SYNC_CLOUDKIT"] = "0"
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchArguments += ["-editor.mode", "source"]
        app.launch()

        let disclosure = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "notebook-disclosure-"
        )).firstMatch
        XCTAssertTrue(disclosure.waitForExistence(timeout: 20))
        if disclosure.value as? String != "Expanded" { disclosure.tap() }

        let file = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "notebook-sidebar-attachment-"
        )).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Diagram.pdf"].exists)
        capture(app, named: "Mixed note and file folder")
        app.staticTexts["Diagram.pdf"].tap()

        let preview = app.descendants(matching: .any).matching(
            identifier: "notebook-attachment-content").firstMatch
        XCTAssertTrue(app.navigationBars["Diagram.pdf"].waitForExistence(timeout: 15))
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        let export = app.buttons["notebook-attachment-export"]
        XCTAssertTrue(export.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["notebook-attachment-preview"].exists)
        Thread.sleep(forTimeInterval: 2)
        capture(app, named: "Attachment inline PDF preview")

        export.tap()
        let nativePopover = app.popovers.firstMatch
        XCTAssertTrue(nativePopover.waitForExistence(timeout: 10))
        let nativeCopy = app.cells.matching(identifier: "actionGroupCell")
            .matching(NSPredicate(format: "label IN %@", ["Copy", "Kopieren"]))
            .firstMatch
        XCTAssertTrue(nativeCopy.waitForExistence(timeout: 10))
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Native PDF share sheet accessibility hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        capture(app, named: "Native PDF share sheet")

        let dismissRegion = app.otherElements["PopoverDismissRegion"]
        XCTAssertTrue(dismissRegion.exists)
        dismissRegion.tap()
        let shareDismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: nativePopover
        )
        XCTAssertEqual(XCTWaiter.wait(for: [shareDismissed], timeout: 10), .completed)
        XCTAssertTrue(export.waitForExistence(timeout: 10))
        XCTAssertTrue(export.isHittable)

        let note = app.staticTexts["Notes"]
        if !note.isHittable {
            let back = app.buttons["BackButton"]
            XCTAssertTrue(back.waitForExistence(timeout: 10))
            back.tap()
        }
        XCTAssertTrue(note.waitForExistence(timeout: 10))
        note.tap()
        let noteTitle = app.buttons["note-title"]
        XCTAssertTrue(noteTitle.waitForExistence(timeout: 10))
        XCTAssertEqual(noteTitle.label, "Notes")
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String,
                       "# Project notes\n\nA fictional attachment example.\n")
        capture(app, named: "Literal Markdown after attachment")

        let attachment = app.staticTexts["Diagram.pdf"]
        if !attachment.isHittable {
            let back = app.buttons["BackButton"]
            XCTAssertTrue(back.waitForExistence(timeout: 10))
            back.tap()
        }
        XCTAssertTrue(attachment.waitForExistence(timeout: 10))
        attachment.tap()
        XCTAssertTrue(app.navigationBars["Diagram.pdf"].waitForExistence(timeout: 15))
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 2)
        capture(app, named: "Reopened inline PDF preview")
    }

    private func capture(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
