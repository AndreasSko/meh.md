import XCTest
#if os(iOS)
import UIKit
#endif

@MainActor
final class UIReleasePolishUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] =
            "release-polish-\(UUID().uuidString)"
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchArguments += ["-editor.mode", "source"]
    }

    override func tearDownWithError() throws {
        if app.state == .runningForeground { app.terminate() }
    }

#if os(iOS)
    func testEmptyLibraryCanCreateAndEditItsFirstNote() throws {
        app.launch()
        let startWriting = app.buttons["notebook-start-writing"]
        let plus = app.buttons["notebook-new-item"].firstMatch
        let hasStartWriting = isBeforeCapture
            ? false
            : startWriting.waitForExistence(timeout: 20)
        if isBeforeCapture {
            XCTAssertTrue(plus.waitForExistence(timeout: 20))
        } else {
            XCTAssertTrue(hasStartWriting,
                          "The empty library should lead with Start Writing")
            XCTAssertFalse(app.textFields["title-field"].exists,
                           "Start Writing should skip the title prompt")
        }
        let importButton = app.buttons["notebook-empty-import"]
        let importFallback = app.buttons["Import Markdown"]
        if hasStartWriting {
            let emptyImport = importButton.exists ? importButton : importFallback
            XCTAssertTrue(emptyImport.waitForExistence(timeout: 5))
            XCTAssertTrue(emptyImport.isHittable)
        }
        capture("Before - empty library")

        if hasStartWriting { startWriting.tap() }
        else { plus.tap() }
        let title = app.textFields["title-field"]
        if isBeforeCapture && title.waitForExistence(timeout: 3) {
            title.typeText("Fictional release note\n")
        }
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        if hasStartWriting {
            XCTAssertFalse(title.exists,
                           "Start Writing should open the body without a title prompt")
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5),
                          "Start Writing should focus the new note for immediate typing")
        } else {
            editor.tap()
        }
        editor.typeText("A first note written in an isolated preview.")

        XCTAssertTrue(app.buttons["note-title"].waitForExistence(timeout: 5))
        XCTAssertTrue((editor.value as? String)?.contains("isolated preview") == true)
        capture("After - first note is created and edited")
    }

    func testEmptyLibraryImportOpensPickerAndCanCancel() throws {
        app.launch()
        let importButton = app.buttons["notebook-empty-import"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 20))
        capture("After - empty library import entry point")
        importButton.tap()

        let files = app.buttons["notebook-import-files"].firstMatch
        XCTAssertTrue(files.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["notebook-import-folder"].firstMatch.exists)
        capture("After - empty library import choices")
        files.tap()

        let cancelPicker = app.buttons.matching(NSPredicate(
            format: "label IN %@", ["Cancel", "Abbrechen"]
        )).firstMatch
        XCTAssertTrue(cancelPicker.waitForExistence(timeout: 15),
                      "The native Files picker should expose Cancel")
        cancelPicker.tap()
        XCTAssertTrue(importButton.waitForExistence(timeout: 10),
                      "Cancel should return to the empty library")
    }

    func testBrowserActionsExposeSettingsImportAndCreateAnotherNote() throws {
        app.launchEnvironment["MEH_NOTEBOOK_TEST_FIXTURE"] = "writing"
        app.launch()
        let browserMenu = app.buttons["notebook-application-actions"]
        let oldBrowserMenu = app.buttons["notebook-app-menu"]
        let menu = browserMenu.exists ? browserMenu : oldBrowserMenu
        if !menu.exists {
            let back = app.navigationBars.buttons.firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 10))
            back.tap()
        }
        let visibleMenu = app.buttons["notebook-application-actions"].exists
            ? app.buttons["notebook-application-actions"]
            : app.buttons["notebook-app-menu"]
        XCTAssertTrue(visibleMenu.waitForExistence(timeout: 10))
        visibleMenu.tap()
        let importBrowser = app.buttons["notebook-import-browser"]
        let settings = app.buttons["notebook-settings"]
        if importBrowser.exists {
            XCTAssertTrue(importBrowser.isHittable)
            capture("After - import is reachable from notebook actions")
            importBrowser.tap()
            for action in ["notebook-import-files", "notebook-import-folder"] {
                XCTAssertTrue(app.buttons[action].waitForExistence(timeout: 5))
            }
            capture("After - import file and folder actions")
            app.buttons["notebook-import-files"].firstMatch.tap()
            let cancel = app.buttons.matching(NSPredicate(
                format: "label IN %@", ["Cancel", "Abbrechen"]
            )).firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: 15))
            cancel.tap()
            XCTAssertTrue(app.buttons["notebook-app-menu"].waitForExistence(timeout: 10))
            return
        }

        if !isBeforeCapture {
            XCTFail("The browser actions should expose Import Markdown")
            return
        }

        if !app.buttons["notebook-import"].exists {
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            settings.tap()
        }
        let importAction = app.buttons["notebook-import"]
        XCTAssertTrue(importAction.waitForExistence(timeout: 10))
        XCTAssertTrue(importAction.isHittable)
        capture("After - import is reachable from notebook actions")
        importAction.tap()
        XCTAssertTrue(app.buttons["Import Files…"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Import Folder…"].exists)
        capture("After - import file and folder actions")
        app.buttons["Import Files…"].tap()
        let cancel = app.buttons.matching(NSPredicate(
            format: "label IN %@", ["Cancel", "Abbrechen"]
        )).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 15))
        cancel.tap()
        XCTAssertTrue(app.buttons["notebook-import"].waitForExistence(timeout: 10))
    }

    func testFormattingCommandChangesTheNoteSource() throws {
        app.launch()
        let plus = app.buttons["notebook-new-item"].firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 20))
        plus.tap()
        let title = app.textFields["title-field"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.typeText("Fictional formatting sample\n")
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.typeText("Harbor observations")
        editor.doubleTap()
        let bold = app.buttons["editor-command-bold"]
        XCTAssertTrue(bold.waitForExistence(timeout: 5))
        XCTAssertTrue(bold.isHittable)
        bold.tap()

        XCTAssertTrue((editor.value as? String)?.contains("**") == true,
                      "Bold should be written as literal Markdown in the note")
        capture("After - formatting command updates literal Markdown")
    }

    func testLongNoteTitleRemainsAccessibleInTheToolbar() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "This toolbar acceptance check targets iPad."
        )
        app.launch()
        let plus = app.buttons["notebook-new-item"].firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 20))
        plus.tap()
        let titleField = app.textFields["title-field"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 10))
        let longTitle = String(repeating: "Fictional voyage ", count: 4)
        titleField.typeText(longTitle + "\n")
        let title = app.buttons["note-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertEqual(title.label, longTitle)
        XCTAssertTrue(title.isHittable)
        capture("After - iPad note title in the editor toolbar")
    }

    func testNoteContextActionCreatesFolderBesideTheNote() throws {
        app.launchEnvironment["MEH_NOTEBOOK_TEST_FIXTURE"] = "writing"
        app.launch()
        let tree = app.buttons["notebook-tree-toggle"]
        XCTAssertTrue(tree.waitForExistence(timeout: 20))
        if tree.value as? String == "Collapsed" { tree.tap() }
        let recents = app.buttons["notebook-recents-toggle"]
        if recents.value as? String == "Expanded" { recents.tap() }

        let note = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@",
            "notebook-sidebar-title-", "Fictional field notes"
        )).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 10))
        var opened = false
        app.withoutIdleWait {
            note.press(forDuration: 1)
            let newFolderID = app.buttons["notebook-menu-new-folder"]
            let newFolderFallback = app.buttons["New Folder"]
            let newFolder = newFolderID.exists ? newFolderID : newFolderFallback
            if isBeforeCapture && !newFolder.waitForExistence(timeout: 2) {
                capture("Before - note context actions")
                return
            }
            XCTAssertTrue(newFolder.waitForExistence(timeout: 5))
            capture("Before - note context actions")
            newFolder.tap()
            opened = true
        }
        guard opened else { return }

        let folderName = app.textFields["Name"]
        XCTAssertTrue(folderName.waitForExistence(timeout: 5))
        folderName.typeText("Fictional folder\n")
        let folder = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@",
            "notebook-sidebar-title-", "Fictional folder"
        )).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 10))
        capture("After - folder created beside the selected note")
    }

    func testNoteMenusExposeTemplatesAndEditorDisplay() throws {
        app.launchEnvironment["MEH_NOTEBOOK_TEST_FIXTURE"] = "writing"
        // An argument-domain override would keep winning over menu changes.
        // This test switches modes through the UI in its fresh fixture suite.
        app.launchArguments = []
        app.launch()
        let tree = app.buttons["notebook-tree-toggle"]
        XCTAssertTrue(tree.waitForExistence(timeout: 20))
        if tree.value as? String == "Collapsed" { tree.tap() }
        let recents = app.buttons["notebook-recents-toggle"]
        if recents.value as? String == "Expanded" { recents.tap() }

        let note = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@",
            "notebook-sidebar-title-", "Fictional field notes"
        )).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 10))
        app.withoutIdleWait {
            note.press(forDuration: 1)
            let templates = app.buttons["Templates & Snippets"]
            XCTAssertTrue(templates.waitForExistence(timeout: 10))
            capture("After - Templates and Snippets submenu is reachable")
            templates.tap()
            let useAsTemplate = app.buttons["Use as Template"]
            XCTAssertTrue(useAsTemplate.waitForExistence(timeout: 5))
            useAsTemplate.tap()
        }

        note.tap()
        let noteActions = app.buttons["notebook-note-actions"]
        XCTAssertTrue(noteActions.waitForExistence(timeout: 10))
        noteActions.tap()
        let editorDisplay = app.buttons["Editor Display"]
        XCTAssertTrue(editorDisplay.waitForExistence(timeout: 5))
        editorDisplay.tap()
        let livePreview = app.buttons["Live Preview"]
        XCTAssertTrue(livePreview.waitForExistence(timeout: 5))
        app.buttons["Markdown Source"].tap()
        noteActions.tap()
        editorDisplay.tap()
        XCTAssertTrue(livePreview.waitForExistence(timeout: 5))
        capture("After - Editor Display choices are reachable")
        livePreview.tap()
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue((editor.value as? String)?.contains("Fictional") == true)
        capture("After - live preview keeps the note source available")
        noteActions.tap()
        editorDisplay.tap()
        XCTAssertTrue(livePreview.waitForExistence(timeout: 5))
        let modeValue = livePreview.value
        capture("After - Live Preview remains checked when reopened")
        XCTAssertTrue(livePreview.isSelected
                      || (modeValue as? NSNumber)?.boolValue == true
                      || modeValue as? String == "1",
                      "Live Preview should remain checked: \(livePreview.debugDescription), "
                      + "value: \(String(describing: modeValue))")
        livePreview.tap()
        editor.tap()
        capture("After - Live Preview renders outside the active paragraph")
    }

    func testPlusContextActionCreatesFolder() throws {
        app.launch()
        let plus = app.buttons["notebook-new-item"].firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 20))
        plus.press(forDuration: 1)
        capture("Before - plus context actions")
        let folderID = app.buttons["notebook-menu-new-folder"]
        let folderLabel = app.buttons["New Folder"]
        let newFolder = folderID.exists ? folderID : folderLabel
        if isBeforeCapture && !newFolder.waitForExistence(timeout: 2) { return }
        XCTAssertTrue(newFolder.waitForExistence(timeout: 5))
        newFolder.tap()
        let name = app.textFields["Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.typeText("Fictional quick folder\n")
        let folder = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@",
            "notebook-sidebar-title-", "Fictional quick folder"
        )).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 10))
        capture("After - plus context action creates a folder")
    }

    func testRetryCountdownMatchesTheDisabledRetryWindow() throws {
        app.launchEnvironment["MEH_NOTEBOOK_TEST_FIXTURE"] = "sync-status"
        app.launchEnvironment["MEH_NOTEBOOK_RETRY_TEST"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_RETRY_SECONDS"] = "12"
        app.launch()

        let details = app.buttons["notebook-sync-details"]
        XCTAssertTrue(details.waitForExistence(timeout: 30))
        details.tap()
        let statusTitle = app.staticTexts["note-sync-status"]
        XCTAssertTrue(statusTitle.waitForExistence(timeout: 15))
        if isBeforeCapture {
            XCTAssertTrue(app.staticTexts["sync-failure-explanation"].exists)
            capture("Before - retry status while cooldown is active")
            return
        }

        let failureTitle = statusTitle.label
        XCTAssertEqual(failureTitle, "Can't reach iCloud")
        let countdown = app.staticTexts["sync-retry-countdown"]
        XCTAssertTrue(countdown.waitForExistence(timeout: 10))
        XCTAssertTrue(countdown.label.contains("You can try again in"))
        let retry = app.buttons["sync-now"]
        XCTAssertFalse(retry.exists,
                       "The countdown replaces Try Again until retry is allowed")
        capture("After - retry countdown")

        XCTAssertTrue(retry.waitForExistence(timeout: 20))
        XCTAssertTrue(retry.isEnabled)
        XCTAssertFalse(countdown.exists,
                       "The countdown should disappear as retry becomes available")
        XCTAssertEqual(statusTitle.label, failureTitle,
                       "The sync headline should remain stable after the cooldown")
        capture("After - retry becomes available when countdown ends")
    }

    func testOfflineSyncStatusIsShortAndRetriesAutomatically() throws {
        app.launchEnvironment["MEH_NOTEBOOK_TEST_FIXTURE"] = "sync-status"
        app.launchEnvironment["MEH_NOTEBOOK_RETRY_TEST"] = "offline"
        app.launchEnvironment["MEH_NOTEBOOK_RETRY_SECONDS"] = "30"
        app.launch()

        let details = app.buttons["notebook-sync-details"]
        XCTAssertTrue(details.waitForExistence(timeout: 30))
        details.tap()
        let statusTitle = app.staticTexts["note-sync-status"]
        XCTAssertTrue(statusTitle.waitForExistence(timeout: 15))
        XCTAssertEqual(statusTitle.label, "You're offline")
        XCTAssertEqual(app.staticTexts["sync-failure-explanation"].label,
                       "Notes sync again once you're back online.")
        let countdown = app.staticTexts["sync-retry-countdown"]
        XCTAssertTrue(countdown.waitForExistence(timeout: 10))
        XCTAssertTrue(countdown.label.contains("Trying again in"))
        XCTAssertFalse(app.buttons["sync-now"].exists)
        capture("After - offline sync status")
    }
#endif

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private var isBeforeCapture: Bool {
        ProcessInfo.processInfo.environment["MEH_UI_POLISH_BASELINE"] == "1"
    }
}
