import Foundation
import SwiftUI
import XCTest

@testable import NativeEditor

#if DEBUG
@MainActor
final class NotebookEditorPreferencesTests: XCTestCase {
    func testPreferencesPersistWithinFixtureAndStayIsolated() throws {
        let first = preview(UUID().uuidString)
        let second = preview(UUID().uuidString)
        let firstName = try XCTUnwrap(NotebookEditorPreferences.suiteName(for: first))
        let secondName = try XCTUnwrap(NotebookEditorPreferences.suiteName(for: second))
        let defaults = NotebookEditorPreferences.store(for: first)
        defer {
            defaults.removePersistentDomain(forName: firstName)
            NotebookEditorPreferences.store(for: second)
                .removePersistentDomain(forName: secondName)
        }
        let ordinary = UserDefaults.standard
        let originalFont = ordinary.string(forKey: "editor.fontFamily")
        let originalOrder = ordinary.stringArray(forKey: "editor.keyboardToolbar.commands")
        let font = AppStorage(wrappedValue: "system", "editor.fontFamily", store: defaults)
        let mode = AppStorage(wrappedValue: "livePreview", "editor.mode", store: defaults)
        font.wrappedValue = "serif"
        mode.wrappedValue = "source"
        defaults.set(28.0, forKey: "editor.fontSize")
        defaults.set(["italic", "bold"], forKey: "editor.keyboardToolbar.commands")

        // A new preferences object models reopening the same fictional app.
        let reopened = NotebookEditorPreferences.store(for: first)
        XCTAssertEqual(reopened.string(forKey: "editor.fontFamily"), "serif")
        XCTAssertEqual(reopened.string(forKey: "editor.mode"), "source")
        XCTAssertEqual(reopened.double(forKey: "editor.fontSize"), 28)
        XCTAssertEqual(reopened.stringArray(forKey: "editor.keyboardToolbar.commands"),
                       ["italic", "bold"])
        let fresh = NotebookEditorPreferences.store(for: second)
        for key in ["editor.fontFamily", "editor.mode", "editor.fontSize",
                    "editor.keyboardToolbar.commands"] {
            XCTAssertNil(fresh.object(forKey: key), "Another fixture inherited \(key)")
        }
        XCTAssertEqual(ordinary.string(forKey: "editor.fontFamily"), originalFont)
        XCTAssertEqual(ordinary.stringArray(forKey: "editor.keyboardToolbar.commands"),
                       originalOrder)
    }

    func testNamespaceIncludesFixtureKindAndLoopbackEndpoint() throws {
        let id = UUID().uuidString
        let first = loopback(id, endpoint: "http://127.0.0.1:9874")
        let second = loopback(id, endpoint: "http://127.0.0.1:9875")
        let names = try [preview(id), first, second].map {
            try XCTUnwrap(NotebookEditorPreferences.suiteName(for: $0))
        }
        XCTAssertEqual(Set(names).count, 3)
        XCTAssertEqual(NotebookEditorPreferences.suiteName(for: first), names[1])
        // A URL disables preview selection in the actual workspace resolver.
        let loopbackWithPreviewFlag = first.merging(["MEH_NOTEBOOK_PREVIEW": "1"]) {
            _, new in new
        }
        XCTAssertEqual(NotebookEditorPreferences.suiteName(for: loopbackWithPreviewFlag),
                       names[1])
    }

    func testNormalAndLiveAccountLaunchesKeepStandardPreferences() {
        for environment in [[:], ["MEH_SYNC_CLOUDKIT": "1"],
                            ["MEH_NOTEBOOK_PREVIEW_RUN": UUID().uuidString]] {
            XCTAssertNil(NotebookEditorPreferences.suiteName(for: environment))
            XCTAssertTrue(NotebookEditorPreferences.store(for: environment) === UserDefaults.standard)
        }
    }

    func testInvalidOrConflictingFixtureFlagsDoNotSelectAStore() {
        let invalid: [[String: String]] = [
            preview(""), preview("../other"), preview(String(repeating: "a", count: 65)),
            ["MEH_NOTEBOOK_PREVIEW": "1"],
            preview("valid").merging(["MEH_SYNC_CLOUDKIT": "1"]) { _, new in new },
            preview("valid").merging(["MEH_SYNC_URL": "http://127.0.0.1"]) { _, new in new },
            loopback("valid", endpoint: "https://127.0.0.1"),
            loopback("valid", endpoint: "http://example.com"),
            loopback("../other", endpoint: "http://127.0.0.1"),
            ["MEH_SYNC_TEST_TRANSPORT": "loopback", "MEH_SYNC_URL": "http://127.0.0.1"],
        ]
        for environment in invalid {
            XCTAssertNil(NotebookEditorPreferences.suiteName(for: environment))
            XCTAssertTrue(NotebookEditorPreferences.store(for: environment) === UserDefaults.standard)
        }
    }

    private func preview(_ id: String) -> [String: String] {
        ["MEH_NOTEBOOK_PREVIEW": "1", "MEH_NOTEBOOK_PREVIEW_RUN": id]
    }

    private func loopback(_ id: String, endpoint: String) -> [String: String] {
        ["MEH_SYNC_TEST_TRANSPORT": "loopback", "MEH_SYNC_URL": endpoint,
         "MEH_SYNC_WORKSPACE": id]
    }
}
#endif
