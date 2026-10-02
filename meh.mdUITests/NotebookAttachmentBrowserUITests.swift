import XCTest

/// Self-contained UI checks use a unique, local-only fictional preview notebook.
/// Native Files picker checks require an explicit task-owned external fixture.
@MainActor
final class NotebookAttachmentBrowserUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] =
            "attachments-\(UUID().uuidString)"
        app.launchEnvironment["MEH_NOTEBOOK_TEST_FIXTURE"] = "attachment-browser"
        app.launchEnvironment["MEH_SYNC_CLOUDKIT"] = "0"
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchArguments += [
            "-editor.mode", "source",
            "-meh.md.backupIncludesAttachments", "NO",
            "-meh.md.backupFrequency", "off"
        ]
        app.launch()
    }

    override func tearDownWithError() throws {
        if let app {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Final accessibility hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            app.terminate()
        }
    }

    func testMixedFolderAndQuickLook() {
        let disclosure = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "notebook-disclosure-"
        )).firstMatch
        XCTAssertTrue(disclosure.waitForExistence(timeout: 30))
        if disclosure.value as? String != "Expanded" { disclosure.tap() }
        XCTAssertTrue(app.staticTexts["Diagram.pdf"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Notes"].exists)
        XCTAssertFalse(app.staticTexts["Discarded sample.bin"].exists)
        capture("After — mixed fictional folder")
        app.staticTexts["Diagram.pdf"].tap()
        let preview = app.descendants(matching: .any).matching(
            identifier: "notebook-attachment-content").firstMatch
        XCTAssertTrue(app.navigationBars["Diagram.pdf"].waitForExistence(timeout: 15))
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["notebook-attachment-export"].exists)
        XCTAssertFalse(app.buttons["notebook-attachment-preview"].exists)
        Thread.sleep(forTimeInterval: 2)
        capture("After — inline PDF preview")

        // On iPad the sidebar stays visible beside the preview. On iPhone,
        // return to the folder before selecting another item.
        let note = app.staticTexts["Notes"]
        if !note.isHittable {
            let back = app.buttons["BackButton"]
            XCTAssertTrue(back.waitForExistence(timeout: 10))
            back.tap()
        }
        XCTAssertTrue(note.waitForExistence(timeout: 10))
        note.tap()
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        XCTAssertEqual(editor.value as? String,
                       "# Fictional voyage\n\nLiteral **Markdown** stays intact.")
        capture("After — literal Markdown note")

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
        capture("After — reopened inline PDF preview")
    }

    func testLongPressImportsAndNormalTapCreatesNote() {
        let plus = app.buttons["notebook-new-item"].firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 30))
        plus.press(forDuration: 1)
        let files = app.buttons["Import Files…"]
        XCTAssertTrue(files.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Import Folder…"].exists)
        capture("After — browser import menu")
        files.tap()
        let cancel = app.buttons.matching(NSPredicate(
            format: "label IN %@", ["Cancel", "Abbrechen"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 15))
        capture("After — system document picker")
        cancel.tap()
        XCTAssertTrue(plus.waitForExistence(timeout: 10))
        plus.tap()
        XCTAssertTrue(app.textViews["markdown-editor"].waitForExistence(timeout: 15))
        capture("After — normal plus opens note")
    }

    func testStorageCountsRealAttachmentFiles() {
        XCTAssertTrue(app.buttons["notebook-new-item"].firstMatch
            .waitForExistence(timeout: 30))
        app.buttons["notebook-app-menu"].tap()
        app.buttons["notebook-settings"].tap()
        let storage = app.buttons["notebook-storage-settings"]
        for _ in 0..<8 where !storage.isHittable { app.swipeUp() }
        XCTAssertTrue(storage.waitForExistence(timeout: 10))
        storage.tap()
        let count = app.staticTexts["notebook-storage-attachment-count"]
        XCTAssertTrue(count.waitForExistence(timeout: 60))
        XCTAssertEqual(count.label, "1 attachment")
        XCTAssertTrue(app.staticTexts["1 attachment in Trash"].exists)
        let category = app.descendants(matching: .any).matching(
            identifier: "notebook-storage-category-attachments").firstMatch
        XCTAssertTrue(category.exists)
        XCTAssertFalse(category.label.contains("Zero KB"))
        XCTAssertFalse(category.label.contains("0 bytes"))
        XCTAssertFalse(app.staticTexts["notebook-storage-total"].label.isEmpty)
        capture("After — real local attachment storage")
    }

    func testAttachmentBackupTogglePersistsAndBackUpNowCompletes() {
        XCTAssertTrue(app.buttons["notebook-new-item"].firstMatch
            .waitForExistence(timeout: 30))
        app.buttons["notebook-app-menu"].tap()
        app.buttons["notebook-settings"].tap()

        let toggleRow = app.switches["notebook-backup-attachments"]
        for _ in 0..<8 where !toggleRow.isHittable { app.swipeUp() }
        XCTAssertTrue(toggleRow.waitForExistence(timeout: 10))
        let toggle = toggleRow.switches.firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0")
        capture("Attachment backups off")

        toggle.tap()
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "1"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
        capture("Attachment backups on")

        let backUpNow = app.buttons["notebook-backup-now"]
        XCTAssertTrue(backUpNow.isEnabled)
        backUpNow.tap()
        XCTAssertTrue(app.staticTexts["Last backup"].waitForExistence(timeout: 180))
        XCTAssertTrue(backUpNow.waitForExistence(timeout: 10))
        XCTAssertTrue(backUpNow.isEnabled)

        app.terminate()
        app.launchArguments = ["-editor.mode", "source"]
        app.launch()
        XCTAssertTrue(app.buttons["notebook-new-item"].firstMatch
            .waitForExistence(timeout: 30))
        app.buttons["notebook-app-menu"].tap()
        app.buttons["notebook-settings"].tap()
        let relaunchedToggleRow = app.switches["notebook-backup-attachments"]
        for _ in 0..<8 where !relaunchedToggleRow.isHittable { app.swipeUp() }
        XCTAssertTrue(relaunchedToggleRow.waitForExistence(timeout: 10))
        let relaunchedToggle = relaunchedToggleRow.switches.firstMatch
        XCTAssertTrue(relaunchedToggle.waitForExistence(timeout: 5))
        XCTAssertEqual(relaunchedToggle.value as? String, "1")
        capture("After relaunch — attachment backups remain enabled")
    }

    func testNativePickerImportsPDFAndOpensPreview() throws {
        try importPDFWithNativePicker(intoSelectedFolder: false)
    }

    func testFolderContextMenuImportsPDF() throws {
        try importPDFWithNativePicker(intoSelectedFolder: true)
    }

    func testBrowserStorageAndTrashWalkthrough() {
        let disclosure = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "notebook-disclosure-"
        )).firstMatch
        XCTAssertTrue(disclosure.waitForExistence(timeout: 30))
        if disclosure.value as? String != "Expanded" { disclosure.tap() }
        XCTAssertTrue(app.staticTexts["Diagram.pdf"].waitForExistence(timeout: 10))
        capture("Mixed fictional folder before Storage")
        testStorageCountsRealAttachmentFiles()
        app.navigationBars["Storage"].buttons["Settings"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["notebook-app-menu"].waitForExistence(timeout: 10))
        app.buttons["notebook-app-menu"].tap()
        app.buttons["notebook-trash-toggle"].tap()
        XCTAssertTrue(app.navigationBars["Trash"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Discarded sample.bin"].exists)
        XCTAssertFalse(app.staticTexts["Diagram.pdf"].isHittable)
        capture("Fictional binary in Trash")
        Thread.sleep(forTimeInterval: 2)
    }

    private func importPDFWithNativePicker(intoSelectedFolder: Bool) throws {
        guard let fixture = ProcessInfo.processInfo.environment[
            "MEH_ATTACHMENT_PICKER_FIXTURE"] else {
            throw XCTSkip("Supply a task-owned Files fixture")
        }
        let plus = app.buttons["notebook-new-item"].firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 30))
        if intoSelectedFolder {
            let folder = app.staticTexts["Attachments Demo"]
            XCTAssertTrue(folder.waitForExistence(timeout: 10))
            folder.press(forDuration: 0.5)
        } else {
            plus.press(forDuration: 1)
        }
        let files = app.buttons["Import Files…"]
        XCTAssertTrue(files.waitForExistence(timeout: 10))
        capture("After — browser import menu for native PDF")
        files.tap()
        let browse = app.buttons.matching(NSPredicate(
            format: "label IN %@", ["Browse", "Durchsuchen"])).firstMatch
        XCTAssertTrue(browse.waitForExistence(timeout: 15))
        browse.tap()
        Thread.sleep(forTimeInterval: 1)
        let pdf = app.cells.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "Imported diagram,")).firstMatch
        let sourceFolder = app.cells.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", fixture + ",")).firstMatch
        if !pdf.isHittable {
            if !sourceFolder.isHittable {
                let container = app.cells.matching(NSPredicate(
                    format: "identifier BEGINSWITH %@", "meh.md,")).firstMatch
                if !container.waitForExistence(timeout: 3) {
                    let local = app.cells.matching(NSPredicate(
                        format: "identifier IN %@", ["DOC.sidebar.item.On My iPhone",
                            "DOC.sidebar.item.Auf meinem iPhone"])).firstMatch
                    XCTAssertTrue(local.waitForExistence(timeout: 10))
                    local.tap()
                }
                XCTAssertTrue(container.waitForExistence(timeout: 10))
                container.tap()
            }
            XCTAssertTrue(sourceFolder.waitForExistence(timeout: 10))
            sourceFolder.tap()
        }
        XCTAssertTrue(pdf.waitForExistence(timeout: 10))
        pdf.tap()
        capture("After — selected fictional PDF in native picker")
        app.buttons.matching(NSPredicate(
            format: "label IN %@", ["Open", "Öffnen"])).firstMatch.tap()
        let imported = app.staticTexts["Imported diagram.pdf"]
        if intoSelectedFolder {
            let disclosure = app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH %@", "notebook-disclosure-"
            )).firstMatch
            XCTAssertTrue(imported.waitForExistence(timeout: 30))
            XCTAssertEqual(disclosure.value as? String, "Expanded",
                           "Import must reveal its destination folder automatically")
            capture("Native PDF imported into selected folder")
            disclosure.tap()
            XCTAssertFalse(imported.exists,
                           "The imported PDF must belong to the selected folder")
            disclosure.tap()
        } else {
            XCTAssertTrue(imported.waitForExistence(timeout: 30))
            capture("After — native PDF imported at root")
        }
        XCTAssertFalse(app.buttons["notebook-confirm-import"].exists)
        XCTAssertFalse(app.alerts["Import Complete"].exists)
        imported.tap()
        let inlinePreview = app.descendants(matching: .any).matching(
            identifier: "notebook-attachment-content").firstMatch
        XCTAssertTrue(app.navigationBars["Imported diagram.pdf"]
            .waitForExistence(timeout: 15))
        XCTAssertTrue(inlinePreview.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["notebook-attachment-export"].exists)
        XCTAssertFalse(app.buttons["notebook-attachment-preview"].exists)
        Thread.sleep(forTimeInterval: 2)
        capture("After — imported PDF preview inline")
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
