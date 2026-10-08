import XCTest
#if os(macOS)
import AppKit
#endif

/// Exercises native mouse/touch drags against isolated fictional notebooks.
/// Run this suite on macOS, an iPhone simulator and an iPad simulator.
@MainActor
final class NotebookDragUITests: XCTestCase {
    private var ownedPreviewRuns = Set<String>()

    func testSortDragResortAndRelaunchPreserveOrderAndSource() throws {
        let app = launchNotebook()
        let charlie = createNote("Charlie", in: app)
        let alpha = createNote("Alpha", in: app)
        let bravo = createNote("Bravo", in: app)
        activate(title(of: bravo, in: app))
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        activate(editor)
        editor.typeText("# Fictional voyage\n\nLiteral **Markdown** stays intact.")
        showSidebar(app)
        // Switching notes crosses the editor save boundary before dragging.
        activate(title(of: alpha, in: app))
        showSidebar(app)
        chooseSort("Name, A–Z", in: app)
        assertOrder([alpha, bravo, charlie], in: app)
        capture(app, "01 Name sorted before drag")

        drag(charlie, to: alpha, at: 0.1)
        assertOrder([charlie, alpha, bravo], in: app)
        capture(app, "02 Native drag overrides previous sort")
        app.terminate()
        app.launch()
        showSidebar(app)
        assertOrder([charlie, alpha, bravo], in: app)
        capture(app, "03 Manual order persists after relaunch")

        chooseSort("Name, Z–A", in: app)
        assertOrder([charlie, bravo, alpha], in: app)
        drag(alpha, to: charlie, at: 0.1)
        assertOrder([alpha, charlie, bravo], in: app)
        chooseSort("Name, A–Z", in: app)
        assertOrder([alpha, bravo, charlie], in: app)
        app.terminate()
        app.launch()
        showSidebar(app)
        assertOrder([alpha, bravo, charlie], in: app)
        activate(title(of: bravo, in: app))
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(
            editor.value as? String,
            "# Fictional voyage\n\nLiteral **Markdown** stays intact."
        )
        capture(app, "04 Literal source preserved after drag and resort")
    }

    func testClosedAndNestedFolderHoverThenReturnToFiles() throws {
        let app = launchNotebook()
        let note = createNote("Travel checklist", in: app)
        let outer = createFolder("Journeys", in: app)
        let inner = createFolder("Weekend", inside: outer, in: app)
        collapse(outer, in: app)
        XCTAssertFalse(inner.exists)
        capture(app, "01 Closed destination before drag")

        drag(note, to: outer, hold: 1.5)
        XCTAssertEqual(disclosure(for: outer, in: app).value as? String, "Expanded")
        XCTAssertTrue(inner.waitForExistence(timeout: 5))
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        capture(app, "02 Hover opens closed destination")
        collapse(outer, in: app)
        XCTAssertTrue(note.waitForNonExistence(timeout: 5))
        expand(outer, in: app)

        collapse(inner, in: app)
        drag(note, to: inner, hold: 1.5)
        XCTAssertEqual(disclosure(for: inner, in: app).value as? String, "Expanded")
        capture(app, "03 Hover opens nested destination")
        collapse(inner, in: app)
        XCTAssertTrue(note.waitForNonExistence(timeout: 5))
        expand(inner, in: app)
        XCTAssertTrue(note.waitForExistence(timeout: 5))

        drag(note, to: app.buttons["notebook-tree-toggle"])
        collapse(outer, in: app)
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        capture(app, "04 Files header returns note to root")
        app.terminate()
        app.launch()
        showSidebar(app)
        collapse(outer, in: app)
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        // A completed drag must leave ordinary native row actions available.
        openContextMenu(on: note, in: app)
        activate(menuAction("Move…", in: app))
        let cancel = app.buttons["notebook-cancel-move"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        activate(cancel)
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        capture(app, "05 Context actions remain available after drag")
    }

    func testFolderSubtreeRejectsDescendantAndCancelledDragKeepsSelection() throws {
        let app = launchNotebook()
        let note = createNote("Packing list", in: app)
        let parent = createFolder("Trips", in: app)
        let child = createFolder("Island", inside: parent, in: app)
        let destination = createFolder("Archive", in: app)
        expand(parent, in: app)
        drag(note, to: child, hold: 1.5)
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        collapse(parent, in: app)
        XCTAssertTrue(note.waitForNonExistence(timeout: 5))

        drag(parent, to: destination, hold: 1.5)
        expand(parent, in: app)
        expand(child, in: app)
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        capture(app, "01 Folder subtree moved together")
        collapse(destination, in: app)
        XCTAssertTrue(parent.waitForNonExistence(timeout: 5))
        XCTAssertFalse(child.exists)
        XCTAssertFalse(note.exists)
        expand(destination, in: app)
        expand(parent, in: app)
        expand(child, in: app)

        // Dropping an ancestor into its own descendant must leave the tree intact.
        drag(parent, to: child, hold: 1.5)
        assertOrder([destination, parent, child, note], in: app)
        capture(app, "02 Descendant drop leaves hierarchy intact")
        collapse(parent, in: app)
        XCTAssertTrue(child.waitForNonExistence(timeout: 5))
        expand(parent, in: app)
        expand(child, in: app)

        // Release over the toolbar, outside every notebook destination.
        drag(note, to: app.descendants(matching: .any).matching(identifier: "notebook-new-item").firstMatch)
        collapse(child, in: app)
        XCTAssertTrue(note.waitForNonExistence(timeout: 5))
        expand(child, in: app)
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        capture(app, "03 Cancelled drag keeps original parent")
        #if os(iOS)
        activate(appMenu(in: app))
        activate(app.descendants(matching: .any)["notebook-select-items"])
        #endif
        activate(title(of: note, in: app))
        assertSelection([note], in: app)
        #if os(iOS)
        activate(app.buttons["notebook-selection-done"])
        #endif
        capture(app, "04 Selection still works after cancelled drag")

        #if os(iOS)
        title(of: note, in: app).swipeLeft(velocity: .slow)
        let trash = app.buttons["notebook-swipe-trash"]
        if trash.waitForExistence(timeout: 2), trash.isHittable { activate(trash) }
        XCTAssertTrue(note.waitForNonExistence(timeout: 5))
        app.openTrash()
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        capture(app, "05 Swipe to Trash works after drag")
        openContextMenu(on: note, in: app)
        activate(menuAction("Restore", in: app))
        app.closeTrash()
        expand(destination, in: app)
        expand(parent, in: app)
        expand(child, in: app)
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        #endif
    }

    @MainActor
    func testContinuousNestedHoverMovesNoteIntoDeepFolder() throws {
        let app = launchNotebook()
        let note = createNote("Voyage checklist", in: app)
        let outer = createFolder("Journeys", in: app)
        let inner = createFolder("Weekend", inside: outer, in: app)
        let destination = createFolder("Island", inside: inner, in: app)
        expand(outer, in: app)
        expand(inner, in: app)
        let destinationPoint = destination.coordinate(
            withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)
        ).screenPoint
        collapse(inner, in: app)
        let innerPoint = inner.coordinate(
            withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)
        ).screenPoint
        collapse(outer, in: app)
        let outerPoint = outer.coordinate(
            withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)
        ).screenPoint
        #if os(macOS)
        activate(title(of: note, in: app))
        assertSelection([note], in: app)
        #endif
        let sourcePoint = note.coordinate(
            withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)
        ).screenPoint
        capture(app, "Continuous drag starts with both folders closed")
        try NotebookContinuousDrag.perform(
            from: sourcePoint, hoveringOver: [outerPoint, innerPoint],
            to: destinationPoint
        )
        XCTAssertEqual(disclosure(for: outer, in: app).value as? String, "Expanded")
        XCTAssertEqual(disclosure(for: inner, in: app).value as? String, "Expanded")
        expand(destination, in: app)
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        assertOrder([outer, inner, destination, note], in: app)
        capture(app, "One held drag spring loads two folders and drops deeper")
        collapse(destination, in: app)
        XCTAssertTrue(note.waitForNonExistence(timeout: 5))
        app.terminate()
        app.launch()
        showSidebar(app)
        expand(outer, in: app)
        expand(inner, in: app)
        expand(destination, in: app)
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        capture(app, "Continuous nested drop persists after relaunch")
    }

    @MainActor
    func testNestedFixtureSequentialAndContinuousHoverPreservesSource() throws {
        let app = launchNotebook(nestedFixture: true)
        let note = row(named: "Voyage checklist", prefix: "notebook-sidebar-note-", in: app)
        let outer = row(named: "Journeys", prefix: "notebook-sidebar-folder-", in: app)
        collapse(outer, in: app)
        #if os(macOS)
        activate(title(of: note, in: app))
        assertSelection([note], in: app)
        #endif
        let cancelDestination = app.descendants(matching: .any)
            .matching(identifier: "notebook-new-item").firstMatch
        XCTAssertTrue(cancelDestination.waitForExistence(timeout: 5))
        XCTAssertTrue(title(of: note, in: app).isHittable)
        XCTAssertFalse(note.frame.isEmpty)
        XCTAssertFalse(outer.frame.isEmpty)
        capture(app, "Held hover cancellation starts with Journeys closed")
        // Expand during one held drag, then release over the toolbar outside
        // every drop destination. The next ordinary disclosure click must work.
        try NotebookContinuousDrag.perform(
            from: note.coordinate(
                withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)
            ).screenPoint,
            hoveringOver: [outer.coordinate(
                withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)
            ).screenPoint],
            to: cancelDestination.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
            ).screenPoint,
            // Match the public held-drag checks' margin for native lift and
            // destination recognition before the app's spring timer starts.
            hoverDuration: 1.5
        )
        XCTAssertEqual(disclosure(for: outer, in: app).value as? String, "Expanded")
        let hoveredInner = row(named: "Weekend", prefix: "notebook-sidebar-folder-", in: app)
        capture(app, "Cancelled held hover expands Journeys without moving Voyage")
        collapse(outer, in: app)
        XCTAssertEqual(disclosure(for: outer, in: app).value as? String, "Collapsed")
        XCTAssertTrue(hoveredInner.waitForNonExistence(timeout: 5))
        XCTAssertTrue(note.waitForExistence(timeout: 5),
                      "Cancelling the held hover keeps Voyage at Files root")
        assertOrder([note, outer], in: app)

        drag(note, to: outer, hold: 1.5)
        XCTAssertEqual(disclosure(for: outer, in: app).value as? String, "Expanded")
        let inner = row(named: "Weekend", prefix: "notebook-sidebar-folder-", in: app)
        collapse(outer, in: app)
        XCTAssertTrue(note.waitForNonExistence(timeout: 5))
        expand(outer, in: app)
        collapse(inner, in: app)
        drag(note, to: inner, hold: 1.5)
        XCTAssertEqual(disclosure(for: inner, in: app).value as? String, "Expanded")
        let island = row(named: "Island", prefix: "notebook-sidebar-folder-", in: app)
        collapse(inner, in: app)
        XCTAssertTrue(note.waitForNonExistence(timeout: 5),
                      "After collapse/reexpand, Weekend must receive the drop")
        expand(inner, in: app)
        capture(app, "Seeded sequential hover reaches nested folder")
        drag(note, to: app.buttons["notebook-tree-toggle"])
        collapse(outer, in: app)
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        capture(app, "Seeded nested note returns to Files root")

        expand(outer, in: app)
        expand(inner, in: app)
        let islandPoint = island.coordinate(
            withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)
        ).screenPoint
        collapse(inner, in: app)
        let innerPoint = inner.coordinate(
            withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)
        ).screenPoint
        collapse(outer, in: app)
        let outerPoint = outer.coordinate(
            withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)
        ).screenPoint
        #if os(macOS)
        activate(title(of: note, in: app))
        assertSelection([note], in: app)
        #endif
        let sourcePoint = note.coordinate(
            withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)
        ).screenPoint
        capture(app, "Seeded continuous hover begins with both folders closed")
        try NotebookContinuousDrag.perform(
            from: sourcePoint, hoveringOver: [outerPoint, innerPoint], to: islandPoint
        )
        XCTAssertEqual(disclosure(for: outer, in: app).value as? String, "Expanded")
        XCTAssertEqual(disclosure(for: inner, in: app).value as? String, "Expanded")
        expand(island, in: app)
        assertOrder([outer, inner, island, note], in: app)
        capture(app, "Seeded continuous held drag reaches Island")
        collapse(island, in: app)
        XCTAssertTrue(note.waitForNonExistence(timeout: 5))
        app.terminate()
        app.launch()
        showSidebar(app)
        expand(outer, in: app)
        expand(inner, in: app)
        expand(island, in: app)
        activate(title(of: note, in: app))
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String,
                       "# Fictional voyage\n\nSample checklist.\n")
        capture(app, "Seeded nested move persists with literal source intact")
    }

    func testExpandedFolderEdgesReorderRootWithoutMovingIntoSubtree() throws {
        let app = launchNotebook(nestedFixture: true)
        let note = row(named: "Voyage checklist", prefix: "notebook-sidebar-note-", in: app)
        let outer = row(named: "Journeys", prefix: "notebook-sidebar-folder-", in: app)
        expand(outer, in: app)
        let inner = row(named: "Weekend", prefix: "notebook-sidebar-folder-", in: app)
        expand(inner, in: app)
        let island = row(named: "Island", prefix: "notebook-sidebar-folder-", in: app)
        expand(island, in: app)

        // The fixture creates the root note first. Move it after the tree
        // so both subsequent edge drags must change its position.
        drag(note, to: outer, at: 0.95)
        assertOrder([outer, inner, island, note], in: app)
        drag(note, to: outer, at: 0.05)
        assertOrder([note, outer, inner, island], in: app)
        capture(app, "Expanded folder top edge places note before subtree")
        drag(note, to: outer, at: 0.95)
        assertOrder([outer, inner, island, note], in: app)
        collapse(outer, in: app)
        XCTAssertTrue(note.waitForExistence(timeout: 5), "Bottom edge keeps the note at Files root")
        XCTAssertTrue(inner.waitForNonExistence(timeout: 5))
        XCTAssertTrue(island.waitForNonExistence(timeout: 5))
        capture(app, "Expanded folder bottom edge keeps note outside subtree")

        app.terminate()
        app.launch()
        showSidebar(app)
        expand(outer, in: app)
        expand(inner, in: app)
        expand(island, in: app)
        assertOrder([outer, inner, island, note], in: app)
        collapse(outer, in: app)
        XCTAssertTrue(note.waitForExistence(timeout: 5), "Relaunch preserves Files root membership")
        XCTAssertTrue(inner.waitForNonExistence(timeout: 5))
        XCTAssertTrue(island.waitForNonExistence(timeout: 5))
        activate(title(of: note, in: app))
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String,
                       "# Fictional voyage\n\nSample checklist.\n")
        capture(app, "Expanded subtree edge placement persists with source intact")
    }

    func testFixtureReordersThreeVisibleNotes() throws {
        let app = launchNotebook(fixture: true)
        let first = row(named: "01 Field observation", prefix: "notebook-sidebar-note-", in: app)
        let second = row(named: "02 Field observation", prefix: "notebook-sidebar-note-", in: app)
        let third = row(named: "03 Field observation", prefix: "notebook-sidebar-note-", in: app)
        assertOrder([first, second, third], in: app)
        capture(app, "Fixture before native reorder")
        drag(third, to: first, at: 0.1)
        assertOrder([third, first, second], in: app)
        capture(app, "Fixture after native reorder")
        activate(appMenu(in: app))
        let undo = app.descendants(matching: .any)["notebook-browser-undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        activate(undo)
        assertOrder([first, second, third], in: app)
        capture(app, "Undo Move restores the original order")
        activate(appMenu(in: app))
        let redo = app.descendants(matching: .any)["notebook-browser-redo"]
        XCTAssertTrue(redo.waitForExistence(timeout: 5))
        activate(redo)
        assertOrder([third, first, second], in: app)
        capture(app, "Redo Move restores the native drag placement")
    }

    func testLongListDragAutoscrollsAndPersists() throws {
        let app = launchNotebook(fixture: true)
        let first = row(named: "01 Field observation", prefix: "notebook-sidebar-note-", in: app)
        // Cache identity while the source is realized. iOS virtualizes it
        // when the placement inspection scrolls back to the beginning.
        let sourceTitleID = "notebook-sidebar-title-" + itemID(first)
        let scrollWitness = row(named: "02 Field observation", prefix: "notebook-sidebar-note-", in: app)
        #if os(macOS)
        activate(title(of: first, in: app))
        assertSelection([first], in: app)
        #endif
        let witnessStartY = scrollWitness.frame.minY
        let minimumScroll = scrollWitness.frame.height * 3
        let list = browserList(containing: first, in: app)
        let before = visibleNoteIDs(in: list, app: app)
        XCTAssertGreaterThan(before.count, 2)
        #if os(macOS)
        XCTAssertTrue(scrollWitness.isHittable)
        XCTAssertTrue(list.frame.contains(CGPoint(
            x: scrollWitness.frame.midX, y: scrollWitness.frame.midY
        )))
        #endif
        capture(app, "Long list before edge drag")
        let start = first.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5))
        #if os(macOS)
        let edgeY = list.frame.maxY - 12
        #else
        // iPhone places New Item at the bottom; iPad places it at the top.
        // Anchor the iPad edge in the gap between its floating footer buttons.
        let newItem = app.descendants(matching: .any)
            .matching(identifier: "notebook-new-item").firstMatch
        let footer = app.buttons["notebook-trash-toggle"]
        let edgeY: CGFloat
        if newItem.frame.minY > list.frame.midY {
            edgeY = min(list.frame.maxY, newItem.frame.minY - 24) - 12
        } else {
            XCTAssertTrue(footer.exists && footer.isHittable,
                          "The native iPad footer must be visible before edge dragging")
            edgeY = min(list.frame.maxY - 12, footer.frame.maxY)
        }
        let geometry = XCTAttachment(string:
            "list=\(list.frame) newItem=\(newItem.frame) "
                + "footer=\(footer.exists ? String(describing: footer.frame) : "absent") "
                + "edgeY=\(edgeY)")
        geometry.name = "Visible footer geometry before native edge drag"
        geometry.lifetime = .keepAlways
        add(geometry)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Fictional notebook hierarchy before native edge drag"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        #endif
        let edge = list.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: list.frame.width * 0.6,
                                 dy: edgeY - list.frame.minY))
        #if os(macOS)
        start.click(forDuration: 0.15, thenDragTo: edge, withVelocity: .slow, thenHoldForDuration: 3)
        #else
        start.press(forDuration: 0.6, thenDragTo: edge, withVelocity: .slow, thenHoldForDuration: 3)
        #endif
        #if os(macOS)
        capture(app, "Long list immediately after edge release")
        let sourceID = first.identifier
        let witnessID = scrollWitness.identifier
        let viewport = list.frame
        #endif
        let scrolled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            #if os(macOS)
            guard let observation = self.macBrowserObservation(in: app, viewport: viewport)
            else { return false }
            if let frame = observation.titles[witnessID]?.frame,
               frame.minY < witnessStartY - minimumScroll {
                return true
            }
            // The fixture contains 01...48 in their original order. 01 is
            // the moved source; an unchanged 05 or later at the top proves
            // scrolling at least three rows beyond the original witness 02,
            // even when it has passed every initially visible row.
            guard let top = observation.visible.first(where: { $0.id != sourceID }),
                  let ordinal = Int(top.name.prefix(2)), (5...48).contains(ordinal),
                  top.name == String(format: "%02d Field observation", ordinal)
            else { return false }
            return !observation.visible.contains(where: { $0.id == witnessID })
            #else
            return !scrollWitness.exists
                || scrollWitness.frame.minY < witnessStartY - minimumScroll
            #endif
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [scrolled], timeout: 5), .completed,
                       "Edge holding must move an unchanged row by three row heights, or virtualize it")
        capture(app, "Long list after edge autoscroll and drop")
        #if os(macOS)
        assertSelection([first], in: app)
        #endif
        // Record the placement produced by this actual held-edge gesture.
        // Its destination depends on the viewport, so use the native Move
        // sheet's current location and immediate sibling IDs as oracles.
        let droppedParent = currentParentPath(sourceTitleID: sourceTitleID, in: app)
        let droppedOrder = try edgeDropNeighbors(sourceTitleID: sourceTitleID, parent: droppedParent, in: app)
        app.terminate()
        app.launch()
        showSidebar(app)
        let relaunchedParent = currentParentPath(sourceTitleID: sourceTitleID, in: app)
        XCTAssertEqual(relaunchedParent, droppedParent,
                       "Relaunch must preserve the edge drop's exact parent path")
        XCTAssertEqual(try edgeDropNeighbors(sourceTitleID: sourceTitleID, parent: relaunchedParent, in: app),
                       droppedOrder,
                       "Relaunch must preserve the edge drop's immediate sibling identities and order")
        scrollBrowserToStart(in: app)
        let second = row(named: "02 Field observation", prefix: "notebook-sidebar-note-", in: app)
        let third = row(named: "03 Field observation", prefix: "notebook-sidebar-note-", in: app)
        assertOrder([second, third], in: app)
        let rootNotes = visibleNoteIDs(in: browserList(containing: second, in: app), app: app)
        XCTAssertEqual(rootNotes.first, second.identifier,
                       "Persisted manual order must start with 02 after moving 01 down")
        capture(app, "Autoscrolled manual placement persists after relaunch")
        // The original row is virtualized after the long move. Locate its
        // title by name before reading that row's accessibility identifier.
        let movedTitle = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND (label == %@ OR value == %@)",
            "notebook-sidebar-title-", "01 Field observation", "01 Field observation"
        )).firstMatch
        scrollDown(until: movedTitle, in: app)
        XCTAssertTrue(first.exists, "The dropped note must remain in the notebook")
        activate(movedTitle)
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String,
                       "# Fictional observation 1\n\nSample voyage notes.\n")
        capture(app, "Edge drag preserves the literal source after relaunch")
    }

    func testSelectedNotesDragTogetherAndKeepTheirSource() throws {
        let app = launchNotebook(fixture: true)
        let folder = createFolder("00 Inbox", rootSortBeforeLookup: "Name, A–Z", in: app)
        scrollToTop(until: title(of: folder, in: app), in: app)
        let first = row(named: "01 Field observation", prefix: "notebook-sidebar-note-", in: app)
        let second = row(named: "02 Field observation", prefix: "notebook-sidebar-note-", in: app)
        let third = row(named: "03 Field observation", prefix: "notebook-sidebar-note-", in: app)
        #if os(iOS)
        activate(appMenu(in: app))
        activate(app.descendants(matching: .any)["notebook-select-items"])
        #endif
        activate(title(of: first, in: app))
        #if os(macOS)
        let secondTitle = title(of: second, in: app)
        XCUIElement.perform(withKeyModifiers: .command) {
            secondTitle.click()
        }
        #else
        activate(title(of: second, in: app))
        #endif
        assertSelection([first, second], in: app)
        capture(app, "Two fictional notes selected before batch drag")
        drag(first, to: folder, hold: 1.5, preservingSelection: true)
        expand(folder, in: app)
        #if os(macOS)
        assertSelection([first, second], in: app)
        #endif
        assertOrder([folder, first, second, third], in: app)
        collapse(folder, in: app)
        XCTAssertTrue(first.waitForNonExistence(timeout: 5))
        XCTAssertFalse(second.exists)
        XCTAssertTrue(third.exists)
        capture(app, "Both selected notes moved and other notes stayed")
        let done = app.descendants(matching: .any)["notebook-selection-done"]
        if done.exists { activate(done) }
        app.terminate()
        app.launch()
        showSidebar(app)
        expand(folder, in: app)
        assertOrder([folder, first, second, third], in: app)
        collapse(folder, in: app)
        XCTAssertTrue(first.waitForNonExistence(timeout: 5))
        XCTAssertFalse(second.exists)
        XCTAssertTrue(third.exists)
        expand(folder, in: app)
        activate(title(of: first, in: app))
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String,
                       "# Fictional observation 1\n\nSample voyage notes.\n")
        showSidebar(app)
        activate(title(of: second, in: app))
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String,
                       "# Fictional observation 2\n\nSample voyage notes.\n")
        capture(app, "Batch drag preserves literal note sources")
    }

    private func currentParentPath(
        sourceTitleID: String, in app: XCUIApplication
    ) -> String {
        let environment = app.launchEnvironment
        guard let run = environment["MEH_NOTEBOOK_PREVIEW_RUN"],
              ownedPreviewRuns.contains(run), UUID(uuidString: run) != nil,
              environment["MEH_NOTEBOOK_PREVIEW"] == "1",
              environment["MEH_NOTEBOOK_DRAG_FIXTURE"] == "long-list",
              environment["MEH_SYNC_CLOUDKIT"] == "0",
              environment["MEH_SYNC_AUTOMATIC"] == "0" else {
            XCTFail("Placement inspection requires this test's UUID-owned fixture")
            return ""
        }
        scrollBrowserToStart(in: app)
        scrollDown(until: app.staticTexts[sourceTitleID], in: app)
        let sourceRowID = sourceTitleID.replacingOccurrences(
            of: "notebook-sidebar-title-", with: "notebook-sidebar-note-"
        )
        let source = app.descendants(matching: .any)[sourceRowID]
        XCTAssertTrue(source.exists,
                      "The cached source identity must resolve after native scrolling")
        openContextMenu(on: source, in: app)
        activate(menuAction("Move…", in: app))
        let location = app.descendants(matching: .any)
            .matching(identifier: "notebook-move-path").firstMatch
        XCTAssertTrue(location.waitForExistence(timeout: 5))
        // The production sheet initializes this path from the selected note's
        // parent placement. Cancel without choosing or submitting a move.
        let allowedPaths = [
            "Notebook", "Notebook / Journeys", "Notebook / Journeys / Weekend"
        ]
        // SwiftUI Label may expose the path on its combined element or its
        // text child, depending on the platform's native accessibility bridge.
        let labels = [location.label, location.value as? String ?? ""]
            + location.staticTexts.allElementsBoundByIndex.flatMap {
                [$0.label, $0.value as? String ?? ""]
            }
        let path = labels.first(where: { allowedPaths.contains($0) }) ?? ""
        XCTAssertFalse(path.isEmpty,
                       "The edge drop must have a real fictional fixture parent")
        activate(app.buttons["notebook-cancel-move"])
        XCTAssertTrue(location.waitForNonExistence(timeout: 5))
        return path
    }

    private struct EdgeDropNeighbors: Equatable {
        let previousID: String?
        let sourceID: String
        let nextID: String?
    }

    private func edgeDropNeighbors(
        sourceTitleID: String, parent: String, in app: XCUIApplication
    ) throws -> EdgeDropNeighbors {
        let environment = app.launchEnvironment
        let run = try XCTUnwrap(environment["MEH_NOTEBOOK_PREVIEW_RUN"])
        XCTAssertTrue(ownedPreviewRuns.contains(run))
        XCTAssertNotNil(UUID(uuidString: run))
        XCTAssertEqual(environment["MEH_NOTEBOOK_PREVIEW"], "1")
        XCTAssertEqual(environment["MEH_NOTEBOOK_DRAG_FIXTURE"], "long-list")
        XCTAssertEqual(environment["MEH_SYNC_CLOUDKIT"], "0")
        XCTAssertEqual(environment["MEH_SYNC_AUTOMATIC"], "0")

        // The fixture has exactly one movable source. All other parents and
        // their original order are fixed. Filter by that known membership,
        // rather than treating arbitrary neighboring tree rows as siblings.
        let sourceName = "01 Field observation"
        let siblingNames: Set<String>
        switch parent {
        case "Notebook":
            siblingNames = Set((2...48).map {
                String(format: "%02d Field observation", $0)
            } + ["Journeys", sourceName])
        case "Notebook / Journeys":
            siblingNames = ["Weekend", sourceName]
        case "Notebook / Journeys / Weekend":
            siblingNames = ["Island", sourceName]
        default:
            XCTFail("Unexpected edge-drop parent")
            return EdgeDropNeighbors(previousID: nil, sourceID: "", nextID: nil)
        }
        #if os(macOS)
        let viewport = macSidebar(in: app).frame
        #else
        let viewport = app.collectionViews.firstMatch.frame
        #endif
        var pending: [any XCUIElementSnapshot] = [try app.snapshot()]
        var rowIDs = Set<String>()
        var visibleTop = viewport.minY
        var siblings: [(id: String, name: String, frame: CGRect)] = []
        while let element = pending.popLast() {
            pending.append(contentsOf: element.children)
            if element.identifier.hasPrefix("notebook-sidebar-note-")
                || element.identifier.hasPrefix("notebook-sidebar-folder-") {
                rowIDs.insert(element.identifier)
            }
            if element.identifier == "notebook-tree-toggle", !element.frame.isEmpty {
                visibleTop = max(visibleTop, element.frame.maxY)
            }
            let frame = element.frame
            guard element.elementType == .staticText,
                  element.identifier.hasPrefix("notebook-sidebar-title-"),
                  !frame.isEmpty,
                  frame.minX.isFinite, frame.minY.isFinite,
                  frame.maxX.isFinite, frame.maxY.isFinite else { continue }
            let name = (element.value as? String)
                .flatMap { $0.isEmpty ? nil : $0 } ?? element.label
            if siblingNames.contains(name) {
                siblings.append((element.identifier, name, element.frame))
            }
        }
        // Match the browser observation's viewport rules: detached titles,
        // offscreen virtualized cells and rows behind the Files header cannot
        // serve as neighbor witnesses. Missing visible witnesses fail closed.
        siblings = siblings.filter {
            let suffix = $0.id.replacingOccurrences(of: "notebook-sidebar-title-", with: "")
            let hasRow = rowIDs.contains("notebook-sidebar-note-" + suffix)
                || rowIDs.contains("notebook-sidebar-folder-" + suffix)
            return hasRow && $0.frame.midY >= visibleTop
                && viewport.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY))
        }
        XCTAssertEqual(Set(siblings.map(\.id)).count, siblings.count,
                       "A reused native row must not produce duplicate visible title witnesses")
        siblings.sort { $0.frame.minY < $1.frame.minY }
        let sourceID = sourceTitleID
        let index = try XCTUnwrap(siblings.firstIndex(where: { $0.id == sourceID }),
                                 "The native placement snapshot must contain the stable source ID")
        let previous = index > 0 ? siblings[index - 1] : nil
        let next = index + 1 < siblings.count ? siblings[index + 1] : nil
        if parent == "Notebook" {
            // 02 and Journeys are the fixed first/last root siblings. Any
            // missing neighbor must be a proven boundary, not virtualization.
            XCTAssertTrue(previous != nil || next?.name == "02 Field observation",
                          "An interior root drop needs its immediate preceding sibling")
            XCTAssertTrue(next != nil || previous?.name == "Journeys",
                          "An interior root drop needs its immediate following sibling")
            XCTAssertNotNil(previous,
                            "The edge gesture must move 01 away from its original first position")
            if let previous, let next {
                let originalPeers = (2...48).map {
                    String(format: "%02d Field observation", $0)
                } + ["Journeys"]
                let previousIndex = try XCTUnwrap(originalPeers.firstIndex(of: previous.name))
                let nextIndex = try XCTUnwrap(originalPeers.firstIndex(of: next.name))
                XCTAssertEqual(nextIndex, previousIndex + 1,
                               "Neighbor witnesses must be adjacent original peers, with no virtualized gap")
            }
        } else {
            XCTAssertEqual(Set(siblings.map(\.name)), siblingNames,
                           "A folder placement must expose its complete two-item sibling order")
        }
        let placement = EdgeDropNeighbors(previousID: previous?.id,
                                          sourceID: sourceID, nextID: next?.id)
        let attachment = XCTAttachment(string:
            "parent=\(parent) previous=\(placement.previousID ?? "none") "
                + "source=\(sourceID) next=\(placement.nextID ?? "none")")
        attachment.name = "Native edge-drop parent and immediate siblings"
        attachment.lifetime = .keepAlways
        add(attachment)
        return placement
    }

    private func launchNotebook(fixture: Bool = false, nestedFixture: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        let previewRun = UUID().uuidString
        ownedPreviewRuns.insert(previewRun)
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = previewRun
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchEnvironment["MEH_SYNC_CLOUDKIT"] = "0"
        XCTAssertFalse(fixture && nestedFixture)
        if fixture { app.launchEnvironment["MEH_NOTEBOOK_DRAG_FIXTURE"] = "long-list" }
        if nestedFixture { app.launchEnvironment["MEH_NOTEBOOK_DRAG_FIXTURE"] = "nested" }
        app.launchArguments += ["-editor.mode", "source"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "notebook-new-item").firstMatch.waitForExistence(timeout: 15))
        showSidebar(app)
        return app
    }

    private func createNote(_ name: String, in app: XCUIApplication) -> XCUIElement {
        #if os(macOS)
        let file = app.menuBars.menuBarItems["File"]
        XCTAssertTrue(file.waitForExistence(timeout: 5))
        activate(file)
        activate(menuAction("New Note", in: app))
        #else
        activate(app.descendants(matching: .any).matching(identifier: "notebook-new-item").firstMatch)
        #endif
        #if os(macOS)
        // The title is visibly selected after New Note, but its SwiftUI host
        // inside the native editor does not expose a separate AX TextField.
        XCTAssertTrue(app.textViews["markdown-editor"].waitForExistence(timeout: 5))
        app.typeKey("a", modifierFlags: .command)
        app.typeText(name)
        app.typeKey(.return, modifierFlags: [])
        #else
        let field = app.textFields["title-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        replace(field, with: name)
        #endif
        showSidebar(app)
        return row(named: name, prefix: "notebook-sidebar-note-", in: app)
    }

    private func createFolder(
        _ name: String, inside parent: XCUIElement? = nil,
        rootSortBeforeLookup: String? = nil,
        in app: XCUIApplication
    ) -> XCUIElement {
        if let parent { openContextMenu(on: parent, in: app) }
        else {
            #if os(macOS)
            // Creating notes/folders can retain several native selections.
            // Root creation belongs to the ordinary browser menu.
            if let visibleTitle = app.staticTexts.matching(NSPredicate(
                format: "identifier BEGINSWITH %@", "notebook-sidebar-title-"
            )).allElementsBoundByIndex.first(where: { $0.isHittable }) {
                activate(visibleTitle)
            }
            #endif
            activate(appMenu(in: app))
        }
        activate(menuAction("New Folder", in: app))
        let field = app.textFields["Name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        #if os(macOS)
        let selected = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND isSelected == YES",
            "notebook-sidebar-title-"
        ))
        XCTAssertLessThanOrEqual(selected.count, 1,
                                 "Naming a new folder must not select unrelated files")
        // Use the focus and default-name selection supplied by the app,
        // as ordinary typing does when New Folder opens its inline field.
        app.typeText(name)
        app.typeKey(.return, modifierFlags: [])
        #else
        replace(field, with: name)
        #endif
        if let parent { expand(parent, in: app) }
        if let rootSortBeforeLookup {
            #if os(macOS)
            // Submitting an inline folder name can retain the prior selection.
            // Select the new folder once before opening the normal sort menu.
            let createdTitle = app.staticTexts.matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND (label == %@ OR value == %@)",
                "notebook-sidebar-title-", name, name
            )).firstMatch
            XCTAssertTrue(createdTitle.waitForExistence(timeout: 5))
            if !createdTitle.isHittable { scrollDown(until: createdTitle, in: app) }
            XCTAssertTrue(createdTitle.isHittable)
            activate(createdTitle)
            let createdFolder = row(
                named: name, prefix: "notebook-sidebar-folder-", in: app
            )
            assertSelection([createdFolder], in: app)
            #endif
            chooseSort(rootSortBeforeLookup, in: app)
            scrollBrowserToStart(in: app)
        }
        return row(named: name, prefix: "notebook-sidebar-folder-", in: app)
    }

    private func replace(_ field: XCUIElement, with name: String) {
        activate(field)
        #if os(macOS)
        field.typeKey("a", modifierFlags: .command)
        field.typeText(name)
        field.typeKey(.return, modifierFlags: [])
        #else
        let previous = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count) + name + "\n")
        #endif
    }

    private func row(
        named name: String, prefix: String, in app: XCUIApplication
    ) -> XCUIElement {
        let label = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND (label == %@ OR value == %@)",
            "notebook-sidebar-title-", name, name
        )).firstMatch
        XCTAssertTrue(label.waitForExistence(timeout: 5))
        let id = label.identifier.replacingOccurrences(of: "notebook-sidebar-title-", with: "")
        let result = app.descendants(matching: .any)[prefix + id]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        return result
    }

    private func itemID(_ row: XCUIElement) -> String {
        row.identifier.replacingOccurrences(of: "notebook-sidebar-note-", with: "")
            .replacingOccurrences(of: "notebook-sidebar-folder-", with: "")
    }

    private func title(of row: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts["notebook-sidebar-title-" + itemID(row)]
    }

    private func disclosure(for row: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["notebook-disclosure-" + itemID(row)]
    }

    private func expand(_ row: XCUIElement, in app: XCUIApplication) {
        let button = disclosure(for: row, in: app)
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        if button.value as? String == "Collapsed" {
            #if os(macOS)
            toggleDisclosure(of: row, to: "Expanded", in: app)
            #else
            activate(button)
            #endif
        }
    }

    private func collapse(_ row: XCUIElement, in app: XCUIApplication) {
        let button = disclosure(for: row, in: app)
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        if button.value as? String == "Expanded" {
            #if os(macOS)
            toggleDisclosure(of: row, to: "Collapsed", in: app)
            #else
            activate(button)
            #endif
        }
    }

    #if os(macOS)
    private func toggleDisclosure(
        of row: XCUIElement, to value: String, in app: XCUIApplication
    ) {
        activate(disclosure(for: row, in: app))
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.disclosure(for: row, in: app).value as? String == value
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed,
                       "One native disclosure click must toggle the folder")
    }
    #endif

    private func drag(
        _ source: XCUIElement, to destination: XCUIElement,
        at fraction: CGFloat = 0.5, hold: TimeInterval = 0.3,
        preservingSelection: Bool = false
    ) {
        XCTAssertTrue(source.exists)
        XCTAssertTrue(destination.exists)
        XCTAssertFalse(source.frame.isEmpty)
        XCTAssertFalse(destination.frame.isEmpty)
        #if os(macOS)
        let app = XCUIApplication()
        revealMacDragSource(source, in: app)
        // A normal click replaces any selection retained by earlier actions.
        // Only the deliberate batch drag preserves a Command-click selection.
        if !preservingSelection {
            activate(title(of: source, in: app))
            assertSelection([source], in: app)
        }
        #endif
        // Coordinates come directly from accessibility row bounds. Drag from
        // the text area, away from disclosure buttons, and target the row edge
        // for sibling ordering or its centre for a folder destination.
        let start = source.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5))
        let end = destination.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: fraction))
        #if os(macOS)
        start.click(forDuration: 0.15, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: hold)
        #else
        start.press(forDuration: 0.6, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: hold)
        #endif
        #if os(macOS)
        if !preservingSelection { assertSelection([source], in: XCUIApplication()) }
        #endif
    }

    #if os(macOS)
    private func revealMacDragSource(_ source: XCUIElement, in app: XCUIApplication) {
        // AX can report a partially visible row as hittable while its chosen
        // midpoint is covered by the pinned Files header. Reveal the whole
        // source using ordinary scrolling before clicking or holding it.
        let list = macSidebar(in: app)
        for _ in 0..<8 {
            let frame = source.frame
            let viewport = list.frame
            let header = app.buttons["notebook-tree-toggle"].frame
            let top = max(viewport.minY, header.maxY)
            if !frame.isEmpty, frame.minY >= top, frame.maxY <= viewport.maxY,
               source.isHittable { return }
            scrollMacBrowser(list, by: frame.minY < top ? 300 : -300, in: app)
        }
        XCTFail("The drag source must be fully visible after bounded scrolling")
    }

    private func macSidebar(in app: XCUIApplication) -> XCUIElement {
        app.scrollViews.allElementsBoundByIndex.first {
            $0.frame.minX < app.windows.firstMatch.frame.midX && $0.frame.height > 100
        } ?? app.scrollViews.firstMatch
    }

    private func scrollMacBrowser(
        _ list: XCUIElement, by delta: Int32, in app: XCUIApplication
    ) {
        list.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5))
            .scroll(byDeltaX: 0, deltaY: CGFloat(delta))
    }

    private func focusMacSidebarForNavigation(in app: XCUIApplication) {
        // Native Home/Page Down scrolling follows the first responder.
        // This preparation precedes the deliberate source/batch selection.
        let environment = app.launchEnvironment
        guard let run = environment["MEH_NOTEBOOK_PREVIEW_RUN"],
              ownedPreviewRuns.contains(run),
              environment["MEH_NOTEBOOK_PREVIEW"] == "1",
              environment["MEH_SYNC_CLOUDKIT"] == "0",
              environment["MEH_SYNC_AUTOMATIC"] == "0" else {
            XCTFail("Sidebar navigation requires this test's preview notebook")
            return
        }
        app.activate()
        let viewport = macSidebar(in: app).frame
        guard let observation = macBrowserObservation(in: app, viewport: viewport),
              let visible = observation.visible.first(where: {
                  $0.frame.minY >= observation.visibleTop + 2
                      && $0.frame.maxY <= viewport.maxY - 48
              }) else {
            XCTFail("Native sidebar navigation needs a visible fictional note")
            return
        }
        let titleID = visible.id.replacingOccurrences(
            of: "notebook-sidebar-note-", with: "notebook-sidebar-title-"
        )
        activate(app.staticTexts[titleID])
    }
    #endif

    private func openContextMenu(on row: XCUIElement, in app: XCUIApplication) {
        #if os(macOS)
        activate(title(of: row, in: app))
        assertSelection([row], in: app)
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)).rightClick()
        #else
        if app.descendants(matching: .any)["notebook-trash-view"].exists {
            row.press(forDuration: 1.0)
        } else {
            title(of: row, in: app).press(forDuration: 1.0)
        }
        #endif
    }

    private func menuAction(_ name: String, in app: XCUIApplication) -> XCUIElement {
        #if os(macOS)
        let action = app.menuItems[name]
        #else
        let action = app.buttons[name]
        #endif
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        return action
    }

    private func chooseSort(_ name: String, in app: XCUIApplication) {
        #if os(macOS)
        capture(app, "Before native Files sort menu opens")
        #endif
        activate(appMenu(in: app))
        #if os(macOS)
        capture(app, "Native Files sort menu after opening")
        let diagnostic = XCTAttachment(string:
            "appState=\(app.state.rawValue) "
                + "windowEnabled=\(app.windows.firstMatch.isEnabled) "
                + "buttonEnabled=\(appMenu(in: app).isEnabled) "
                + "buttonFrame=\(appMenu(in: app).frame) "
                + "sortIDExists=\(app.menuItems["notebook-sort-root"].exists) "
                + "sortLabelExists=\(app.menuItems["Sort Files Once"].exists) "
                + "newFolderExists=\(app.menuItems["New Folder"].exists)")
        diagnostic.name = "Native Files sort menu availability"
        diagnostic.lifetime = .keepAlways
        add(diagnostic)
        let submenu = app.menuItems["notebook-sort-root"]
        XCTAssertTrue(submenu.waitForExistence(timeout: 5))
        submenu.hover()
        let option = menuAction(name, in: app)
        // Native AX menu clicks can repeat their own hover after finding a
        // submenu item. Use its current visible coordinates for one click.
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard option.exists else { return false }
            let frame = option.frame
            return !frame.isEmpty && frame.minX.isFinite && frame.minY.isFinite
                && frame.maxX.isFinite && frame.maxY.isFinite
        }, object: option)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed,
                       "The native sort submenu item must become visible")
        let frame = option.frame
        let window = app.windows.firstMatch
        let origin = window.frame.origin
        window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: frame.midX - origin.x, dy: frame.midY - origin.y
        )).click()
        XCTAssertTrue(option.waitForNonExistence(timeout: 5),
                      "Choosing a sort order must dismiss the native menu")
        #else
        activate(app.descendants(matching: .any)["notebook-sort-root"])
        activate(menuAction(name, in: app))
        #endif
    }

    private func appMenu(in app: XCUIApplication) -> XCUIElement {
        #if os(macOS)
        app.menuButtons["notebook-app-menu"]
        #else
        app.buttons["notebook-app-menu"]
        #endif
    }

    private func showSidebar(_ app: XCUIApplication) {
        let files = app.buttons["notebook-tree-toggle"]
        #if os(iOS)
        if !files.isHittable { app.navigationBars.buttons.firstMatch.tap() }
        #endif
        XCTAssertTrue(files.waitForExistence(timeout: 5))
        let recents = app.buttons["notebook-recents-toggle"]
        if recents.value as? String == "Expanded" { activate(recents) }
        if files.value as? String == "Collapsed" { activate(files) }
    }

    private func browserList(containing row: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        #if os(macOS)
        let list = app.scrollViews.allElementsBoundByIndex.first {
            $0.frame.height > 100 && $0.frame.contains(row.frame)
        }
        XCTAssertNotNil(list)
        return list ?? app.scrollViews.firstMatch
        #else
        return app.collectionViews.firstMatch
        #endif
    }

    #if os(macOS)
    private struct MacNoteTitle {
        let id: String
        let name: String
        let frame: CGRect
    }

    private struct MacBrowserObservation {
        let visibleTop: CGFloat
        let titles: [String: MacNoteTitle]
        let visible: [MacNoteTitle]
    }

    private func macBrowserObservation(
        in app: XCUIApplication, viewport: CGRect
    ) -> MacBrowserObservation? {
        // Resolve native virtualized rows once. Indexed live queries can
        // resolve different reused rows, and exceed a short predicate wait.
        guard let root = try? app.snapshot() else { return nil }
        return macBrowserObservation(snapshot: root, viewport: viewport)
    }

    private func macBrowserObservation(
        snapshot root: any XCUIElementSnapshot, viewport: CGRect
    ) -> MacBrowserObservation {
        var pending: [any XCUIElementSnapshot] = [root]
        var noteIDs = Set<String>()
        var titles: [String: MacNoteTitle] = [:]
        var visibleTop = viewport.minY
        while let element = pending.popLast() {
            pending.append(contentsOf: element.children)
            let id = element.identifier
            if id.hasPrefix("notebook-sidebar-note-") {
                noteIDs.insert(id)
            }
            if id == "notebook-tree-toggle", !element.frame.isEmpty {
                visibleTop = max(visibleTop, element.frame.maxY)
            }
            guard element.elementType == .staticText,
                  id.hasPrefix("notebook-sidebar-title-") else { continue }
            let frame = element.frame
            guard !frame.isEmpty, frame.minX.isFinite, frame.minY.isFinite,
                  frame.maxX.isFinite, frame.maxY.isFinite else { continue }
            let noteID = id.replacingOccurrences(
                of: "notebook-sidebar-title-", with: "notebook-sidebar-note-"
            )
            let value = element.value as? String
            let name = value.flatMap { $0.isEmpty ? nil : $0 } ?? element.label
            titles[noteID] = MacNoteTitle(id: noteID, name: name, frame: frame)
        }
        let visible = titles.values.filter {
            noteIDs.contains($0.id) && $0.frame.midY >= visibleTop
                && viewport.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY))
        }.sorted { $0.frame.minY < $1.frame.minY }
        return MacBrowserObservation(
            visibleTop: visibleTop, titles: titles, visible: visible
        )
    }
    #endif

    private func visibleNoteIDs(in list: XCUIElement, app: XCUIApplication) -> [String] {
        let viewport = list.frame
        #if os(macOS)
        return macBrowserObservation(in: app, viewport: viewport)?.visible.map(\.id) ?? []
        #else
        return app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "notebook-sidebar-note-"
        )).allElementsBoundByIndex.filter {
            !$0.frame.isEmpty && viewport.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY))
        }.sorted { $0.frame.minY < $1.frame.minY }.map { $0.identifier }
        #endif
    }

    private func scrollToTop(until target: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 {
            if target.exists, target.isHittable { return }
            #if os(macOS)
            scrollMacBrowser(macSidebar(in: app), by: 600, in: app)
            #else
            app.collectionViews.firstMatch.swipeDown(velocity: .slow)
            #endif
        }
        XCTAssertTrue(target.exists, "Expected target after bounded scrolling to the top")
    }

    private func scrollBrowserToStart(in app: XCUIApplication) {
        // A relaunch can restore its scroll offset. Reach the real beginning
        // before comparing root order, including notes virtualized offscreen.
        #if os(macOS)
        focusMacSidebarForNavigation(in: app)
        app.typeKey(.home, modifierFlags: [])
        #else
        for _ in 0..<8 {
            app.collectionViews.firstMatch.swipeDown(velocity: .fast)
        }
        #endif
    }

    private func scrollDown(until target: XCUIElement, in app: XCUIApplication) {
        #if os(macOS)
        focusMacSidebarForNavigation(in: app)
        #endif
        func isRevealed() -> Bool {
            guard target.exists, target.isHittable else { return false }
            #if os(macOS)
            return true
            #else
            // UIKit can hit a sliver of a clipped cell. A placement witness
            // needs the entire title inside the list, including its midpoint.
            let frame = target.frame
            return !frame.isEmpty && app.collectionViews.firstMatch.frame.contains(frame)
            #endif
        }
        for _ in 0..<8 {
            if isRevealed() { return }
            #if os(macOS)
            app.typeKey(.pageDown, modifierFlags: [])
            #else
            app.collectionViews.firstMatch.swipeUp(velocity: .slow)
            #endif
        }
        XCTAssertTrue(isRevealed(), "Expected a fully revealed source after bounded scrolling")
    }

    private func activate(_ element: XCUIElement) {
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }

    private func assertOrder(_ rows: [XCUIElement], in app: XCUIApplication) {
        #if os(macOS)
        // Native List can recycle an AX row between live frame queries.
        // Resolve exact note/folder identities in one coherent snapshot,
        // without spending the predicate's deadline on repeated lookups.
        let expectedIDs = rows.map { $0.identifier }
        let expected = Set(expectedIDs)
        XCTAssertEqual(expected.count, rows.count)
        var observed: [String: CGRect] = [:]
        let order = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let root = try? app.snapshot() else { return false }
            var pending: [any XCUIElementSnapshot] = [root]
            var frames: [String: CGRect] = [:]
            while let element = pending.popLast() {
                pending.append(contentsOf: element.children)
                guard expected.contains(element.identifier) else { continue }
                let frame = element.frame
                guard !frame.isEmpty, frame.minX.isFinite, frame.minY.isFinite,
                      frame.maxX.isFinite, frame.maxY.isFinite else { continue }
                frames[element.identifier] = frame
            }
            observed = frames
            let positions = expectedIDs.compactMap { frames[$0]?.minY }
            guard positions.count == expectedIDs.count else { return false }
            return zip(positions, positions.dropFirst()).allSatisfy { $0.0 < $0.1 }
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [order], timeout: 5), .completed,
                       "Expected row order \(expectedIDs); snapshot frames \(observed)")
        #else
        let order = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard rows.allSatisfy({ $0.exists && !$0.frame.isEmpty }) else { return false }
            let positions = rows.map { $0.frame.minY }
            return zip(positions, positions.dropFirst()).allSatisfy { $0.0 < $0.1 }
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [order], timeout: 5), .completed)
        #endif
    }

    private func assertSelection(_ rows: [XCUIElement], in app: XCUIApplication) {
        #if os(macOS)
        // AppKit exposes selection on native cells and their title children,
        // whereas the identified SwiftUI row group does not inherit it.
        let expected = Set(rows.map { "notebook-sidebar-title-" + itemID($0) })
        let exactSelection = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let selected = app.staticTexts.matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND isSelected == YES",
                "notebook-sidebar-title-"
            )).allElementsBoundByIndex
            return Set(selected.map { $0.identifier }) == expected
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [exactSelection], timeout: 5), .completed)
        #else
        let count = app.descendants(matching: .any)["notebook-selection-count"]
        if count.exists {
            let expected = "\(rows.count) selected"
            XCTAssertTrue(count.label == expected || count.value as? String == expected)
            XCTAssertTrue(rows.allSatisfy { $0.isSelected })
        } else {
            // Narrow iPad sidebars omit the principal count from their toolbar.
            // The native selection checkmarks still expose exact row state.
            let selected = app.images.matching(identifier: "checkmark.circle.fill")
            let exactSelection = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                selected.count == rows.count && rows.allSatisfy { $0.isSelected }
            }, object: app)
            XCTAssertEqual(XCTWaiter.wait(for: [exactSelection], timeout: 5), .completed)
        }
        #endif
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        #if os(macOS)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        #else
        let attachment = XCTAttachment(screenshot: app.screenshot())
        #endif
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
