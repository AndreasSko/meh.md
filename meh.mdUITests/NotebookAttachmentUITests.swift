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
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
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

        let detail = app.staticTexts["notebook-attachment-title"]
        XCTAssertTrue(detail.waitForExistence(timeout: 10))
        XCTAssertEqual(detail.label, "Diagram.pdf")
        capture(app, named: "Attachment detail")
        let back = app.buttons["BackButton"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["notebook-tree-toggle"].waitForExistence(timeout: 5))
        app.staticTexts["Diagram.pdf"].tap()
        XCTAssertTrue(detail.waitForExistence(timeout: 10))
        let preview = app.buttons["notebook-attachment-preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        XCTAssertTrue(preview.isEnabled)
        XCTAssertTrue(app.buttons["notebook-attachment-export"].exists)
        preview.tap()
        let close = app.buttons["QLOverlayDoneButtonAccessibilityIdentifier"]
        XCTAssertTrue(
            close.waitForExistence(timeout: 10),
            "Expected Quick Look to open the PDF copy"
        )
        // Quick Look exposes its close control before the PDF page finishes
        // rendering; its document text has no stable accessibility element.
        Thread.sleep(forTimeInterval: 5)
        capture(app, named: "Attachment Quick Look")
        close.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let quickLookClosed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: close
        )
        XCTAssertEqual(XCTWaiter.wait(for: [quickLookClosed], timeout: 10), .completed)
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        let backReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"), object: back
        )
        XCTAssertEqual(XCTWaiter.wait(for: [backReady], timeout: 10), .completed)
        back.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["notebook-tree-toggle"].waitForExistence(timeout: 5))
        app.staticTexts["Notes"].tap()
        let noteTitle = app.buttons["note-title"]
        XCTAssertTrue(noteTitle.waitForExistence(timeout: 10))
        XCTAssertEqual(noteTitle.label, "Notes")
        capture(app, named: "Note after attachment")
    }

    private func capture(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
