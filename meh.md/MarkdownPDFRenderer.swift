import CoreGraphics
import Foundation

#if os(macOS)
import AppKit
typealias MarkdownPDFColor = NSColor
#else
import UIKit
typealias MarkdownPDFColor = UIColor
#endif

enum MarkdownPDFRenderer {
    enum RenderError: LocalizedError {
        case unableToCreatePDFContext
        case unableToCreateTextLayout
        case noteTooLarge
        case tableCannotFitPage

        var errorDescription: String? {
            switch self {
            case .unableToCreatePDFContext:
                "The PDF could not be created."
            case .unableToCreateTextLayout:
                "The note could not be laid out for PDF export."
            case .noteTooLarge:
                "This note is too large to export as a PDF."
            case .tableCannotFitPage:
                "A table row is too tall to fit on a PDF page and cannot be exported safely."
            }
        }
    }

    private struct Line {
        let fragment: NSTextLayoutFragment
        let textLine: NSTextLineFragment
        let sourceRange: NSRange
        let elementStart: Int
        let rect: CGRect
        let drawingOrigin: CGPoint
        let tableRow: MarkdownTableLayout.Row?
    }

    private struct Page {
        let startY: CGFloat
        var lines: [Line]
    }

    private static let pageSize = CGSize(width: 612, height: 792)
    private static let marginTop: CGFloat = 48
    private static let marginLeft: CGFloat = 52
    private static let marginBottom: CGFloat = 48
    private static let marginRight: CGFloat = 52

    @MainActor
    static func data(
        text: String,
        title: String,
        fontSize: Double,
        fontFamily: EditorFontFamily
    ) throws -> Data {
        guard text.utf8.count <= 4 * 1024 * 1024 else {
            throw RenderError.noteTooLarge
        }
        return try withLightAppearance {
            try render(text: text, title: title, fontSize: fontSize,
                       fontFamily: fontFamily)
        }
    }

    @MainActor
    private static func render(
        text: String,
        title: String,
        fontSize: Double,
        fontFamily: EditorFontFamily
    ) throws -> Data {
        let source = text
        let parsed = MarkdownSyntax.parse(source)
        let bodyFont = MarkdownPresentation.bodyFont(
            for: fontFamily,
            pointSize: MarkdownPresentation.normalizedFontSize(fontSize)
        )
        let width = pageSize.width - marginLeft - marginRight
        let snapshot = MarkdownLivePreviewSnapshot(
            mode: .livePreview,
            selection: NSRange(location: 0, length: 0),
            isEditing: false,
            tableWidth: width,
            fontSize: bodyFont.pointSize
        )
        let preview = MarkdownLivePreview.ranges(
            in: source, result: parsed, snapshot: snapshot
        )
        let tables = MarkdownTableLayout.make(
            text: source,
            result: parsed,
            hiddenRanges: preview.collapsed,
            bodyFont: bodyFont,
            width: width,
            usePDFTextLayout: true
        )
        let attributed = MarkdownPresentation.exportAttributedString(
            text: source,
            result: parsed,
            bodyFont: bodyFont,
            previewRanges: preview,
            tableLayout: tables
        )
        let lines = try layoutLines(attributed, tableLayout: tables)
        let pages = try paginate(lines, availableHeight: pageSize.height
                                 - marginTop - marginBottom)
        return try makePDF(pages, title: title, width: width,
                           tableLayout: tables, source: source, result: parsed,
                           bodyFont: bodyFont)
    }

    @MainActor
    private static func layoutLines(
        _ attributed: NSAttributedString,
        tableLayout: MarkdownTableLayout
    ) throws -> [Line] {
        let contentStorage = NSTextContentStorage()
        contentStorage.textStorage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let textContainer = NSTextContainer(
            size: CGSize(width: pageSize.width - marginLeft - marginRight,
                         height: .greatestFiniteMagnitude)
        )
        textContainer.lineFragmentPadding = 0
        layoutManager.textContainer = textContainer
        let documentRange = contentStorage.documentRange
        layoutManager.ensureLayout(for: documentRange)
        var output: [Line] = []
        layoutManager.enumerateTextLayoutFragments(
            from: documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            guard let contentManager = layoutManager.textContentManager else {
                return false
            }
            guard let textElement = fragment.textElement,
                  let elementRange = textElement.elementRange else {
                return false
            }
            let elementStart = contentManager.offset(
                from: contentManager.documentRange.location,
                to: elementRange.location
            )
            for textLine in fragment.textLineFragments {
                let localRange = textLine.characterRange
                let location = elementStart + localRange.location
                let range = NSRange(location: location,
                                    length: localRange.length)
                guard range.location < attributed.length else { continue }
                let bounds = textLine.typographicBounds
                let fragmentFrame = fragment.layoutFragmentFrame
                let rect = bounds.offsetBy(dx: fragmentFrame.minX,
                                           dy: fragmentFrame.minY)
                let drawingOrigin = CGPoint(
                    x: fragmentFrame.minX + bounds.minX,
                    y: fragmentFrame.minY + bounds.minY
                )
                let row = tableLayout.row(at: range.location)
                if let row, range.location > row.range.location {
                    continue
                }
                if tableLayout.delimiters.contains(where: {
                    NSIntersectionRange($0, range).length > 0
                }) { continue }
                output.append(Line(
                    fragment: fragment,
                    textLine: textLine,
                    sourceRange: range,
                    elementStart: elementStart,
                    rect: rect,
                    drawingOrigin: drawingOrigin,
                    tableRow: row
                ))
            }
            return true
        }
        return output.sorted {
            if abs($0.rect.minY - $1.rect.minY) > 0.5 {
                return $0.rect.minY < $1.rect.minY
            }
            return $0.sourceRange.location < $1.sourceRange.location
        }
    }

    private static func paginate(
        _ lines: [Line],
        availableHeight: CGFloat
    ) throws -> [Page] {
        guard let first = lines.first else {
            return [Page(startY: 0, lines: [])]
        }
        var pages = [Page(startY: first.rect.minY, lines: [])]
        for line in lines {
            if let row = line.tableRow, row.height > availableHeight {
                throw RenderError.tableCannotFitPage
            }
            let page = pages.count - 1
            let startY = pages[page].startY
            let height = line.tableRow?.height ?? max(1, line.rect.height)
            if !pages[page].lines.isEmpty,
               line.rect.minY + min(height, availableHeight) - startY
                    > availableHeight {
                pages.append(Page(startY: line.rect.minY, lines: []))
            }
            pages[pages.count - 1].lines.append(line)
        }
        return pages
    }

    private static func makePDF(
        _ pages: [Page],
        title: String,
        width: CGFloat,
        tableLayout: MarkdownTableLayout,
        source: String,
        result: MarkdownSyntaxResult,
        bodyFont: PlatformFont
    ) throws -> Data {
        let output = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        let metadata: [CFString: Any] = [
            kCGPDFContextTitle: title,
            kCGPDFContextCreator: "meh.md",
        ]
        guard let consumer = CGDataConsumer(data: output as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox,
                                      metadata as CFDictionary) else {
            throw RenderError.unableToCreatePDFContext
        }
        for (pageNumber, page) in pages.enumerated() {
            context.beginPDFPage(nil)
            context.saveGState()
            context.translateBy(x: 0, y: pageSize.height)
            context.scaleBy(x: 1, y: -1)
            context.setFillColor(MarkdownPDFColor.white.cgColor)
            context.fill(CGRect(origin: .zero, size: pageSize))
            if pageNumber == 0, !title.isEmpty {
                drawPageTitle(title, in: context)
            }
            for line in page.lines {
                let top = marginTop + line.rect.minY - page.startY
                if let row = line.tableRow {
                    let rowRect = CGRect(x: marginLeft, y: top,
                                         width: width,
                                         height: row.height)
                    tableLayout.drawForPDF(
                        row, in: rowRect, context: context
                    )
                    continue
                }
                drawBlockDecoration(for: line, top: top, width: width,
                                    source: source, result: result,
                                    bodyFont: bodyFont, context: context)
                line.textLine.draw(
                    at: CGPoint(x: marginLeft + line.drawingOrigin.x,
                                y: top + line.drawingOrigin.y
                                    - line.rect.minY),
                    in: context
                )
                drawListMarkers(for: line, top: top, source: source,
                                result: result, context: context)
            }
            let footer = "\(pageNumber + 1)"
            drawFooter(footer, in: context)
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
        return output as Data
    }

    private static func drawBlockDecoration(
        for line: Line,
        top: CGFloat,
        width: CGFloat,
        source: String,
        result: MarkdownSyntaxResult,
        bodyFont: PlatformFont,
        context: CGContext
    ) {
        guard let run = result.paragraphRuns.first(where: {
            NSLocationInRange(line.sourceRange.location, $0.range)
        }) else { return }
        let kind: MarkdownPresentation.BlockDecoration.Kind
        switch run.kind {
        case .blockquote: kind = .blockquote
        case .codeBlock: kind = .codeBlock
        default: return
        }
        let left: CGFloat
        if kind == .codeBlock {
            left = 0
        } else if let marker = result.spans.first(where: {
            $0.role == .blockquoteMarker
                && NSLocationInRange($0.range.location, run.range)
        }), NSIntersectionRange(marker.range, line.sourceRange).length > 0,
                  let points = markerPoints(marker.range, in: line) {
            left = points.minX
        } else if let marker = result.spans.first(where: {
            $0.role == .blockquoteMarker
                && NSLocationInRange($0.range.location, run.range)
        }) {
            let source = source as NSString
            let prefixStart = run.contentPrefixRange.location
            let prefixEnd = min(marker.range.location, source.length)
            let prefixRange = NSRange(location: prefixStart,
                                      length: max(0, prefixEnd - prefixStart))
            let prefix = source.substring(with: prefixRange)
            left = (prefix as NSString).size(withAttributes: [.font: bodyFont]).width
        } else {
            let prefix = (source as NSString).substring(
                with: run.contentPrefixRange
            )
            left = (prefix as NSString).size(withAttributes: [.font: bodyFont]).width
        }
        let rect = CGRect(x: marginLeft + left, y: top,
                          width: max(0, width - left),
                          height: max(1, line.rect.height))
        MarkdownPresentation.drawExportBlockDecoration(kind, in: rect,
                                                       context: context)
    }

    private static func drawListMarkers(
        for line: Line,
        top: CGFloat,
        source: String,
        result: MarkdownSyntaxResult,
        context: CGContext
    ) {
        let source = source as NSString
        let lineRange = line.sourceRange
        let taskLines = Set(result.spans.compactMap { span -> Int? in
            guard case .taskMarker = span.role else { return nil }
            return source.lineRange(for: span.range).location
        })
        for span in result.spans where NSIntersectionRange(span.range,
                                                            lineRange).length > 0 {
            guard let points = markerPoints(span.range, in: line) else { continue }
            switch span.role {
            case .listMarker where span.range.length == 1:
                guard !taskLines.contains(source.lineRange(for: span.range).location)
                else { continue }
                let character = source.character(at: span.range.location)
                guard character == 42 || character == 43 || character == 45 else {
                    continue
                }
                let diameter = min(5, max(3, line.rect.height * 0.2))
                let bullet = CGRect(
                    x: marginLeft + points.midX - diameter / 2,
                    y: top + line.rect.height / 2 - diameter / 2,
                    width: diameter, height: diameter
                )
                MarkdownPresentation.drawExportListBullet(in: bullet,
                                                          context: context)
            case let .taskMarker(checked):
                let side = min(22, max(19, line.rect.height * 0.9))
                let checkbox = CGRect(
                    x: marginLeft + points.midX - side / 2,
                    y: top + line.rect.height / 2 - side / 2,
                    width: side, height: side
                )
                MarkdownPresentation.drawExportTaskCheckbox(
                    in: checkbox, checked: checked, context: context
                )
            default: continue
            }
        }
    }

    private static func markerPoints(_ range: NSRange, in line: Line)
    -> (minX: CGFloat, midX: CGFloat, maxX: CGFloat)? {
        let lineRange = line.textLine.characterRange
        let start = range.location - line.elementStart - lineRange.location
        guard start >= 0, start < lineRange.length else { return nil }
        let first = line.textLine.locationForCharacter(at: start)
        let last = line.textLine.locationForCharacter(at: start + range.length)
        return (first.x, (first.x + last.x) / 2, last.x)
    }

    private static func drawFooter(_ text: String, in context: CGContext) {
        let font = MarkdownPresentation.bodyFont(for: .system, pointSize: 9)
#if os(macOS)
        let color = NSColor.secondaryLabelColor
#else
        let color = UIColor.secondaryLabel
#endif
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color,
        ]
        let value = NSAttributedString(string: text, attributes: attributes)
        let rect = CGRect(x: marginLeft,
                          y: pageSize.height - marginBottom + 16,
                          width: pageSize.width - marginLeft - marginRight,
                          height: 12)
#if os(macOS)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context,
                                                       flipped: true)
        value.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
#else
        UIGraphicsPushContext(context)
        value.draw(in: rect)
        UIGraphicsPopContext()
#endif
    }

    private static func drawPageTitle(_ title: String, in context: CGContext) {
#if os(macOS)
        let font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        let color = NSColor.secondaryLabelColor
#else
        let font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        let color = UIColor.secondaryLabel
#endif
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let value = NSAttributedString(
            string: title,
            attributes: [.font: font, .foregroundColor: color,
                         .paragraphStyle: style]
        )
        let rect = CGRect(x: marginLeft, y: 18,
                          width: pageSize.width - marginLeft - marginRight,
                          height: 20)
#if os(macOS)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context,
                                                       flipped: true)
        value.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
#else
        UIGraphicsPushContext(context)
        value.draw(in: rect)
        UIGraphicsPopContext()
#endif
    }

    @MainActor
    private static func withLightAppearance<T>(
        _ operation: () throws -> T
    ) throws -> T {
        var result: Result<T, Error>!
#if os(macOS)
        guard let appearance = NSAppearance(named: .aqua) else {
            return try operation()
        }
        appearance.performAsCurrentDrawingAppearance {
            result = Result { try operation() }
        }
#else
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            result = Result { try operation() }
        }
#endif
        return try result.get()
    }
}
