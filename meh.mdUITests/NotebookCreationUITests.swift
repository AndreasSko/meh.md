import XCTest

#if os(iOS)
@MainActor
final class NotebookCreationUITests: XCTestCase {
    func testContextualCreationPlacesItemsAroundNote() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] =
            "pointer-gap-\(UUID().uuidString)"
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
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
        let alpha = title("Orbit Alpha", in: app)
        let beta = title("Orbit Beta", in: app)
        XCTAssertTrue(alpha.waitForExistence(timeout: 5))
        alpha.press(forDuration: 1)
        app.buttons.matching(NSPredicate(
            format: "label == %@ AND identifier != %@",
            "New Note", "notebook-new-item"
        )).firstMatch.tap()
        let noteField = app.textFields["title-field"]
        XCTAssertTrue(noteField.waitForExistence(timeout: 10))
        replaceTitle(in: noteField, app: app, with: "Orbit Between")
        noteField.typeText("\n")
        showFiles(in: app)
        let middle = title("Orbit Between", in: app)
        XCTAssertTrue(middle.waitForExistence(timeout: 5))
        XCTAssertLessThan(alpha.frame.minY, middle.frame.minY)
        XCTAssertLessThan(middle.frame.minY, beta.frame.minY)

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
        XCTAssertLessThan(middle.frame.minY, title("Upper Moon", in: app).frame.minY)
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
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] =
            "folder-naming-\(UUID().uuidString)"
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchArguments += ["-editor.mode", "source"]
        app.launch()
        let newNote = app.buttons["notebook-new-item"].firstMatch
        XCTAssertTrue(newNote.waitForExistence(timeout: 15))
        newNote.tap()
        XCTAssertTrue(app.textViews["markdown-editor"].waitForExistence(timeout: 10))
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

    func testContextualFolderCreationStartsInsideFolder() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = UUID().uuidString
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchArguments += ["-editor.mode", "source"]
        app.launch()
        XCTAssertTrue(app.buttons["notebook-app-menu"].waitForExistence(timeout: 15))
        let recents = app.buttons["notebook-recents-toggle"]
        if recents.value as? String == "Expanded" { recents.tap() }
        let tree = app.buttons["notebook-tree-toggle"]
        if tree.value as? String == "Collapsed" { tree.tap() }
        app.buttons["notebook-app-menu"].tap()
        app.buttons["New Folder"].tap()
        let name = app.textFields["Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.typeText("Orbit Folder\n")
        let parent = title("Orbit Folder", in: app)
        XCTAssertTrue(parent.waitForExistence(timeout: 5))

        parent.press(forDuration: 1)
        app.buttons["New Folder"].tap()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertTrue(name.isHittable, "New folder must be revealed for naming")
        name.typeText("First Moon\n")
        let child = title("First Moon", in: app)
        XCTAssertTrue(child.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(child.frame.minY, parent.frame.minY)
        capture(app, name: "New child folder revealed for naming")

        parent.press(forDuration: 1)
        app.buttons["New Folder"].tap()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.typeText("Earlier Moon\n")
        let firstChild = title("Earlier Moon", in: app)
        XCTAssertTrue(firstChild.waitForExistence(timeout: 5))
        XCTAssertLessThan(firstChild.frame.minY, child.frame.minY,
                          "Context creation belongs at the start of a folder")
    }

    private func replaceTitle(
        in field: XCUIElement, app: XCUIApplication, with title: String
    ) {
        let old = field.value as? String ?? ""
        field.tap()
        field.press(forDuration: 1.2)
        let selectAll = app.menuItems["Select All"]
        if selectAll.waitForExistence(timeout: 2) {
            selectAll.tap()
            field.typeText(title)
        } else {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue,
                                 count: old.count) + title)
        }
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
