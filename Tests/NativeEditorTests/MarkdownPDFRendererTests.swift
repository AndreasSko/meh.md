import PDFKit
import XCTest

@testable import NativeEditor

@MainActor
final class MarkdownPDFRendererTests: XCTestCase {
    func testPDFKeepsNestedListQuoteTextSelectable() throws {
        let source = """
        First short paragraph before the containers.

        * > **Nested quote in a list**
          > A wrapped continuation with `native code`.
        - [ ] An unchecked task
        - [x] A checked task
        """
        let data = try MarkdownPDFRenderer.data(
            text: source,
            title: "Meeting notes",
            fontSize: 17,
            fontFamily: .system
        )
        let document = try XCTUnwrap(PDFDocument(data: data))
        let extracted = try XCTUnwrap(document.string)
        XCTAssertTrue(extracted.contains("Nested quote in a list"))
        XCTAssertTrue(extracted.contains("wrapped continuation"))
        XCTAssertTrue(extracted.contains("An unchecked task"))
        XCTAssertTrue(extracted.contains("A checked task"))
        XCTAssertEqual(document.documentAttributes?[PDFDocumentAttribute.titleAttribute]
                       as? String,
                       "Meeting notes")
    }

    func testTitleSpecialCharactersStayLiteral() throws {
        let data = try MarkdownPDFRenderer.data(
            text: "A plain note body.",
            title: "Release **draft**.md",
            fontSize: 17,
            fontFamily: .system
        )
        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertTrue(try XCTUnwrap(document.string)
            .contains("Release **draft**.md"))
    }

    func testPDFPaginatesLongParagraphsAndTallNotes() throws {
        let paragraph = String(repeating: "A continuous paragraph wraps. ",
                               count: 220)
        let note = (0..<48).map { "Line \($0): \(paragraph)" }
            .joined(separator: "\n\n")
        let data = try MarkdownPDFRenderer.data(
            text: note,
            title: "Long note",
            fontSize: 17,
            fontFamily: .system
        )
        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertGreaterThan(document.pageCount, 1)
        XCTAssertTrue(try XCTUnwrap(document.string).contains("Line 47:"))
    }

    func testWideTableRemainsInPDFText() throws {
        let source = """
        | Name | Description | Status | Owner |
        | --- | --- | --- | --- |
        | North | A full description stays selectable. | Open | Ada |
        | South | Another complete cell. | Closed | Lin |
        """
        let data = try MarkdownPDFRenderer.data(
            text: source,
            title: "Table export",
            fontSize: 17,
            fontFamily: .system
        )
        let document = try XCTUnwrap(PDFDocument(data: data))
        let extracted = try XCTUnwrap(document.string)
        XCTAssertTrue(extracted.contains("North"))
        let normalized = extracted.split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        XCTAssertTrue(normalized.contains("A full description stays selectable."))
        XCTAssertTrue(extracted.contains("South"))
    }

    func testTallTableRowFailsRatherThanExportingClippedText() {
        let longCell = String(repeating: "A wrapped table phrase. ", count: 95)
        let source = """
        | Name | Description | Status |
        | --- | --- | --- |
        | North | \(longCell) FINAL-CELL-TOKEN | Open |
        """
        XCTAssertThrowsError(try MarkdownPDFRenderer.data(
            text: source,
            title: "Table export",
            fontSize: 17,
            fontFamily: .system
        )) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "A table row is too tall to fit on a PDF page and cannot be exported safely."
            )
        }
    }

    func testWritesNativeReviewSample() throws {
        guard let outputPath = ProcessInfo.processInfo.environment[
            "MEH_PDF_REVIEW_OUTPUT"
        ] else { return }
        let text = """
        # Quiet Notes

        An ordinary paragraph with **bold**, _italic_, `code`, and a [link](https://example.com).

        * A list item with a wrapped second line that should keep its indent.
        * > A quote nested within a list, with **emphasis** and enough text to wrap over multiple lines.
        - [ ] An unchecked task
        - [x] A checked task

        > A quiet quote with several lines of readable prose for checking the accent bar and background.

        | Name | Description | Status |
        | --- | --- | --- |
        | North | A longer cell that wraps at the page width and keeps all its content visible. | Open |
        | South | Another row. | Closed |

        \(String(repeating: "A long paragraph should continue onto another page without cutting a line. ", count: 180))
        """
        let data = try MarkdownPDFRenderer.data(
            text: text,
            title: "Release **draft**.md",
            fontSize: 17,
            fontFamily: .system
        )
        try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }

    func testExportUsesEditorFontRunsAndParagraphIndents() throws {
        let source = "* > **Nested quote**\n"
        let result = MarkdownSyntax.parse(source)
        let bodyFont = MarkdownPresentation.bodyFont(for: .serif,
                                                     pointSize: 17)
        let preview = MarkdownLivePreview.ranges(
            in: source,
            result: result,
            snapshot: MarkdownLivePreviewSnapshot(
                mode: .livePreview,
                selection: NSRange(location: 0, length: 0),
                isEditing: false,
                tableWidth: 500,
                fontSize: 17
            )
        )
        let attributed = MarkdownPresentation.exportAttributedString(
            text: source,
            result: result,
            bodyFont: bodyFont,
            previewRanges: preview,
            tableLayout: nil
        )
        let boldRange = (source as NSString).range(of: "Nested quote")
        let run = try XCTUnwrap(result.fontRuns.first {
            NSIntersectionRange($0.range, boldRange).length > 0
        })
        let actualFont = try XCTUnwrap(attributed.attribute(
            .font, at: boldRange.location, effectiveRange: nil
        ) as? PlatformFont)
        XCTAssertEqual(actualFont,
                       MarkdownPresentation.layoutFont(for: run,
                                                       bodyFont: bodyFont))
        let quote = try XCTUnwrap(result.paragraphRuns.first {
            $0.kind == .blockquote
        })
        let style = try XCTUnwrap(attributed.attribute(
            .paragraphStyle, at: quote.range.location, effectiveRange: nil
        ) as? NSParagraphStyle)
        XCTAssertGreaterThan(style.headIndent, 0)
    }
}
