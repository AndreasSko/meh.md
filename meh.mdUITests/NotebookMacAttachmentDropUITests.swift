#if os(macOS)
import AppKit
import XCTest

/// Opt-in cross-application gestures use only disposable fictional sources.
@MainActor
final class NotebookMacAttachmentDropUITests: XCTestCase {
    private var app: XCUIApplication!
    private var finder: XCUIApplication!
    private var sources: URL!
    private var openedFinderWindow = false
    private var ownedFinderWindow: XCUIElement?

    func testInlinePDFPreviewPreservesNoteSourceAcrossSelection() throws {
        defer { cleanUp() }
        continueAfterFailure = false
        launchAttachmentFixture()
        XCTAssertTrue(folder.waitForExistence(timeout: 20))
        expandFolder()

        let note = row(prefix: "notebook-sidebar-note-", containing: "Notes")
        XCTAssertTrue(note.waitForExistence(timeout: 10))
        note.click()
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let source = "# Fictional voyage\n\nLiteral **Markdown** stays intact."
        XCTAssertEqual(editor.value as? String, source)
        capture("Inline PDF fixture note source")

        let attachment = row(
            prefix: "notebook-sidebar-attachment-", containing: "Diagram.pdf"
        )
        XCTAssertTrue(attachment.waitForExistence(timeout: 10))
        attachment.click()
        assertInlinePDFPreview()
        capture("Inline rendered Diagram.pdf")
        captureHierarchy("Inline rendered Diagram.pdf")

        note.click()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, source)
        capture("Note source unchanged after preview")

        attachment.click()
        assertInlinePDFPreview()
        capture("Reopened inline Diagram.pdf")
    }

    private func assertInlinePDFPreview(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // Quick Look's helper process exposes rendered PDF text through AX.
        // The SwiftUI identifier does not propagate into that native content.
        let preview = app.staticTexts["Fictional diagram"]
        XCTAssertTrue(
            preview.waitForExistence(timeout: 20),
            "Expected inline rendered PDF without a separate Preview action",
            file: file,
            line: line
        )
        XCTAssertFalse(preview.frame.isEmpty, file: file, line: line)
        XCTAssertTrue(
            preview.frame.intersects(app.windows.firstMatch.frame),
            file: file,
            line: line
        )
        XCTAssertTrue(
            app.buttons["notebook-attachment-export"]
                .waitForExistence(timeout: 10),
            file: file,
            line: line
        )
        XCTAssertFalse(
            app.buttons["notebook-attachment-preview"].exists,
            "Inline preview should not require a Preview button",
            file: file,
            line: line
        )
    }

    private func prepare() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MEH_MAC_ATTACHMENT_DROP_UI"] == "1",
            "Enable the opt-in native Finder drop acceptance run."
        )
        continueAfterFailure = false
        sources = FileManager.default.temporaryDirectory
            .appendingPathComponent("MehFictionalDrop-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: sources, withIntermediateDirectories: true
        )
        try Data([0, 255, 1, 2, 3]).write(
            to: sources.appendingPathComponent("Fictional specimen.bin")
        )
        // A unique visible marker identifies our window without relying on
        // Finder's AXTitle, which XCTest does not expose as a window label.
        try Data().write(to: sources.appendingPathComponent(finderMarkerName))
        launchAttachmentFixture()
        XCTAssertTrue(folder.waitForExistence(timeout: 20))
        positionWindow(app.windows.firstMatch, origin: CGPoint(x: 30, y: 40))
        finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
    }

    private func launchAttachmentFixture() {
        app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = UUID().uuidString
        app.launchEnvironment["MEH_NOTEBOOK_TEST_FIXTURE"] = "attachment-browser"
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchEnvironment["MEH_SYNC_CLOUDKIT"] = "0"
        app.launchArguments += ["-editor.mode", "source"]
        app.launch()
    }

    private func cleanUp() {
        if let window = ownedFinderWindow, window.exists {
            finder.activate()
            let close = window.buttons["_XCUI:CloseWindow"]
            if close.exists { close.click() }
        }
        app?.terminate()
        if let sources { try? FileManager.default.removeItem(at: sources) }
    }

    func testFinderFolderDropAndInternalMoveSurviveRelaunch() throws {
        defer { cleanUp() }
        try prepare()
        expandFolder()
        capture("Before Finder import")
        try dragFromFinder("Fictional specimen.bin", into: folder)
        XCTAssertTrue(app.staticTexts["Fictional specimen.bin"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["notebook-confirm-import"].exists)
        XCTAssertFalse(app.sheets.containing(NSPredicate(
            format: "elementType == %d AND (label == %@ OR value == %@)",
            XCUIElement.ElementType.staticText.rawValue,
            "Import Complete", "Import Complete"
        )).firstMatch.exists)
        capture("Finder file added inside destination folder")

        // Collapsing the destination proves the imported row is its child.
        collapseFolder()
        XCTAssertFalse(app.staticTexts["Fictional specimen.bin"].isHittable)
        expandFolder()
        XCTAssertTrue(app.staticTexts["Fictional specimen.bin"].isHittable)

        // Internal note moves still work after a Finder import.
        let note = row(prefix: "notebook-sidebar-note-", containing: "Notes")
        XCTAssertTrue(note.waitForExistence(timeout: 10))
        let files = app.buttons["notebook-tree-toggle"]
        XCTAssertTrue(files.isHittable)
        note.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5))
            .click(forDuration: 0.15, thenDragTo:
                files.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
                withVelocity: .slow, thenHoldForDuration: 0.3)
        collapseFolder()
        XCTAssertTrue(note.isHittable, "Internal note drag should move Notes to root")
        note.click()
        XCTAssertEqual(
            app.textViews["markdown-editor"].value as? String,
            "# Fictional voyage\n\nLiteral **Markdown** stays intact."
        )
        capture("Internal note drag preserves Markdown")

        app.terminate()
        app.launch()
        XCTAssertTrue(folder.waitForExistence(timeout: 20))
        expandFolder()
        XCTAssertTrue(app.staticTexts["Fictional specimen.bin"].waitForExistence(timeout: 10))
        collapseFolder()
        XCTAssertFalse(app.staticTexts["Fictional specimen.bin"].isHittable)
        let reopenedNote = row(prefix: "notebook-sidebar-note-", containing: "Notes")
        XCTAssertTrue(reopenedNote.isHittable)
        reopenedNote.click()
        XCTAssertEqual(
            app.textViews["markdown-editor"].value as? String,
            "# Fictional voyage\n\nLiteral **Markdown** stays intact."
        )
        capture("Finder destination and internal move persist after relaunch")
    }

    private var folder: XCUIElement {
        row(prefix: "notebook-sidebar-folder-", containing: "Attachments Demo")
    }

    private func row(prefix: String, containing label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", prefix
        )).containing(.staticText, identifier: label).firstMatch
    }

    private var folderDisclosure: XCUIElement {
        let id = String(folder.identifier.dropFirst("notebook-sidebar-folder-".count))
        return app.buttons["notebook-disclosure-" + id]
    }

    private func expandFolder() {
        let disclosure = folderDisclosure
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        if disclosure.value as? String != "Expanded" { disclosure.click() }
    }

    private func collapseFolder() {
        let disclosure = folderDisclosure
        if disclosure.value as? String == "Expanded" { disclosure.click() }
    }

    private var finderMarkerName: String {
        sources.lastPathComponent + ".fixture"
    }

    private func dragFromFinder(_ filename: String, into destination: XCUIElement) throws {
        // Keep the notebook above unrelated windows before Finder covers it.
        app.activate()
        finder.activate()
        if !openedFinderWindow {
            finder.typeKey("n", modifierFlags: .command)
            openedFinderWindow = true
        }
        finder.typeKey("g", modifierFlags: [.command, .shift])
        let path = finder.textFields.firstMatch
        XCTAssertTrue(path.waitForExistence(timeout: 5))
        path.typeKey("a", modifierFlags: .command)
        path.typeText(sources.path)
        path.typeKey(.return, modifierFlags: [])
        // The hosted Finder hierarchy exposes native file icons as Images.
        finder.typeKey("1", modifierFlags: .command)
        let window = finder.windows.containing(
            .image, identifier: finderMarkerName
        ).firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        ownedFinderWindow = window
        let appFrame = app.windows.firstMatch.frame
        positionWindow(window, origin: CGPoint(
            x: appFrame.minX + appFrame.width * 0.4,
            y: appFrame.minY + min(180, appFrame.height * 0.25)
        ))
        let source = window.images[filename]
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        XCTAssertTrue(source.isHittable)
        XCTAssertTrue(destination.isHittable)
        let target = CGPoint(
            x: destination.frame.minX + destination.frame.width * 0.65,
            y: destination.frame.midY
        )
        XCTAssertFalse(window.frame.contains(target), "Finder must leave the folder drop target exposed")
        // Select in Finder first, then begin the separate native drag gesture.
        source.click()
        source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .click(forDuration: 0.15, thenDragTo:
                destination.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5)),
                withVelocity: .slow, thenHoldForDuration: 0.3)
        app.activate()
    }

    private func positionWindow(_ window: XCUIElement, origin: CGPoint) {
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let frame = window.frame
        let titlePoint = CGPoint(x: frame.minX + 100, y: frame.minY + 8)
        guard !frame.isEmpty, frame.minX.isFinite, frame.minY.isFinite,
              frame.maxX.isFinite, frame.maxY.isFinite,
              frame.contains(titlePoint) else {
            XCTFail("Window placement requires a finite titlebar point")
            return
        }
        let controls = window.descendants(matching: .button).allElementsBoundByIndex
            + window.descendants(matching: .textField).allElementsBoundByIndex
        guard !controls.contains(where: { $0.frame.contains(titlePoint) }) else {
            XCTFail("Window drag must start on blank titlebar space")
            return
        }
        let start = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 100, dy: 8))
        start.click(forDuration: 0.15, thenDragTo: start.withOffset(CGVector(
            dx: origin.x - frame.minX, dy: origin.y - frame.minY
        )), withVelocity: .slow, thenHoldForDuration: 0.3)
        let positioned = NSPredicate { _, _ in
            abs(window.frame.minX - origin.x) <= 8
                && abs(window.frame.minY - origin.y) <= 8
        }
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: positioned, object: window
        )], timeout: 5) == .completed, "Native window drag must reach the requested origin")
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func captureHierarchy(_ name: String) {
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(name) accessibility hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}
#endif
