import Foundation
import XCTest

@testable import NativeEditor

#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class MarkdownPreparedSyntaxTests: XCTestCase {
    func testPreparedResultReusesObservedRevisionAcrossToolbarQueries() {
        let (view, storage) = fixture("# Header\n\nOrdinary café e\u{0301} 🪐 paragraph.")
        let cache = view.markdownSyntaxCache
        let initial = cache.preparedSyntax(in: storage)
        let parses = cache.parseCount
        let snapshots = cache.snapshotCount
        let incremental = cache.incrementalParseCount
        let comparisons = cache.fullTextComparisonCount
        for _ in 0..<10 {
            XCTAssertEqual(cache.preparedSyntax(in: storage), initial)
            _ = view.availableTableCommands
            _ = view.currentTableAlignment
            _ = view.headingCommandsEnabled
        }
        storage.addAttribute(.kern, value: 2, range: NSRange(location: 0, length: 1))
        XCTAssertEqual(cache.preparedSyntax(in: storage), initial)
        _ = view.availableTableCommands
        _ = view.currentTableAlignment
        _ = view.headingCommandsEnabled
        XCTAssertEqual(cache.parseCount, parses)
        XCTAssertEqual(cache.snapshotCount, snapshots)
        XCTAssertEqual(cache.incrementalParseCount, incremental)
        XCTAssertEqual(cache.fullTextComparisonCount, comparisons)
    }

    func testPreparedResultConsumesNewCharacterRevisionExactlyOnce() {
        let (_, storage) = fixture("# Header\n\nOrdinary paragraph.")
        let cache = MarkdownSyntaxCache()
        _ = cache.preparedSyntax(in: storage)
        let parses = cache.parseCount
        let snapshots = cache.snapshotCount
        let incremental = cache.incrementalParseCount
        let comparisons = cache.fullTextComparisonCount
        let edit = (storage.string as NSString).range(of: "Ordinary")
        storage.replaceCharacters(in: edit, with: "A **bright**")
        let result = cache.preparedSyntax(in: storage)
        XCTAssertEqual(result, MarkdownSyntax.parse(storage.string))
        XCTAssertEqual(cache.snapshotCount, snapshots + 1)
        XCTAssertEqual(cache.parseCount, parses)
        XCTAssertEqual(cache.incrementalParseCount, incremental + 1)
        XCTAssertEqual(cache.preparedSyntax(in: storage), result)
        XCTAssertEqual(cache.snapshotCount, snapshots + 1)
        XCTAssertEqual(cache.incrementalParseCount, incremental + 1)
        XCTAssertEqual(cache.fullTextComparisonCount, comparisons)
    }

    func testArbitraryStringsCountLiteralComparisonsWithoutUnicodeNormalization() {
        let cache = MarkdownSyntaxCache()
        let composed = "==é=="
        let decomposed = "==e\u{0301}=="
        XCTAssertEqual(composed, decomposed)
        XCTAssertFalse(composed.utf8.elementsEqual(decomposed.utf8))
        let first = cache.result(for: composed)
        XCTAssertEqual(cache.fullTextComparisonCount, 0)
        XCTAssertEqual(cache.result(for: composed), first)
        XCTAssertEqual(cache.fullTextComparisonCount, 1)
        XCTAssertEqual(cache.parseCount, 1)

        let second = cache.result(for: decomposed)
        XCTAssertEqual(cache.fullTextComparisonCount, 2)
        XCTAssertEqual(cache.parseCount, 2)
        XCTAssertEqual(second, MarkdownSyntax.parse(decomposed))
        XCTAssertNotEqual(first.spans.first?.range, second.spans.first?.range)
        XCTAssertEqual(cache.result(for: decomposed), second)
        XCTAssertEqual(cache.fullTextComparisonCount, 3)
        XCTAssertEqual(cache.parseCount, 2)
    }

    func testArbitraryMissInvalidatesNativePreparedIdentityButExactHitRetainsIt() {
        let storage = NSTextStorage(string: "# Native\n==café==")
        let cache = MarkdownSyntaxCache()
        let initial = cache.preparedSyntax(in: storage)
        let parses = cache.parseCount
        XCTAssertEqual(cache.result(for: storage.string), initial)
        XCTAssertEqual(cache.preparedSyntax(in: storage), initial)
        XCTAssertEqual(cache.parseCount, parses)

        let unrelated = "**An unrelated string**"
        XCTAssertEqual(cache.result(for: unrelated), MarkdownSyntax.parse(unrelated))
        XCTAssertEqual(cache.preparedSyntax(in: storage), MarkdownSyntax.parse(storage.string))
        XCTAssertEqual(cache.parseCount, parses + 2)
        XCTAssertNil(cache.nativeTextChange(in: storage))
    }

    func testArbitraryMissDoesNotConsumePendingNativeIntentAsItsOwnEdit() {
        let storage = NSTextStorage(string: "# Native\nTail")
        let cache = MarkdownSyntaxCache()
        _ = cache.preparedSyntax(in: storage)
        storage.replaceCharacters(in: NSRange(location: storage.length, length: 0),
                                  with: " 🪐 **new**")
        let intent = cache.nativeTextChange(in: storage)
        XCTAssertNotNil(intent)
        let unrelated = "# Other\n[[Sky]]"
        XCTAssertEqual(cache.result(for: unrelated), MarkdownSyntax.parse(unrelated))
        XCTAssertEqual(cache.incrementalParseCount, 0)
        XCTAssertEqual(cache.nativeTextChange(in: storage), intent)
        XCTAssertEqual(cache.preparedSyntax(in: storage), MarkdownSyntax.parse(storage.string))
        XCTAssertEqual(cache.nativeTextChange(in: storage), intent)
        XCTAssertEqual(cache.incrementalParseCount, 0)
        XCTAssertEqual(cache.parseCount, 3)
    }

    func testPreparedResultFollowsReplacementStorageIdentity() {
        let cache = MarkdownSyntaxCache()
        let first = NSTextStorage(string: "[[Sky]]\nTail")
        _ = cache.preparedSyntax(in: first)
        first.replaceCharacters(in: NSRange(location: first.length, length: 0), with: "!")
        let other = NSTextStorage(string: "# Different\n**bold**")
        let result = cache.preparedSyntax(in: other)
        XCTAssertEqual(result, MarkdownSyntax.parse(other.string))
        XCTAssertNil(cache.nativeTextChange(in: other))
        XCTAssertEqual(cache.preparedSyntax(in: first), MarkdownSyntax.parse(first.string))
    }

    private func fixture(_ text: String) -> (MarkdownTextView, NSTextStorage) {
        let view = MarkdownTextView(usingTextLayoutManager: true)
#if os(macOS)
        view.string = text
        let storage = view.textStorage!
#else
        view.text = text
        let storage = view.textStorage
#endif
        MarkdownPresentation.configure(view, mode: .livePreview)
        return (view, storage)
    }
}
