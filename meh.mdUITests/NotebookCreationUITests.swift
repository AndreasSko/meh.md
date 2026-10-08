import XCTest
#if os(iOS)
import UIKit

@MainActor
final class NotebookCreationUITests: XCTestCase {
    func testPointerGapPlacesFoldersBeforeAndAfterNote() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] =
            "pointer-gap-\(UUID().uuidString)"
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchEnvironment["MEH_NATIVE_INPUT_DIAGNOSTICS"] = "1"
        app.launchArguments += ["-editor.mode", "source"]
        app.launch()
        for text in ["Orbit Alpha", "Orbit Beta"] {
            let newNote = app.buttons["notebook-new-item"].firstMatch
            XCTAssertTrue(newNote.waitForExistence(timeout: 15))
            newNote.tap()
            let field = app.textFields["title-field"]
            XCTAssertTrue(field.waitForExistence(timeout: 10))
            replaceTitle(in: field, app: app, with: text)
            field.typeText("\n")
            showFiles(in: app)
        }
        let beta = title("Orbit Beta", in: app)
        func createFolder(_ name: String, at verticalOffset: CGFloat) {
            XCTAssertTrue(beta.isHittable)
            beta.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: verticalOffset))
                .press(forDuration: 1)
            app.buttons["New Folder"].tap()
            let field = app.textFields["Name"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.typeText(name + "\n")
            XCTAssertTrue(title(name, in: app).waitForExistence(timeout: 5))
        }
        createFolder("Upper Moon", at: 0.25)
        capture(app, name: "Folder created in the gap above a note")
        XCTAssertLessThan(title("Orbit Alpha", in: app).frame.minY,
                          title("Upper Moon", in: app).frame.minY)
        XCTAssertLessThan(title("Upper Moon", in: app).frame.minY, beta.frame.minY)
        createFolder("Lower Moon", at: 0.75)
        XCTAssertGreaterThan(title("Lower Moon", in: app).frame.minY, beta.frame.minY)
        createFolder("Center Moon", at: 0.5)
        XCTAssertGreaterThan(title("Center Moon", in: app).frame.minY, beta.frame.minY)
        capture(app, name: "Lower and center note presses create folders after it")
    }

    func testOpeningNoteFinishesNewFolderNaming() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        let reuseWorkspace = ProcessInfo.processInfo.environment["MEH_FILES_UI_WORKSPACE"]
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = reuseWorkspace
            ?? "folder-naming-\(UUID().uuidString)"
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchArguments += ["-editor.mode", "source"]
        app.launch()
        if reuseWorkspace == nil {
            let newNote = app.buttons["notebook-new-item"].firstMatch
            XCTAssertTrue(newNote.waitForExistence(timeout: 15))
            newNote.tap()
            XCTAssertTrue(app.textViews["markdown-editor"].waitForExistence(timeout: 10))
        }
        showFiles(in: app)
        app.buttons["notebook-app-menu"].tap()
        app.buttons["New Folder"].tap()
        let name = app.textFields["Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.typeText("Orbit Pending")
        capture(app, name: "Folder naming before tapping another note")
        let notes = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "notebook-sidebar-note-"
        ))
        let note = try XCTUnwrap(notes.allElementsBoundByIndex
            .first { $0.isHittable }, "Expected another visible Files note")
        note.tap()
        capture(app, name: "Files after tapping note during folder naming")
        XCTAssertTrue(app.textViews["markdown-editor"]
            .waitForExistence(timeout: 5),
            "Opening a note must finish inline folder naming")
        showFiles(in: app)
        XCTAssertTrue(title("Orbit Pending", in: app).waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        showFiles(in: app)
        XCTAssertTrue(title("Orbit Pending", in: app).waitForExistence(timeout: 5),
                      "Folder naming must persist before opening another note")
    }

    func testContextualFolderCreationAndBottomClearance() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = UUID().uuidString
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchArguments += ["-editor.mode", "source"]
        let originalOrientation = XCUIDevice.shared.orientation
        defer { XCUIDevice.shared.orientation = originalOrientation }
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCUIDevice.shared.orientation = .landscapeLeft
        }
        app.launch()
        XCTAssertTrue(app.buttons["notebook-app-menu"].waitForExistence(timeout: 15))
        let recents = app.buttons["notebook-recents-toggle"]
        if recents.value as? String == "Expanded" { recents.tap() }
        let tree = app.buttons["notebook-tree-toggle"]
        if tree.value as? String == "Collapsed" { tree.tap() }
        for index in 1...12 {
            app.buttons["notebook-app-menu"].tap()
            app.buttons["New Folder"].tap()
            let name = app.textFields["Name"]
            XCTAssertTrue(name.waitForExistence(timeout: 5))
            XCTAssertTrue(name.isHittable)
            name.typeText(String(format: "Orbit Folder %02d", index) + "\n")
        }
        let list = app.collectionViews.firstMatch
        list.swipeUp(velocity: .slow)
        Thread.sleep(forTimeInterval: 1)
        capture(app, name: "Files bottom with floating controls")
        let last = title("Orbit Folder 12", in: app)
        XCTAssertTrue(last.waitForExistence(timeout: 5))
        let search = app.searchFields.firstMatch
        let newNote = app.buttons["notebook-new-item"].firstMatch
        XCTAssertTrue(search.exists)
        XCTAssertTrue(newNote.exists)
        let floatingControlsTop: CGFloat
        if UIDevice.current.userInterfaceIdiom == .pad {
            let settings = app.buttons["notebook-settings"]
            let trash = app.buttons["notebook-trash-toggle"]
            XCTAssertTrue(settings.isHittable)
            XCTAssertTrue(trash.isHittable)
            floatingControlsTop = min(settings.frame.minY, trash.frame.minY)
        } else {
            floatingControlsTop = min(search.frame.minY, newNote.frame.minY)
        }
        XCTAssertLessThan(last.frame.maxY, floatingControlsTop - 16,
                          "Files can scroll beyond the last row above controls")
        last.press(forDuration: 1)
        app.buttons["New Folder"].tap()
        let name = app.textFields["Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertTrue(name.isHittable, "New folder must be revealed for naming")
        name.typeText("First Moon\n")
        let child = title("First Moon", in: app)
        XCTAssertTrue(child.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(child.frame.minY, last.frame.minY)
        capture(app, name: "New child folder revealed for naming")
        last.press(forDuration: 1)
        app.buttons["New Folder"].tap()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.typeText("Earlier Moon\n")
        let firstChild = title("Earlier Moon", in: app)
        XCTAssertTrue(firstChild.waitForExistence(timeout: 5))
        XCTAssertLessThan(firstChild.frame.minY, child.frame.minY,
                          "Context creation belongs at the start of a folder")
    }

    func testContextualNoteAppearsAfterItsSibling() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = UUID().uuidString
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchArguments += ["-editor.mode", "source"]
        app.launch()
        func create(_ text: String) {
            XCTAssertTrue(app.buttons["notebook-new-item"].firstMatch
                .waitForExistence(timeout: 15))
            app.buttons["notebook-new-item"].firstMatch.tap()
            let field = app.textFields["title-field"]
            XCTAssertTrue(field.waitForExistence(timeout: 10))
            replaceTitle(in: field, app: app, with: text)
            field.typeText("\n")
            showFiles(in: app)
        }
        create("Orbit Alpha")
        create("Orbit Beta")
        let alpha = title("Orbit Alpha", in: app)
        XCTAssertTrue(alpha.waitForExistence(timeout: 5))
        alpha.press(forDuration: 1)
        app.buttons.matching(NSPredicate(
            format: "label == %@ AND identifier != %@",
            "New Note", "notebook-new-item"
        )).firstMatch.tap()
        let field = app.textFields["title-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        replaceTitle(in: field, app: app, with: "Orbit Between")
        field.typeText("\n")
        showFiles(in: app)
        let middle = title("Orbit Between", in: app)
        XCTAssertTrue(middle.waitForExistence(timeout: 5))
        XCTAssertLessThan(alpha.frame.minY, middle.frame.minY)
        XCTAssertLessThan(middle.frame.minY, title("Orbit Beta", in: app).frame.minY)
        capture(app, name: "Contextual note inserted after its sibling")
    }

    private func replaceTitle(
        in field: XCUIElement, app: XCUIApplication, with title: String
    ) {
        field.tap()
        // Select using the native editing command rather than leaving an iOS
        // long-press menu open when a macOS menu-item query cannot find it.
        app.typeKey("a", modifierFlags: .command)
        field.typeText(title)
        let completed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", title), object: field
        )
        XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 5), .completed)
        XCTAssertEqual(field.value as? String, title)
    }

    private func showFiles(in app: XCUIApplication) {
        let tree = app.buttons["notebook-tree-toggle"]
        if !tree.isHittable { app.navigationBars.buttons.firstMatch.tap() }
        XCTAssertTrue(tree.waitForExistence(timeout: 5))
        let recents = app.buttons["notebook-recents-toggle"]
        if recents.value as? String == "Expanded" { recents.tap() }
        if tree.value as? String == "Collapsed" { tree.tap() }
    }

    private func title(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@",
            "notebook-sidebar-title-", name
        )).firstMatch
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
