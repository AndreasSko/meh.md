import Foundation
import XCTest
@testable import NativeEditor

#if DEBUG
@MainActor
final class NotebookEditorPreferencesTests: XCTestCase {
    func testPreferencesPersistWithinRunAndStayFreshAcrossRuns() throws {
        let first = preview(UUID().uuidString, fixture: "writing")
        let second = preview(UUID().uuidString, fixture: "writing")
        let firstName = try XCTUnwrap(NotebookEditorPreferences.suiteName(for: first))
        let secondName = try XCTUnwrap(NotebookEditorPreferences.suiteName(for: second))
        defer {
            UserDefaults.standard.removePersistentDomain(forName: firstName)
            UserDefaults.standard.removePersistentDomain(forName: secondName)
        }
        let defaults = NotebookEditorPreferences.store(for: first)
        defaults.set("source", forKey: "editor.mode")
        defaults.set(23.0, forKey: "editor.fontSize")
        defaults.set("monospaced", forKey: "editor.fontFamily")
        defaults.set(["bold", "italic"], forKey: "editor.keyboardToolbar.commands")
        XCTAssertEqual(NotebookEditorPreferences.store(for: first)
            .string(forKey: "editor.mode"), "source")
        XCTAssertEqual(NotebookEditorPreferences.store(for: first)
            .double(forKey: "editor.fontSize"), 23.0)
        XCTAssertEqual(NotebookEditorPreferences.store(for: first)
            .string(forKey: "editor.fontFamily"), "monospaced")
        XCTAssertEqual(NotebookEditorPreferences.store(for: first)
            .stringArray(forKey: "editor.keyboardToolbar.commands"), ["bold", "italic"])
        for key in ["editor.mode", "editor.fontSize", "editor.fontFamily",
                    "editor.keyboardToolbar.commands"] {
            XCTAssertNil(NotebookEditorPreferences.store(for: second).object(forKey: key))
        }
        for environment in [[:], ["MEH_NOTEBOOK_PREVIEW_RUN": "run"],
                            preview("../run", fixture: "writing"),
                            first.merging(["MEH_SYNC_CLOUDKIT": "1"]) { _, new in new }] {
            XCTAssertNil(NotebookEditorPreferences.suiteName(for: environment))
            XCTAssertTrue(NotebookEditorPreferences.store(for: environment) === UserDefaults.standard)
        }
    }

    func testLoopbackRequiresValidatedLocalWorkspace() throws {
        let valid = ["MEH_SYNC_TEST_TRANSPORT": "loopback",
                     "MEH_SYNC_URL": "http://127.0.0.1:8080",
                     "MEH_SYNC_WORKSPACE": "fictional"]
        let namespace = try XCTUnwrap(
            NotebookEditorPreferences.suiteName(for: valid))
        XCTAssertNotEqual(namespace, NotebookEditorPreferences.suiteName(
            for: preview("fictional", fixture: "writing")))
        XCTAssertNotEqual(namespace, NotebookEditorPreferences.suiteName(
            for: valid.merging(["MEH_SYNC_URL": "http://127.0.0.1:8081"])
                { _, new in new }))
        XCTAssertNil(NotebookEditorPreferences.suiteName(
            for: valid.filter { $0.key != "MEH_SYNC_WORKSPACE" }))
        for changes in [
            ["MEH_SYNC_URL": "https://127.0.0.1"],
            ["MEH_SYNC_URL": "http://example.com"],
            ["MEH_SYNC_WORKSPACE": "../personal"],
            ["MEH_NOTEBOOK_PREVIEW": "1"],
            ["MEH_SYNC_CLOUDKIT": "1"]
        ] {
            XCTAssertNil(NotebookEditorPreferences.suiteName(
                for: valid.merging(changes) { _, new in new }))
        }
    }

    private func preview(_ run: String, fixture: String) -> [String: String] {
        ["MEH_NOTEBOOK_PREVIEW": "1", "MEH_NOTEBOOK_PREVIEW_RUN": run,
         "MEH_NOTEBOOK_TEST_FIXTURE": fixture]
    }
}
#endif
