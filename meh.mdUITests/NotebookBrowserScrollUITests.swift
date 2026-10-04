import XCTest
#if os(iOS)
import UIKit

final class NotebookBrowserScrollUITests: XCTestCase {
    func testBottomFilesNoteKeepsItsPositionAfterReturning() throws {
        try XCTSkipIf(
            UIDevice.current.userInterfaceIdiom != .phone,
            "This test requires compact navigation."
        )
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        let reuseWorkspace = ProcessInfo.processInfo.environment["MEH_FILES_UI_WORKSPACE"]
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = reuseWorkspace
            ?? "files-return-\(UUID().uuidString)"
        app.launchArguments += ["-editor.mode", "source"]
        app.launch()

        for index in (reuseWorkspace == nil ? Array(1...16) : []) {
            let newNote = app.buttons["notebook-new-item"].firstMatch
            XCTAssertTrue(newNote.waitForExistence(timeout: 15))
            newNote.tap()
            let field = app.textFields["title-field"]
            XCTAssertTrue(field.waitForExistence(timeout: 10))
            field.tap()
            let oldTitle = field.value as? String ?? ""
            field.typeText(
                String(repeating: XCUIKeyboardKey.delete.rawValue, count: oldTitle.count)
                    + String(format: "Moon Journal %02d", index) + "\n"
            )
            XCTAssertTrue(app.textViews["markdown-editor"].waitForExistence(timeout: 10))
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(app.buttons["notebook-tree-toggle"].waitForExistence(timeout: 10))
        }
        let recents = app.buttons["notebook-recents-toggle"]
        if recents.value as? String == "Expanded" { recents.tap() }
        let files = app.buttons["notebook-tree-toggle"]
        if files.value as? String == "Collapsed" { files.tap() }
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        list.swipeUp(velocity: .slow)
        // Compare settled viewports after native deceleration finishes.
        Thread.sleep(forTimeInterval: 1)
        let notes = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "notebook-sidebar-note-"
        ))
        let bottom = notes.allElementsBoundByIndex
            .filter { $0.isHittable && $0.frame.maxY < app.frame.maxY - 65 }
            .max { $0.frame.midY < $1.frame.midY }
        let note = try XCTUnwrap(bottom, "Expected a visible note near the bottom")
        let identifier = note.identifier
        let original = note.frame
        capture(app, name: "Files before opening bottom note")
        for cycle in 0..<3 {
            let target = app.descendants(matching: .any)[identifier]
            XCTAssertTrue(target.isHittable)
            target.tap()
            let editor = app.textViews["markdown-editor"]
            XCTAssertTrue(editor.waitForExistence(timeout: 10))
            if cycle == 2 {
                edgeBack(in: app, completing: false)
                let cancelled = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "hittable == true"), object: editor
                )
                XCTAssertEqual(
                    XCTWaiter.wait(for: [cancelled], timeout: 5), .completed,
                    "Cancelling Back must leave the note open"
                )
                edgeBack(in: app, completing: true)
            } else {
                app.navigationBars.buttons.firstMatch.tap()
            }
            XCTAssertTrue(files.waitForExistence(timeout: 10))
            let returned = app.descendants(matching: .any)[identifier]
            XCTAssertTrue(returned.waitForExistence(timeout: 10))
            capture(app, name: cycle == 0
                    ? "Files after returning from bottom note"
                    : "Files after return cycle \(cycle + 1)")
            XCTAssertEqual(
                returned.frame.minY, original.minY, accuracy: 2,
                "Returning should preserve the Files list viewport"
            )
            XCTAssertTrue(returned.isHittable)
            let search = app.searchFields.firstMatch
            if search.exists {
                XCTAssertLessThan(returned.frame.maxY, search.frame.minY)
            }
        }
        let firstBeforePan = try XCTUnwrap(
            notes.allElementsBoundByIndex.first { $0.isHittable }
        ).identifier
        list.swipeDown(velocity: .slow)
        Thread.sleep(forTimeInterval: 1)
        let firstAfterPan = try XCTUnwrap(
            notes.allElementsBoundByIndex.first { $0.isHittable }
        ).identifier
        XCTAssertNotEqual(
            firstAfterPan, firstBeforePan,
            "A new pan must move Files instead of restoring the old viewport"
        )
    }

    private func edgeBack(in app: XCUIApplication, completing: Bool) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.002, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(
            dx: completing ? 0.95 : 0.25, dy: 0.5
        ))
        start.press(forDuration: 0.05, thenDragTo: end,
                    withVelocity: .slow, thenHoldForDuration: 0.5)
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
