import XCTest

@testable import NativeEditor

#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class MarkdownRenderingIndexTests: XCTestCase {
    func testSelectionReusesSyntaxIndexAndEverySyntaxChangeInvalidatesIt() {
        let source = "# Sky\n`inline` and **bright**.\n```\nmoon\n```\nTail"
        let storage = NSTextStorage(string: source)
        let cache = MarkdownSyntaxCache()
        func snapshot(_ offset: Int) -> MarkdownLivePreviewSnapshot {
            MarkdownLivePreviewSnapshot(mode: .livePreview,
                selection: NSRange(location: offset, length: 0), isEditing: true)
        }
        func verify(_ presentation: MarkdownRenderingPresentation, text: String) {
            XCTAssertEqual(presentation.result, MarkdownSyntax.parse(text))
            assertMatchesLegacy(presentation,
                target: NSRange(location: 0, length: text.utf16.count))
        }
        verify(cache.presentation(in: storage, snapshot: snapshot(0)), text: source)
        XCTAssertEqual(cache.renderingSyntaxIndexBuildCount, 1)
        for offset in [3, 12, source.utf16.count] {
            verify(cache.presentation(in: storage, snapshot: snapshot(offset)), text: source)
            XCTAssertEqual(cache.renderingSyntaxIndexBuildCount, 1)
        }

        storage.replaceCharacters(in: NSRange(location: storage.length, length: 0),
                                  with: "!")
        verify(cache.presentation(in: storage, snapshot: snapshot(0)), text: source + "!")
        XCTAssertEqual(cache.incrementalParseCount, 1)
        XCTAssertEqual(cache.renderingSyntaxIndexBuildCount, 2)

        // Structural edits force a full parse, which owns a new syntax index.
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length),
                                  with: "```\nnew code\n```\n`later`")
        verify(cache.presentation(in: storage, snapshot: snapshot(0)), text: storage.string)
        XCTAssertEqual(cache.renderingSyntaxIndexBuildCount, 3)

        let other = NSTextStorage(string: "[map](sky.md) and ==light==")
        verify(cache.presentation(in: other, snapshot: snapshot(0)), text: other.string)
        XCTAssertEqual(cache.renderingSyntaxIndexBuildCount, 4)
        let arbitrary = "# Unrelated\n`fresh`"
        verify(cache.presentation(for: arbitrary, snapshot: snapshot(0)), text: arbitrary)
        XCTAssertEqual(cache.renderingSyntaxIndexBuildCount, 5)
        verify(cache.presentation(in: other, snapshot: snapshot(2)), text: other.string)
        XCTAssertEqual(cache.renderingSyntaxIndexBuildCount, 6)
    }

    func testParsedRenderingAndConcealmentMatchLegacyForEveryCharacter() {
        let sources = [
            "# Sky\n**bold _nested_** ==light== ~~dust~~ [map](sky.md)\n"
                + "- [x] Seen\n> Quote\n`inline`\n```swift\nlet sky = `moon`\n```\n",
            "Before `inline` and **`nested`**.\n```\ncode\n```\n"
                + "After `later`.\n~~~swift\nmore code\n~~~\n",
        ]
        for source in sources {
            let result = MarkdownSyntax.parse(source)
            for mode in [MarkdownEditorMode.source, .livePreview] {
                let ranges = MarkdownLivePreview.ranges(
                    in: source, result: result,
                    snapshot: MarkdownLivePreviewSnapshot(
                        mode: mode, selection: NSRange(location: 0, length: 0),
                        isEditing: false
                    )
                )
                let presentation = MarkdownRenderingPresentation(
                    result: result, previewRanges: ranges
                )
                for offset in 0..<source.utf16.count {
                    assertMatchesLegacy(presentation,
                        target: NSRange(location: offset, length: 1))
                }
                assertMatchesLegacy(presentation,
                    target: NSRange(location: 0, length: source.utf16.count))
                assertMatchesLegacy(presentation,
                    target: NSRange(location: source.utf16.count, length: 0))
            }
        }
    }

    func testNestedAndBoundaryCodeSpansPreserveExactLegacyPredicate() {
        let result = MarkdownSyntaxResult(
            spans: [
                MarkdownStyleSpan(range: NSRange(location: 0, length: 60), role: .code),
                MarkdownStyleSpan(range: NSRange(location: 2, length: 50), role: .strong),
                MarkdownStyleSpan(range: NSRange(location: 5, length: 15), role: .code),
                MarkdownStyleSpan(range: NSRange(location: 10, length: 30), role: .code),
                MarkdownStyleSpan(range: NSRange(location: 20, length: 10), role: .code),
                MarkdownStyleSpan(range: NSRange(location: 30, length: 10), role: .code),
                MarkdownStyleSpan(range: NSRange(location: 40, length: 5), role: .code),
                MarkdownStyleSpan(range: NSRange(location: 45, length: 10), role: .highlight),
            ], fontRuns: [], paragraphRuns: [20, 40].map {
                MarkdownParagraphRun(range: NSRange(location: $0, length: 5),
                    kind: .codeBlock, contentColumn: 0,
                    contentPrefixRange: NSRange(location: $0, length: 0))
            }, restartOffsets: [0, 60], canRestartAtEnd: true
        )
        let presentation = MarkdownRenderingPresentation(result: result,
            hiddenRanges: [NSRange(location: 19, length: 4),
                           NSRange(location: 45, length: 2)])
        for offset in 0..<60 {
            assertMatchesLegacy(presentation,
                target: NSRange(location: offset, length: 1))
        }
        assertMatchesLegacy(presentation, target: NSRange(location: 0, length: 60))
    }

    private func assertMatchesLegacy(_ presentation: MarkdownRenderingPresentation,
                                    target: NSRange,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let expected = presentation.result.spans.filter {
            NSIntersectionRange($0.range, target).length > 0
                && !MarkdownPresentation.renderingAttributes(
                    for: $0, in: presentation.result
                ).isEmpty
        }
        var actual: [MarkdownStyleSpan] = []
        presentation.forEachRenderingSpan(intersecting: target) { span, attributes in
            actual.append(span)
            let legacy = MarkdownPresentation.renderingAttributes(
                for: span, in: presentation.result
            )
            XCTAssertTrue(NSDictionary(dictionary: attributes).isEqual(to: legacy),
                          file: file, line: line)
            #if os(iOS)
            for style in [UIUserInterfaceStyle.light, .dark] {
                let traits = UITraitCollection(userInterfaceStyle: style)
                for (key, value) in attributes {
                    if let color = value as? UIColor,
                       let previous = legacy[key] as? UIColor {
                        XCTAssertEqual(color.resolvedColor(with: traits),
                                       previous.resolvedColor(with: traits),
                                       file: file, line: line)
                    }
                }
            }
            #endif
        }
        XCTAssertEqual(actual, expected, file: file, line: line)
        var hidden: [NSRange] = []
        presentation.forEachHiddenRange(intersecting: target) { hidden.append($0) }
        XCTAssertEqual(hidden, presentation.hiddenRanges.filter {
            NSIntersectionRange($0, target).length > 0
        }, file: file, line: line)
        XCTAssertEqual(presentation.hiddenRenderingAttributes[.foregroundColor]
                       as? PlatformColor, PlatformColor.clear, file: file, line: line)
        // Begin with unrelated attributes: base adds must retain them, while
        // role and hidden setters must replace the complete dictionary.
        let bases: [[NSAttributedString.Key: Any]] = [
            [:], [.foregroundColor: PlatformColor.systemBlue],
        ]
        for base in bases {
            let initial: [NSAttributedString.Key: Any] = [
                .backgroundColor: PlatformColor.systemYellow, .underlineStyle: 1,
            ]
            let legacy = NSMutableAttributedString(
                string: String(repeating: "x", count: NSMaxRange(target)), attributes: initial)
            legacy.addAttributes(base, range: target)
            presentation.forEachSpan(intersecting: target) { span in
                let attributes = MarkdownPresentation.renderingAttributes(
                    for: span, in: presentation.result)
                if !attributes.isEmpty {
                    legacy.setAttributes(attributes,
                        range: NSIntersectionRange(span.range, target))
                }
            }
            presentation.forEachHiddenRange(intersecting: target) {
                legacy.setAttributes(presentation.hiddenRenderingAttributes,
                    range: NSIntersectionRange($0, target))
            }
            let actual = NSMutableAttributedString(
                string: legacy.string, attributes: initial)
            let commands = presentation.renderingCommands(in: target, baseAttributes: base)
            var previousEnd = target.location
            for command in commands {
                XCTAssertGreaterThan(command.range.length, 0, file: file, line: line)
                XCTAssertGreaterThanOrEqual(command.range.location, previousEnd,
                                            file: file, line: line)
                previousEnd = NSMaxRange(command.range)
                XCTAssertLessThanOrEqual(previousEnd, NSMaxRange(target), file: file, line: line)
                if command.replacesAttributes {
                    actual.setAttributes(command.attributes, range: command.range)
                } else {
                    actual.addAttributes(command.attributes, range: command.range)
                }
            }
            XCTAssertTrue(actual.isEqual(to: legacy), file: file, line: line)
        }
    }
}
