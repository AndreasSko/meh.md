import re
import subprocess
import unittest

from select_ui_tests import (
    FULL,
    HARNESS,
    NO_UI_IMPACT,
    PLANS,
    PROJECT,
    ROOT,
    compiled,
    evaluate,
    expand,
    matches,
    plan_cases,
    select,
    version_only,
)

VERSION_BUMP = """\
--- a/meh.md.xcodeproj/project.pbxproj
+++ b/meh.md.xcodeproj/project.pbxproj
@@ -457,1 +457,1 @@
-\t\t\t\tMARKETING_VERSION = 0.22.6;
+\t\t\t\tMARKETING_VERSION = 0.22.7;
"""

VIEW = "meh.md/Example.swift"
SOURCE = """\
import SwiftUI

/// Shows a title.
struct Example: View {
    let title: String

    var body: some View {
        Text(title)
        #if os(macOS)
            .padding(12)
        #else
            .padding(8)
        #endif
    }
}
"""


def changed(old, new):
    return SOURCE.replace(old, new, 1)


class SelectionTests(unittest.TestCase):
    def chosen(self, changes, platform="iphone", diff="", texts=None):
        return select(changes, platform, diff, texts)[0]

    def swift(self, new, old=SOURCE, path=VIEW, platform="iphone"):
        return self.chosen({path}, platform, texts={path: (old, new)})

    def test_docs_unit_tests_and_tools_need_no_ui_goal(self):
        for platform in PLANS:
            self.assertEqual(
                self.chosen({"README.md", "docs/plan.md", "Tests/NoteCoreTests/A.swift",
                             "Tools/AppStore/capture.sh", ".github/workflows/testflight.yml",
                             "meh.mdWidgets/NotesWidget.swift"},
                            platform),
                set(),
            )

    def test_version_bump_needs_no_ui_goal(self):
        self.assertTrue(version_only(VERSION_BUMP))
        self.assertEqual(self.chosen({PROJECT}, diff=VERSION_BUMP), set())

    def test_unpaired_version_changes_are_not_a_bump(self):
        header = VERSION_BUMP.split("@@")[0]
        line = "\t\t\t\tMARKETING_VERSION = 0.22.7;"
        for diff in [
            header + "@@ -1,1 +1,0 @@\n-" + line + "\n",
            header + "@@ -1,0 +1,1 @@\n+" + line + "\n",
            header + "@@ -1,1 +1,0 @@\n-" + line + "\n@@ -9,0 +9,1 @@\n+" + line + "\n",
            header + "@@ -1,1 +1,1 @@\n-" + line + "\n+\t\t\t\tCURRENT_PROJECT_VERSION = 2;\n",
        ]:
            with self.subTest(diff):
                self.assertFalse(version_only(diff))
                self.assertIs(self.chosen({PROJECT}, diff=diff), FULL)

    def test_other_project_changes_run_the_whole_plan(self):
        diff = VERSION_BUMP + "+\t\t\t\tSWIFT_VERSION = 6.0;\n"
        self.assertIs(self.chosen({PROJECT}, diff=diff), FULL)
        self.assertIs(self.chosen({PROJECT}), FULL)

    def test_harness_and_other_files_run_the_whole_plan(self):
        for path in [
            "scripts/run_ui_foundation.py",
            "TestPlans/CIIPhone.xctestplan",
            ".github/workflows/ui-regressions.yml",
            "Package.swift",
            "meh.md/Localizable.xcstrings",
            "meh.md/Assets.xcassets/Contents.json",
        ]:
            with self.subTest(path):
                self.assertIs(self.chosen({path, "README.md"}), FULL)

    def test_comment_and_blank_line_changes_need_no_ui_goal(self):
        for new in [
            changed("/// Shows a title.", "/// Shows the title."),
            changed("/// Shows a title.\n", "/// Shows a title.\n///\n/// More.\n"),
            changed("    let title: String\n", "    let title: String\n\n"),
            changed("import SwiftUI\n", "import SwiftUI\n/* A\n   block. */\n"),
        ]:
            with self.subTest(new):
                for platform in PLANS:
                    self.assertEqual(self.swift(new, platform=platform), set())

    def test_code_changes_run_the_whole_plan(self):
        for new in [
            changed("Text(title)", "Text(title.uppercased())"),
            changed("    let title: String", "    let title: String?"),
        ]:
            with self.subTest(new):
                self.assertIs(self.swift(new), FULL)

    def test_blank_lines_and_slashes_in_multi_line_strings_are_text(self):
        before = changed("Text(title)", 'Text("""\n        a\n        b\n        """)')
        for inside in ["        a\n\n", "        a\n        // b\n"]:
            after = before.replace("        a\n", inside, 1)
            with self.subTest(inside):
                self.assertIs(self.swift(after, old=before), FULL)

    def test_each_lane_only_counts_code_it_compiles(self):
        mac = changed(".padding(12)", ".padding(16)")
        self.assertEqual(self.swift(mac, platform="iphone"), set())
        self.assertEqual(self.swift(mac, platform="ipad"), set())
        self.assertIs(self.swift(mac, platform="mac"), FULL)
        ios = changed(".padding(8)", ".padding(10)")
        self.assertIs(self.swift(ios, platform="iphone"), FULL)
        self.assertIs(self.swift(ios, platform="ipad"), FULL)
        self.assertEqual(self.swift(ios, platform="mac"), set())

    def test_new_platform_blocks_count_only_where_they_compile(self):
        block = "    }\n    #if os(macOS)\n    func menu() {}\n    #endif\n}\n"
        new = SOURCE.replace("    }\n}\n", block)
        self.assertEqual(self.swift(new, platform="iphone"), set())
        self.assertIs(self.swift(new, platform="mac"), FULL)

    def test_changed_conditions_count_where_they_change_the_code(self):
        new = changed("#if os(macOS)", "#if os(iOS)")
        for platform in PLANS:
            self.assertIs(self.swift(new, platform=platform), FULL)
        unknown = changed("#if os(macOS)", "#if DEBUG")
        self.assertIs(self.swift(unknown, platform="iphone"), FULL)
        # A condition that resolves the same way compiles the same code.
        same = changed("#if os(macOS)", "#if os(macOS) && canImport(AppKit)")
        for platform in PLANS:
            self.assertEqual(self.swift(same, platform=platform), set())

    def test_files_for_another_platform(self):
        path = "meh.md/MacOnly.swift"
        old = "#if os(macOS)\nimport AppKit\n\nfunc a() {}\n#endif\n"
        new = old.replace("a()", "b()")
        self.assertEqual(self.swift(new, old, path, "iphone"), set())
        self.assertIs(self.swift(new, old, path, "mac"), FULL)
        # New and deleted files compare against nothing.
        self.assertEqual(self.swift(new, None, path, "iphone"), set())
        self.assertEqual(self.swift(None, old, path, "ipad"), set())
        self.assertIs(self.swift(None, old, path, "mac"), FULL)
        self.assertIs(self.swift("func a() {}\n", None, path, "iphone"), FULL)

    def test_ui_test_file_runs_its_own_goals(self):
        path = "meh.mdUITests/FlairUITests.swift"
        old = "final class FlairUITests: XCTestCase {\n    func testA() {}\n}\n"
        new = old.replace("{}", "{ XCTFail() }")
        self.assertEqual(
            self.swift(new, old, path), expand(["FlairUITests"], plan_cases("iphone")),
        )
        # A nightly-only class has no PR goal to run.
        self.assertEqual(self.swift(new, old, "meh.mdUITests/NotebookTrashUITests.swift"), set())
        # Shared UI test support can affect every class.
        self.assertIs(self.swift(new, old, "meh.mdUITests/NotebookUITestSupport.swift"), FULL)

    def test_class_entries_in_a_plan_stay_whole(self):
        # CIMac lists MacFormattingUITests as a class; the runner expands it.
        path = "meh.mdUITests/MacFormattingUITests.swift"
        old = "#if os(macOS)\nfinal class MacFormattingUITests {}\n#endif\n"
        new = old.replace("{}", "{ }")
        self.assertEqual(self.swift(new, old, path, "mac"), {"MacFormattingUITests"})
        self.assertEqual(self.swift(new, old, path, "iphone"), set())

    def test_conditions(self):
        self.assertIs(evaluate(" os(macOS)", "iphone"), False)
        self.assertIs(evaluate(" !os(macOS)", "iphone"), True)
        self.assertIs(evaluate(" os(iOS) || os(macOS)", "mac"), True)
        self.assertIs(evaluate(" canImport(UIKit) && !os(macOS)", "ipad"), True)
        for unknown in [" DEBUG", " os(iOS) && DEBUG", " targetEnvironment(simulator)",
                        " swift(>=6.0)", " !NOTEBOOK_PERFORMANCE_HOST"]:
            with self.subTest(unknown):
                self.assertIsNone(evaluate(unknown, "iphone"))

    def test_compiled_branches(self):
        text = "\n".join([
            "#if os(macOS)", "a", "#elseif os(iOS)", "b", "#else", "c", "#endif",
            "#if DEBUG", "d", "#else", "e", "#endif",
        ])
        self.assertEqual(
            compiled(text, "iphone"), ["b", "#if DEBUG", "d", "#else", "e", "#endif"],
        )
        self.assertEqual(compiled(text, "mac")[0], "a")

    def test_globs(self):
        self.assertTrue(matches("Tools/Import/README.md", ["**.md"]))
        self.assertFalse(matches("meh.md/Welcome.md", NO_UI_IMPACT))
        self.assertTrue(matches("docs/a/b.png", ["docs/**"]))
        self.assertFalse(matches("docsx/a.png", ["docs/**"]))


class RepositoryTests(unittest.TestCase):
    def setUp(self):
        self.files = subprocess.run(
            ["git", "ls-files"], cwd=ROOT, check=True, capture_output=True, text=True,
        ).stdout.splitlines()

    def test_every_harness_path_matches_a_tracked_file(self):
        for pattern in HARNESS:
            with self.subTest(pattern):
                self.assertTrue(any(matches(f, [pattern]) for f in self.files))

    def test_ui_test_files_declare_only_their_own_class(self):
        """A changed UI test file runs only its own class, so it may hold nothing else."""
        for path in self.files:
            match = re.fullmatch(r"meh\.mdUITests/(\w+UITests)\.swift", path)
            if not match:
                continue
            with self.subTest(path):
                declarations = re.findall(
                    r"^(?:@\w+\s+|(?:public|internal|private|fileprivate|final)\s+)*"
                    r"(?:class|struct|enum|actor|extension|func|let|var|protocol"
                    r"|typealias)\s+(\w+)",
                    (ROOT / path).read_text(), re.M,
                )
                self.assertEqual(declarations, [match[1]])


if __name__ == "__main__":
    unittest.main()
