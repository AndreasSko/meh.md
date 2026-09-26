import Foundation
import XCTest

@testable import NativeEditor

#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class MarkdownTablePresentationTests: XCTestCase {
    private let table = "| Name | Value |\n| :--- | ---: |\n| café | **bright** |\n"

    func testSelectionAnywhereInTableRevealsWholeSourceAndInlineSyntax() throws {
        let source = "Before\n" + table + "\nAfter"
        let parsed = MarkdownSyntax.parse(source)
        let tableRange = try XCTUnwrap(parsed.tables.first?.range)
        let nsSource = source as NSString

        for target in ["Name", ":---", "café", "bright"] {
            let selection = nsSource.range(of: target)
            let hidden = MarkdownLivePreview.hiddenRanges(
                in: source, result: parsed,
                snapshot: MarkdownLivePreviewSnapshot(
                    mode: .livePreview, selection: selection,
                    tableWidth: 480
                )
            )
            XCTAssertTrue(hidden.allSatisfy {
                NSIntersectionRange($0, tableRange).length == 0
            }, "Table syntax remained hidden at \(target)")
        }
    }

    func testInactiveAndNoneditingTableCollapseAsOneSourceRange() throws {
        let source = "Before\n" + table + "\nAfter"
        let parsed = MarkdownSyntax.parse(source)
        let tableRange = try XCTUnwrap(parsed.tables.first?.range)

        for (selection, isEditing) in [
            ((source as NSString).range(of: "Before"), true),
            ((source as NSString).range(of: "bright"), false),
        ] {
            let hidden = MarkdownLivePreview.hiddenRanges(
                in: source, result: parsed,
                snapshot: MarkdownLivePreviewSnapshot(
                    mode: .livePreview, selection: selection,
                    isEditing: isEditing, tableWidth: 480
                )
            )
            XCTAssertTrue(hidden.contains {
                $0.location <= tableRange.location
                    && NSMaxRange($0) >= NSMaxRange(tableRange)
            })
        }
    }

    func testTooNarrowTableKeepsLiteralSourceVisible() throws {
        let source = table + "\nOutside"
        let parsed = MarkdownSyntax.parse(source)
        let tableRange = try XCTUnwrap(parsed.tables.first?.range)
        let hidden = MarkdownLivePreview.hiddenRanges(
            in: source, result: parsed,
            snapshot: MarkdownLivePreviewSnapshot(
                mode: .livePreview,
                selection: (source as NSString).range(of: "Outside"),
                tableWidth: 90
            )
        )
        XCTAssertTrue(hidden.allSatisfy {
            NSIntersectionRange($0, tableRange).length == 0
        })
    }

    func testExtraBodyCellKeepsLiteralSourceVisible() throws {
        let source = "| A | B |\n| --- | --- |\n| one | two | extra |\n\nOutside"
        let parsed = MarkdownSyntax.parse(source)
        let tableRange = try XCTUnwrap(parsed.tables.first?.range)
        let hidden = MarkdownLivePreview.hiddenRanges(
            in: source, result: parsed,
            snapshot: MarkdownLivePreviewSnapshot(
                mode: .livePreview,
                selection: (source as NSString).range(of: "Outside"),
                tableWidth: 400
            )
        )
        XCTAssertTrue(hidden.allSatisfy {
            NSIntersectionRange($0, tableRange).length == 0
        })
    }

    func testSelectionAcrossTablesRevealsBothButLeavesOtherTableRendered() throws {
        let source = table + "\nBetween\n\n" + table
            + "\nBetween again\n\n" + table
        let parsed = MarkdownSyntax.parse(source)
        XCTAssertEqual(parsed.tables.count, 3)
        let first = try XCTUnwrap(parsed.tables.first?.range)
        let second = parsed.tables[1].range
        let third = parsed.tables[2].range
        let selection = NSRange(
            location: first.location + 2,
            length: NSMaxRange(second) - first.location - 2
        )

        let hidden = MarkdownLivePreview.hiddenRanges(
            in: source, result: parsed,
            snapshot: MarkdownLivePreviewSnapshot(
                mode: .livePreview, selection: selection,
                tableWidth: 480
            )
        )
        XCTAssertTrue(hidden.allSatisfy {
            NSIntersectionRange($0, first).length == 0
                && NSIntersectionRange($0, second).length == 0
        })
        XCTAssertTrue(hidden.contains {
            $0.location <= third.location
                && NSMaxRange($0) >= NSMaxRange(third)
        })
    }

    func testLayoutWrapsRowsAndKeepsHeaderAndCellAlignment() throws {
        let source = "| Left | Center | Right |\n"
            + "| :--- | :---: | ---: |\n"
            + "| a long sentence with several words to wrap | middle | end |\n"
        let parsed = MarkdownSyntax.parse(source)
        let hidden = [try XCTUnwrap(parsed.tables.first?.range)]
        let font = MarkdownPresentation.editorBodyFont
        let wide = MarkdownTableLayout.make(
            text: source, result: parsed, hiddenRanges: hidden,
            bodyFont: font, width: 900
        )
        let narrow = MarkdownTableLayout.make(
            text: source, result: parsed, hiddenRanges: hidden,
            bodyFont: font, width: 210
        )

        XCTAssertEqual(wide.rows.count, 2)
        XCTAssertEqual(narrow.rows.count, 2)
        XCTAssertEqual(narrow.delimiters.count, 1)
        XCTAssertGreaterThan(narrow.rows[1].height, wide.rows[1].height)
        XCTAssertTrue(narrow.rows[0].isHeader)
        XCTAssertFalse(narrow.rows[1].isHeader)
        XCTAssertTrue(narrow.rows[1].isLast)
        XCTAssertEqual(narrow.rows[0].cells.count, 3)
        XCTAssertEqual(narrow.rows[0].cells[0].string, "Left")
        XCTAssertEqual(narrow.rows[1].cells[0].string,
                       "a long sentence with several words to wrap")
        for row in narrow.rows {
            for (column, expected) in [
                NSTextAlignment.left, .center, .right,
            ].enumerated() {
                let style = try XCTUnwrap(row.cells[column].attribute(
                    .paragraphStyle, at: 0, effectiveRange: nil
                ) as? NSParagraphStyle)
                XCTAssertEqual(style.alignment, expected)
            }
        }
        let headerFont = try XCTUnwrap(narrow.rows[0].cells[0].attribute(
            .font, at: 0, effectiveRange: nil
        ) as? PlatformFont)
        XCTAssertTrue(isBold(headerFont))
    }

    func testRenderedCellsDecodeEscapesAndInlineStylesWithoutChangingSource() throws {
        let source = "| Label | Detail |\n| --- | --- |\n"
            + "| one\\|two | **bold** and `code` |\n"
        let parsed = MarkdownSyntax.parse(source)
        let layout = MarkdownTableLayout.make(
            text: source, result: parsed,
            hiddenRanges: [try XCTUnwrap(parsed.tables.first?.range)],
            bodyFont: MarkdownPresentation.editorBodyFont, width: 500
        )
        XCTAssertEqual(layout.rows.count, 2)
        XCTAssertEqual(layout.rows[1].cells[0].string, "one|two")
        XCTAssertEqual(layout.rows[1].cells[1].string, "bold and code")
        XCTAssertEqual(
            (source as NSString).substring(with: parsed.tables[0].rows[0].cells[0]),
            "one\\|two"
        )
        let cell = layout.rows[1].cells[1]
        let boldFont = try XCTUnwrap(cell.attribute(
            .font, at: 0, effectiveRange: nil
        ) as? PlatformFont)
        XCTAssertTrue(isBold(boldFont))
        let codeLocation = (cell.string as NSString).range(of: "code").location
        let codeFont = try XCTUnwrap(cell.attribute(
            .font, at: codeLocation, effectiveRange: nil
        ) as? PlatformFont)
        XCTAssertTrue(isMonospaced(codeFont))
    }

    func testTableCacheReusesCellsWhenTrailingProseOrSelectionChanges() throws {
        let source = table + "\nFirst line\nSecond line"
        let cache = MarkdownSyntaxCache()
        let font = MarkdownPresentation.editorBodyFont
        let firstSelection = (source as NSString).range(of: "First line")
        let firstPresentation = cache.presentation(
            for: source,
            snapshot: MarkdownLivePreviewSnapshot(
                mode: .livePreview, selection: firstSelection,
                tableWidth: 500
            )
        )
        XCTAssertNotNil(cache.prepareTables(
            text: source, presentation: firstPresentation,
            bodyFont: font, width: 500
        ))
        let originalCell = try XCTUnwrap(cache.tableLayout?.rows.first?.cells.first)

        let laterSelection = (source as NSString).range(of: "Second line")
        let laterPresentation = cache.presentation(
            for: source,
            snapshot: MarkdownLivePreviewSnapshot(
                mode: .livePreview, selection: laterSelection,
                tableWidth: 500
            )
        )
        XCTAssertNil(cache.prepareTables(
            text: source, presentation: laterPresentation,
            bodyFont: font, width: 500
        ))
        XCTAssertTrue(cache.tableLayout?.rows.first?.cells.first === originalCell)

        let edited = source.replacingOccurrences(
            of: "Second line", with: "Second line revised"
        )
        let editedPresentation = cache.presentation(
            for: edited,
            snapshot: MarkdownLivePreviewSnapshot(
                mode: .livePreview,
                selection: (edited as NSString).range(of: "revised"),
                tableWidth: 500
            )
        )
        XCTAssertNil(cache.prepareTables(
            text: edited, presentation: editedPresentation,
            bodyFont: font, width: 500
        ))
        XCTAssertTrue(cache.tableLayout?.rows.first?.cells.first === originalCell)
    }

    func testEditingFirstTableInvalidatesOnlyThatTable() throws {
        let source = table + "\nSpacer\n\n" + table
        let cache = MarkdownSyntaxCache()
        let font = MarkdownPresentation.editorBodyFont
        let snapshot = MarkdownLivePreviewSnapshot(
            mode: .livePreview,
            selection: (source as NSString).range(of: "Spacer"),
            tableWidth: 500
        )
        let initial = cache.presentation(for: source, snapshot: snapshot)
        XCTAssertEqual(initial.result.tables.count, 2)
        XCTAssertNotNil(cache.prepareTables(
            text: source, presentation: initial,
            bodyFont: font, width: 500
        ))

        let edited = (source as NSString).replacingCharacters(
            in: (source as NSString).range(of: "café"), with: "cafe"
        )
        let revised = cache.presentation(for: edited, snapshot: snapshot)
        XCTAssertEqual(revised.result.tables.count, 2)
        let invalidated = try XCTUnwrap(cache.prepareTables(
            text: edited, presentation: revised,
            bodyFont: font, width: 500
        ))
        XCTAssertEqual(invalidated, revised.result.tables[0].range)
        XCTAssertEqual(
            NSIntersectionRange(invalidated, revised.result.tables[1].range).length,
            0
        )
    }

#if os(macOS)
    func testNativePreviewPreservesSourceSelectionUndoAndRestoresSourceStyle() throws {
        let source = "Before\n" + table + "\nAfter"
        let view = NSTextView(usingTextLayoutManager: true)
        view.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
        view.allowsUndo = true
        view.string = source
        let window = NSWindow(
            contentRect: view.frame, styleMask: .borderless,
            backing: .buffered, defer: false
        )
        window.contentView = view
        XCTAssertTrue(window.makeFirstResponder(view))
        let selection = (source as NSString).range(of: "Before")
        view.setSelectedRange(selection)
        MarkdownPresentation.configure(view, mode: .livePreview)
        view.undoManager?.removeAllActions()

        let cache = MarkdownPresentation.syntaxCache(for: view)
        XCTAssertEqual(cache.tableLayout?.rows.count, 2)
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(view.selectedRange(), selection)
        XCTAssertFalse(view.undoManager?.canUndo == true)
        let headerLocation = (source as NSString).range(of: "Name").location
        let previewStyle = try paragraphStyle(at: headerLocation, in: view)
        XCTAssertGreaterThan(previewStyle.minimumLineHeight, 0)

        MarkdownPresentation.refresh(view, mode: .source)
        let sourceStyle = try paragraphStyle(at: headerLocation, in: view)
        XCTAssertEqual(sourceStyle.minimumLineHeight, 0)
        XCTAssertEqual(sourceStyle.maximumLineHeight, 0)
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(view.selectedRange(), selection)
        XCTAssertFalse(view.undoManager?.canUndo == true)
    }

    func testNativeCacheRebuildsForFontAndWidthChanges() throws {
        let source = table + "\nOutside"
        let view = NSTextView(usingTextLayoutManager: true)
        view.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
        view.textContainer?.containerSize = NSSize(width: 500, height: 400)
        view.string = source
        view.setSelectedRange((source as NSString).range(of: "Outside"))
        MarkdownPresentation.configure(view, mode: .livePreview)
        let cache = MarkdownPresentation.syntaxCache(for: view)
        let first = try XCTUnwrap(cache.tableLayout)

        MarkdownPresentation.refresh(view, fontSize: 24, mode: .livePreview)
        let larger = try XCTUnwrap(cache.tableLayout)
        XCTAssertGreaterThan(larger.rows[0].height, first.rows[0].height)

        view.textContainer?.containerSize = NSSize(width: 170, height: 400)
        MarkdownPresentation.refresh(view, fontSize: 24, mode: .livePreview)
        let narrow = try XCTUnwrap(cache.tableLayout)
        XCTAssertLessThan(narrow.width, larger.width)
        XCTAssertEqual(view.string, source)
    }

    private func paragraphStyle(
        at location: Int, in view: NSTextView
    ) throws -> NSParagraphStyle {
        try XCTUnwrap(view.textStorage?.attribute(
            .paragraphStyle, at: location, effectiveRange: nil
        ) as? NSParagraphStyle)
    }
#endif

    private func isBold(_ font: PlatformFont) -> Bool {
#if os(macOS)
        font.fontDescriptor.symbolicTraits.contains(.bold)
#else
        font.fontDescriptor.symbolicTraits.contains(.traitBold)
#endif
    }

    private func isMonospaced(_ font: PlatformFont) -> Bool {
#if os(macOS)
        font.fontDescriptor.symbolicTraits.contains(.monoSpace)
#else
        font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace)
#endif
    }
}
