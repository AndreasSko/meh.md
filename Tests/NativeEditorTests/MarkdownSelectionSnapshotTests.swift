import Foundation
import SwiftUI
import XCTest

@testable import NativeEditor

#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class MarkdownSelectionSnapshotTests: XCTestCase {
    func testSelectionReportsLiteralCurrentSnapshotWithoutRebuildingIt() async {
        let source = "# Fictional café\n\nA decomposed e\u{0301} and moon 🪐."
        let navigation = MarkdownEditorNavigation()
        let editor = MarkdownEditor(text: .constant(source), navigation: navigation)
        let coordinator = editor.makeCoordinator()
        let view = MarkdownTextView(usingTextLayoutManager: true)
        #if os(macOS)
        view.string = source
        let storage = view.textStorage!
        #else
        view.text = source
        let storage = view.textStorage
        #endif
        MarkdownPresentation.configure(view)
        let cache = view.markdownSyntaxCache
        let prepared = cache.textSnapshot(in: storage)
        let snapshots = cache.snapshotCount
        func report() async -> String {
            await withCheckedContinuation { continuation in
                navigation.selectionChanged = { text, _, _ in
                    continuation.resume(returning: text)
                }
                #if os(macOS)
                coordinator.textViewDidChangeSelection(Notification(
                    name: NSTextView.didChangeSelectionNotification, object: view
                ))
                #else
                coordinator.textViewDidChangeSelection(view)
                #endif
            }
        }
        let unchanged = await report()
        XCTAssertTrue(unchanged.utf8.elementsEqual(prepared.utf8))
        XCTAssertEqual(cache.snapshotCount, snapshots)

        // A native character edit must invalidate the shared immutable snapshot.
        storage.replaceCharacters(in: NSRange(location: storage.length, length: 0),
                                  with: " [[Moon")
        let changed = await report()
        XCTAssertTrue(changed.utf8.elementsEqual((source + " [[Moon").utf8))
        XCTAssertEqual(cache.snapshotCount, snapshots + 1)
        let repeated = await report()
        XCTAssertTrue(repeated.utf8.elementsEqual(changed.utf8))
        XCTAssertEqual(cache.snapshotCount, snapshots + 1)
        navigation.selectionChanged = nil
    }
}
