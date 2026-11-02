import CoreText
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A line ending in `=` and the total of the times above it.
struct MarkdownTimeSum: Hashable {
    /// The `=` that asks for the sum, as a UTF-16 offset.
    let location: Int
    let seconds: Int
}

/// The Labs time calculator. A line that ends in `=` sums the times written
/// since the previous `=` line or heading. Live Preview draws the result
/// after the `=`; it is never part of the text.
enum MarkdownTimeCalculator {
    /// The device-local Labs setting. Each note still opts in on its own.
    static let enabledKey = "labs.timeCalculator"

    // MARK: - Sums

    static func sums(in text: String, result: MarkdownSyntaxResult) -> [MarkdownTimeSum] {
        var skipped: [NSRange] = []
        var boundaries: [NSRange] = []
        for span in result.spans {
            switch span.role {
            case .code, .link, .listMarker: skipped.append(span.range)
            case .heading: boundaries.append(span.range)
            default: break
            }
        }
        return sums(in: text, skipping: skipped, boundaries: boundaries)
    }

    /// Sums for every line ending in `=`. Characters in `skipped` are not
    /// read, and a line touching one of `boundaries` starts a new sum.
    static func sums(
        in text: String, skipping skipped: [NSRange], boundaries: [NSRange]
    ) -> [MarkdownTimeSum] {
        let source = text as NSString
        let length = source.length
        let skipped = merged(skipped)
        let boundaries = merged(boundaries)
        var boundaryIndex = 0
        func isSkipped(_ location: Int) -> NSRange? {
            let index = MarkdownPresentation.firstRange(in: skipped, endingAfter: location)
            guard index < skipped.count, NSLocationInRange(location, skipped[index]) else {
                return nil
            }
            return skipped[index]
        }

        var sums: [MarkdownTimeSum] = []
        var total = 0.0
        // An operator applies to the value right after it, even on the next line.
        var sign: Double?
        // The last value on this line, so `1h 30m` shares one sign.
        var group: (end: Int, sign: Double, unit: Int)?
        var lineStart = 0
        while lineStart < length {
            let line = source.lineRange(for: NSRange(location: lineStart, length: 0))
            var contentEnd = NSMaxRange(line)
            while contentEnd > line.location, isLineBreak(source.character(at: contentEnd - 1)) {
                contentEnd -= 1
            }
            lineStart = NSMaxRange(line)
            group = nil
            while boundaryIndex < boundaries.count,
                  NSMaxRange(boundaries[boundaryIndex]) <= line.location {
                boundaryIndex += 1
            }
            if boundaryIndex < boundaries.count,
               NSIntersectionRange(boundaries[boundaryIndex], line).length > 0 {
                total = 0
                sign = nil
                continue
            }
            let equals = equalsSign(in: source, from: line.location, to: contentEnd)
                .flatMap { isSkipped($0) == nil ? $0 : nil }
            let scanEnd = equals ?? contentEnd
            var index = line.location
            while index < scanEnd {
                if let range = isSkipped(index) {
                    index = NSMaxRange(range)
                    group = nil
                    continue
                }
                let character = source.character(at: index)
                if character == plus || character == minus || character == minusSign {
                    // `Mon-Fri` is a word, but in `7m-1h` the `-` follows a time.
                    if index == line.location || group?.end == index
                        || !isWord(source.character(at: index - 1)) {
                        sign = character == plus ? 1 : -1
                    } else {
                        sign = nil
                    }
                    group = nil
                    index += 1
                    continue
                }
                if isDigit(character),
                   group?.end == index || canStartValue(in: source, at: index, lineStart: line.location) {
                    if let value = value(in: source, at: index, end: scanEnd) {
                        let valueSign: Double
                        if let group, sign == nil, value.unit > group.unit {
                            valueSign = group.sign
                        } else {
                            valueSign = sign ?? 1
                        }
                        total += valueSign * value.seconds
                        sign = nil
                        group = (value.end, valueSign, value.unit)
                        index = value.end
                    } else {
                        sign = nil
                        group = nil
                        while index < scanEnd, isWord(source.character(at: index)) { index += 1 }
                    }
                    continue
                }
                if character != space && character != tab {
                    sign = nil
                    group = nil
                }
                index += 1
            }
            if let equals {
                // A huge number in the text must not trap the conversion.
                let rounded = total.rounded()
                let seconds = Int(exactly: rounded) ?? (rounded < 0 ? -Int.max : Int.max)
                sums.append(MarkdownTimeSum(location: equals, seconds: seconds))
                total = 0
                sign = nil
            }
        }
        return sums
    }

    /// `1d 2h 5m`, `-3m`, or `0m`.
    static func format(_ seconds: Int) -> String {
        guard seconds != 0 else { return "0m" }
        let magnitude = seconds.magnitude
        let parts: [(UInt, String)] = [
            (magnitude / 86_400, "d"), (magnitude % 86_400 / 3_600, "h"),
            (magnitude % 3_600 / 60, "m"), (magnitude % 60, "s"),
        ]
        let text = parts.filter { $0.0 > 0 }.map { "\($0.0)\($0.1)" }.joined(separator: " ")
        return seconds < 0 ? "-" + text : text
    }

    private static let plus: unichar = 0x2B
    private static let minus: unichar = 0x2D
    private static let minusSign: unichar = 0x2212
    private static let equals: unichar = 0x3D
    private static let space: unichar = 0x20
    private static let tab: unichar = 0x09

    /// Units from largest to smallest; the index orders them.
    private static let units: [(unichar, Double)] = [
        (0x64, 86_400), (0x68, 3_600), (0x6D, 60), (0x73, 1),
    ]

    private static func merged(_ ranges: [NSRange]) -> [NSRange] {
        ranges.sorted { $0.location < $1.location }.reduce(into: []) { result, range in
            if let last = result.last, range.location <= NSMaxRange(last) {
                result[result.count - 1] = NSUnionRange(last, range)
            } else {
                result.append(range)
            }
        }
    }

    /// The trailing `=` of a line, unless it closes `==highlight==` or a
    /// heading underline.
    private static func equalsSign(in source: NSString, from start: Int, to end: Int) -> Int? {
        var last = end
        while last > start, isWhitespace(source.character(at: last - 1)) { last -= 1 }
        guard last > start, source.character(at: last - 1) == equals else { return nil }
        let location = last - 1
        guard location == start || source.character(at: location - 1) != equals else { return nil }
        return location
    }

    /// A value starts at a word boundary, but not inside a number like `v1.5`.
    private static func canStartValue(in source: NSString, at index: Int, lineStart: Int) -> Bool {
        guard index > lineStart else { return true }
        let previous = source.character(at: index - 1)
        if isWord(previous) { return false }
        if previous == 0x2E || previous == 0x2C, index - 1 > lineStart,
           isDigit(source.character(at: index - 2)) { return false }
        return true
    }

    private static func value(
        in source: NSString, at start: Int, end: Int
    ) -> (seconds: Double, unit: Int, end: Int)? {
        var index = start
        while index < end, isDigit(source.character(at: index)) { index += 1 }
        if index + 1 < end, source.character(at: index) == 0x2E || source.character(at: index) == 0x2C,
           isDigit(source.character(at: index + 1)) {
            index += 1
            while index < end, isDigit(source.character(at: index)) { index += 1 }
        }
        let number = source.substring(with: NSRange(location: start, length: index - start))
            .replacingOccurrences(of: ",", with: ".")
        var unitLocation = index
        while unitLocation < end,
              source.character(at: unitLocation) == space || source.character(at: unitLocation) == tab {
            unitLocation += 1
        }
        guard unitLocation < end, let amount = Double(number),
              let unit = units.firstIndex(where: { $0.0 == source.character(at: unitLocation) })
        else { return nil }
        let valueEnd = unitLocation + 1
        if valueEnd < end, isWord(source.character(at: valueEnd)),
           !isDigit(source.character(at: valueEnd)) { return nil }
        return (amount * units[unit].1, unit, valueEnd)
    }

    private static func isDigit(_ character: unichar) -> Bool {
        character >= 0x30 && character <= 0x39
    }

    private static func isLineBreak(_ character: unichar) -> Bool {
        character == 0x0A || character == 0x0D
    }

    private static func isWhitespace(_ character: unichar) -> Bool {
        character == space || character == tab || isLineBreak(character)
    }

    private static func isWord(_ character: unichar) -> Bool {
        if character == 0x5F { return true }
        guard let scalar = Unicode.Scalar(character) else { return true }
        return CharacterSet.alphanumerics.contains(scalar)
    }

    // MARK: - Drawing

    /// Recomputes the sums after a refresh and redraws the lines whose
    /// result changed.
    static func update(_ textView: MarkdownTextView) {
        var sums: [MarkdownTimeSum] = []
        let snapshot = MarkdownLivePreview.snapshot(for: textView)
        #if os(macOS)
        let storage = textView.textStorage
        #else
        let storage: NSTextStorage? = textView.textStorage
        #endif
        if textView.markdownTimeCalculator, snapshot.mode == .livePreview, let storage {
            // Turning the calculator on can happen between refreshes.
            let presentation = MarkdownPresentation.presentationForDrawing(
                in: storage, syntaxCache: textView.markdownSyntaxCache, snapshot: snapshot
            )
            sums = self.sums(in: storage.string, result: presentation.result)
        }
        let previous = textView.markdownTimeSums
        guard sums != previous else { return }
        textView.markdownTimeSums = sums
        #if os(macOS)
        textView.needsDisplay = true
        #else
        // Each fragment draws its own result, so only changed lines redraw.
        guard let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager else { return }
        let source = textView.text as NSString
        let changed = Set(previous).symmetricDifference(sums).map(\.location)
        for location in Set(changed) where location < source.length {
            let line = source.lineRange(for: NSRange(location: location, length: 0))
            if let range = MarkdownPresentation.textRange(
                for: line, documentStart: contentManager.documentRange.location,
                contentManager: contentManager
            ) {
                layoutManager.invalidateLayout(for: range)
            }
        }
        #endif
    }

    private struct Result {
        let text: String
        let font: PlatformFont
        /// The baseline start in text container coordinates.
        let origin: CGPoint
    }

    private static func results(
        for sums: [MarkdownTimeSum], in textView: MarkdownTextView,
        layoutManager: NSTextLayoutManager
    ) -> [Result] {
        guard let contentManager = layoutManager.textContentManager else { return [] }
        #if os(macOS)
        guard let storage = textView.textStorage else { return [] }
        #else
        let storage = textView.textStorage
        #endif
        let source = storage.string as NSString
        return sums.compactMap { sum in
            // A refresh follows every edit; skip results that moved meanwhile.
            guard sum.location < source.length,
                  source.character(at: sum.location) == equals,
                  let range = MarkdownPresentation.textRange(
                      for: NSRange(location: sum.location, length: 1),
                      documentStart: contentManager.documentRange.location,
                      contentManager: contentManager
                  ) else { return nil }
            let font = storage.attribute(.font, at: sum.location, effectiveRange: nil)
                as? PlatformFont ?? textView.font ?? MarkdownPresentation.editorBodyFont
            var origin: CGPoint?
            layoutManager.enumerateTextSegments(
                in: range, type: .standard, options: [.rangeNotRequired]
            ) { _, frame, baseline, _ in
                guard !frame.isNull else { return true }
                origin = CGPoint(x: frame.maxX + spaceWidth(of: font), y: frame.minY + baseline)
                return false
            }
            return origin.map { Result(text: format(sum.seconds), font: font, origin: $0) }
        }
    }

    private static func spaceWidth(of font: PlatformFont) -> CGFloat {
        (" " as NSString).size(withAttributes: [.font: font]).width
    }

    private static func draw(_ results: [Result], offset: CGPoint, context: CGContext) {
        guard !results.isEmpty else { return }
        #if os(macOS)
        let color = NSColor.secondaryLabelColor.cgColor
        #else
        let color = UIColor.secondaryLabel.cgColor
        #endif
        context.saveGState()
        defer { context.restoreGState() }
        context.setFillColor(color)
        // Text views draw flipped; CoreText expects the y axis to point up.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for result in results {
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: result.text,
                attributes: [
                    .font: result.font,
                    NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
                ]
            ))
            context.textPosition = CGPoint(
                x: result.origin.x + offset.x, y: result.origin.y + offset.y
            )
            CTLineDraw(line, context)
        }
    }

    #if os(macOS)
    /// AppKit draws the background in one pass over the dirty area.
    static func draw(in textView: MarkdownTextView, dirtyRect: CGRect) {
        guard !textView.markdownTimeSums.isEmpty,
              let layoutManager = textView.textLayoutManager,
              let visible = MarkdownPresentation.visibleRange(in: layoutManager),
              let context = NSGraphicsContext.current?.cgContext else { return }
        let sums = textView.markdownTimeSums.filter { NSLocationInRange($0.location, visible) }
        draw(results(for: sums, in: textView, layoutManager: layoutManager),
             offset: textView.textContainerOrigin, context: context)
    }
    #else
    /// UIKit draws each fragment on its own.
    static func draw(
        in fragment: NSTextLayoutFragment,
        textView: MarkdownTextView,
        at point: CGPoint,
        context: CGContext
    ) {
        guard !textView.markdownTimeSums.isEmpty,
              let layoutManager = fragment.textLayoutManager,
              let range = MarkdownHistoryMarks.nsRange(of: fragment, in: layoutManager)
        else { return }
        let sums = textView.markdownTimeSums.filter { NSLocationInRange($0.location, range) }
        guard !sums.isEmpty else { return }
        let frame = fragment.layoutFragmentFrame
        draw(results(for: sums, in: textView, layoutManager: layoutManager),
             offset: CGPoint(x: point.x - frame.minX, y: point.y - frame.minY),
             context: context)
    }
    #endif
}
