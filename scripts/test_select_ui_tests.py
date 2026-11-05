from pathlib import Path
import re
import subprocess
import tempfile
import unittest

from run_ui_foundation import coverage_index
from select_ui_tests import (
    DIFF,
    FULL,
    HARNESS,
    NO_UI_IMPACT,
    PLANS,
    PROJECT,
    ROOT,
    Index,
    compiled,
    declaration,
    evaluate,
    expand,
    matches,
    parse_diff,
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
# Line numbers matter: COVERAGE says which goal ran which line.
SOURCE = """\
import SwiftUI

/// Shows a title.
struct Example: View {
    let title: String

    var body: some View {
        if title.isEmpty {
            Text("Empty")
        } else {
            Text(title)
        }
    }

    func open() {
        print("open")
    }
#if os(macOS)
    func macOnly() {
        print("mac")
    }
#else
    func iosOnly() {
        print("ios")
    }
#endif
}
"""
EXECUTABLE = [7, 8, 9, 10, 11, 12, 13, 15, 16, 17, 23, 24, 25]
COVERAGE = {
    # Line 9 only runs for an empty title, line 11 otherwise.
    "Case/testEmpty": [7, 8, 9, 10, 12, 13],
    "Case/testTitle": [7, 8, 10, 11, 12, 13],
    "Other/testOpen": [7, 8, 10, 11, 12, 13, 15, 16, 17, 23, 24, 25],
    "FlairUITests/testA": [],
}
RUN_BY_VIEW = {"Case/testEmpty", "Case/testTitle", "Other/testOpen"}
PLAN = {"Case/testEmpty", "Case/testTitle", "Other/testOpen", "FlairUITests/testA", "Fresh"}


def hunks(old, new):
    """The -U0 hunks git reports between two texts."""
    with tempfile.TemporaryDirectory() as directory:
        before, after = Path(directory, "a"), Path(directory, "b")
        before.write_text(old)
        after.write_text(new)
        diff = subprocess.run(
            ["git", *DIFF, "-U0", "--no-index", str(before), str(after)],
            capture_output=True, text=True,
        ).stdout
    return next(iter(parse_diff(diff).values()), [])


def change(old, new):
    return {"old": old, "new": new, "hunks": hunks(old or "", new or "")}


def edited(old, new, text=SOURCE):
    assert old in text, old
    return text.replace(old, new, 1)


class Selection(unittest.TestCase):
    def setUp(self):
        self.original = select.__globals__["plan_cases"]
        select.__globals__["plan_cases"] = lambda platform: PLAN

    def tearDown(self):
        select.__globals__["plan_cases"] = self.original

    def index(self, platform="iphone"):
        root = str(ROOT) + "/"
        return Index(coverage_index(
            platform, "abc",
            {test: {root + VIEW: lines} for test, lines in COVERAGE.items()},
            {root + VIEW: EXECUTABLE},
            {root + path for path in [
                VIEW, "meh.md/Declarations.swift", "meh.mdUITests/FlairUITests.swift",
                "meh.mdUITests/NotebookTrashUITests.swift",
                "meh.mdUITests/NotebookUITestSupport.swift",
            ]},
        ))

    def chosen(self, changes, platform="iphone", index=True):
        cases, reasons = select(changes, platform, self.index(platform) if index else None)
        return cases if cases is FULL else cases - {"Fresh"}

    def swift(self, new, old=SOURCE, path=VIEW, platform="iphone", index=True, more=None):
        return self.chosen({path: change(old, new), **(more or {})}, platform, index)


class FileRules(Selection):
    def test_docs_unit_tests_tools_and_widgets_need_no_ui_goal(self):
        paths = ["README.md", "docs/plan.md", "Tests/NoteCoreTests/A.swift",
                 "Tools/AppStore/capture.sh", ".github/workflows/testflight.yml",
                 "meh.mdWidgets/NotesWidget.swift"]
        for platform in PLANS:
            for index in (True, False):
                self.assertEqual(
                    self.chosen({path: {} for path in paths}, platform, index), set(),
                )

    def test_version_bump_needs_no_ui_goal(self):
        self.assertTrue(version_only(VERSION_BUMP))
        self.assertEqual(self.chosen({PROJECT: {"diff": VERSION_BUMP}}), set())
        other = VERSION_BUMP + "+\t\t\t\tSWIFT_VERSION = 6.0;\n"
        self.assertIs(self.chosen({PROJECT: {"diff": other}}), FULL)

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

    def test_harness_and_other_files_run_the_whole_plan(self):
        for path in [
            "scripts/run_ui_foundation.py",
            "TestPlans/CIIPhone.xctestplan",
            ".github/workflows/ui-regressions.yml",
            ".github/workflows/ui-coverage.yml",
            "Package.swift",
            "meh.md/Localizable.xcstrings",
            "meh.md/Assets.xcassets/Contents.json",
        ]:
            with self.subTest(path):
                self.assertIs(self.chosen({path: {}, "README.md": {}}), FULL)

    def test_without_an_index_swift_changes_run_the_whole_plan(self):
        new = edited('Text("Empty")', 'Text("None")')
        self.assertIs(self.swift(new, index=False), FULL)

    def test_comment_and_blank_line_changes_need_no_ui_goal(self):
        for new in [
            edited("/// Shows a title.", "/// Shows the title."),
            edited("/// Shows a title.\n", "/// Shows a title.\n///\n/// More.\n"),
            edited("    let title: String\n", "    let title: String\n\n"),
            edited("import SwiftUI\n", "import SwiftUI\n/* A\n   block. */\n"),
        ]:
            with self.subTest(new):
                for platform in PLANS:
                    self.assertEqual(self.swift(new, platform=platform, index=False), set())

    def test_blank_lines_and_slashes_in_multi_line_strings_are_text(self):
        before = edited("Text(title)", 'Text("""\n        a\n        b\n        """)')
        for inside in ["        a\n\n", "        a\n        // b\n"]:
            after = edited("        a\n", inside, before)
            with self.subTest(inside):
                self.assertIs(self.swift(after, before, index=False), FULL)

    def test_each_lane_only_counts_code_it_compiles(self):
        mac = edited('print("mac")', 'print("macOS")')
        self.assertEqual(self.swift(mac, platform="iphone", index=False), set())
        self.assertEqual(self.swift(mac, platform="ipad", index=False), set())
        self.assertIs(self.swift(mac, platform="mac", index=False), FULL)
        ios = edited('print("ios")', 'print("iOS")')
        self.assertIs(self.swift(ios, platform="ipad", index=False), FULL)
        self.assertEqual(self.swift(ios, platform="mac", index=False), set())

    def test_a_condition_that_resolves_the_same_compiles_the_same(self):
        same = edited("#if os(macOS)", "#if os(macOS) && canImport(AppKit)")
        for platform in PLANS:
            self.assertEqual(self.swift(same, platform=platform, index=False), set())
        flipped = edited("#if os(macOS)", "#if os(iOS)")
        for platform in PLANS:
            self.assertIs(self.swift(flipped, platform=platform), FULL)

    def test_files_for_another_platform(self):
        path = "meh.md/MacOnly.swift"
        old = "#if os(macOS)\nimport AppKit\n\nfunc a() {}\n#endif\n"
        new = old.replace("a()", "b()")
        self.assertEqual(self.swift(new, old, path, "iphone"), set())
        self.assertEqual(self.swift(new, None, path, "iphone"), set())
        self.assertEqual(self.swift(None, old, path, "ipad"), set())
        self.assertIs(self.swift(None, old, path, "mac"), FULL)

    def test_ui_test_files_without_line_data_run_their_own_class(self):
        old = "final class FlairUITests: XCTestCase {\n    func testA() {}\n}\n"
        new = old.replace("{}", "{ XCTFail() }")
        for index in (True, False):
            self.assertEqual(
                self.swift(new, old, "meh.mdUITests/FlairUITests.swift", index=index),
                {"FlairUITests/testA"},
            )
            # A nightly-only class has no PR goal to run.
            self.assertEqual(
                self.swift(new, old, "meh.mdUITests/NotebookTrashUITests.swift", index=index),
                set(),
            )
            # Shared UI test support can affect every class.
            self.assertIs(
                self.swift(new, old, "meh.mdUITests/NotebookUITestSupport.swift", index=index),
                FULL,
            )


class CoverageRules(Selection):
    def test_a_changed_line_runs_the_goals_that_ran_it(self):
        self.assertEqual(
            self.swift(edited('Text("Empty")', 'Text("None")')), {"Case/testEmpty"},
        )
        self.assertEqual(
            self.swift(edited('print("open")', 'print("opened")')), {"Other/testOpen"},
        )

    def test_a_case_of_a_class_entry_runs(self):
        # CIMac lists MacFormattingUITests as a class; coverage names its cases.
        select.__globals__["plan_cases"] = lambda platform: {"Case", "Other/testOpen"}
        cases, _ = select(
            {VIEW: change(SOURCE, edited('Text("Empty")', 'Text("None")'))},
            "iphone", self.index(),
        )
        self.assertEqual(cases, {"Case/testEmpty"})

    def test_goals_without_coverage_data_always_run(self):
        cases, reasons = select(
            {VIEW: change(SOURCE, edited('Text("Empty")', 'Text("None")'))},
            "iphone", self.index(),
        )
        self.assertEqual(cases, {"Case/testEmpty", "Fresh"})
        self.assertIn("Fresh: has no coverage data yet", reasons)

    def test_a_line_no_goal_ran_needs_no_goal(self):
        index = self.index()
        index.files[VIEW]["ran"].pop(str(index.tests.index("Other/testOpen")))
        cases, _ = select(
            {VIEW: change(SOURCE, edited('print("open")', 'print("opened")'))}, "iphone", index,
        )
        self.assertEqual(cases, {"Fresh"})

    def test_inserted_code_runs_the_goals_around_it(self):
        new = edited('Text("Empty")\n', 'Text("Empty")\n            Text("More")\n')
        # Between line 9 (an empty title) and 10 (`} else {`, run by all).
        self.assertEqual(self.swift(new), RUN_BY_VIEW)

    def test_used_declarations_run_through_their_callers(self):
        new = edited('    func open() {', '    func close() {}\n\n    func open() {')
        new = edited('print("open")', "close()", new)
        self.assertEqual(self.swift(new), RUN_BY_VIEW)
        # A stored value has no line data; the code around it stands in.
        stored = edited("    let title: String", "    let title: String?")
        self.assertEqual(self.swift(stored), RUN_BY_VIEW)

    def test_declarations_that_may_run_by_themselves_run_the_whole_plan(self):
        insert = "    }\n\n    func open() {"
        for added in [
            # Unused, so maybe called implicitly, like a delegate method.
            "func close() {}",
            "private static let shared = 1",
            "@objc func close() {}",
            "init(title: String) { self.title = title }",
            "override func viewDidLoad() {}",
        ]:
            with self.subTest(added):
                new = edited(insert, f"    }}\n\n    {added}\n\n    func open() {{")
                self.assertIs(self.swift(new), FULL)
        for new in [
            edited("struct Example: View {", "struct Example: View, Hashable {"),
            SOURCE + "\nextension Example: Identifiable {}\n",
            SOURCE + "\nenum Kind {\n    case a\n}\n",
        ]:
            with self.subTest(new):
                self.assertIs(self.swift(new), FULL)
        local = edited('        print("open")', '        let name = "open"\n        print(name)')
        self.assertEqual(self.swift(local), {"Other/testOpen"})

    def test_platform_code_counts_only_where_it_compiles(self):
        mac = edited('print("mac")', 'print("macOS")')
        self.assertEqual(self.swift(mac, platform="iphone"), set())
        ios = edited('print("ios")', 'print("iOS")')
        self.assertEqual(self.swift(ios), {"Other/testOpen"})
        block = "    }\n    #if os(macOS)\n    func menu() {}\n    #endif\n}\n"
        new = SOURCE[: -len("}\n")] + block[len("    }\n"):]
        self.assertEqual(self.swift(new, platform="iphone"), set())

    def test_unknown_conditions_run_the_whole_plan(self):
        new = edited("    func open() {", "    #if DEBUG\n    func debug() {}\n    #endif\n\n    func open() {")
        self.assertIs(self.swift(new), FULL)

    def test_files_without_line_data(self):
        path = "meh.md/Declarations.swift"
        old = "enum Kind {\n    case a\n}\n"
        self.assertIs(self.swift(old.replace("a", "b"), old, path), FULL)
        # A file the lane did not build has nothing to run.
        self.assertEqual(self.swift(old.replace("a", "b"), old, "meh.md/Other.swift"), set())

    def test_new_files_run_through_the_changed_lines_that_use_them(self):
        path = "meh.md/NewThing.swift"
        text = ("import SwiftUI\n\n@MainActor\nstruct NewThing: View {\n"
                "    var body: some View {\n        Text(\"x\")\n    }\n}\n\n"
                "#Preview {\n    NewThing()\n}\n")
        caller = {VIEW: change(SOURCE, edited('Text("Empty")', "NewThing()"))}
        self.assertIs(self.swift(text, None, path), FULL)
        self.assertEqual(self.swift(text, None, path, more=caller), {"Case/testEmpty"})
        for unsafe in [
            "extension Example: Hashable {}\n",
            "extension Example {\n    func makeCoordinator() {}\n}\n",
            "@main\nstruct App {}\n",
            'print("top level")\n',
        ]:
            with self.subTest(unsafe):
                self.assertIs(self.swift(unsafe + text, None, path, more=caller), FULL)

    def test_deleted_files_run_the_whole_plan(self):
        self.assertIs(self.swift(None), FULL)


class Helpers(unittest.TestCase):
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

    def test_declarations(self):
        for line, expected in {
            "func a()": ("named", "a"),
            "  private static let x = 1": ("stored", "x"),
            "@State private var open = false": ("stored", "open"),
            "var body: some View {": ("named", "body"),
            "public final class A {": ("type", "A"),
            "@MainActor": (None, None),
            "@objc func a()": ("implicit", None),
            "#warning(\"x\")": ("implicit", None),
            "#Preview {": (None, None),
            "extension A: B {": ("implicit", None),
            "extension A where T: B {": (None, None),
            "extension A {": (None, None),
            "override init() {": ("implicit", None),
            "case wiki, markdown": ("implicit", None),
            "case .a:": (None, None),
            "case let .a(value):": (None, None),
            "return a": (None, None),
        }.items():
            with self.subTest(line):
                self.assertEqual(declaration(line), expected)

    def test_globs(self):
        self.assertTrue(matches("Tools/Import/README.md", ["**.md"]))
        self.assertFalse(matches("meh.md/Welcome.md", NO_UI_IMPACT))
        self.assertTrue(matches("docs/a/b.png", ["docs/**"]))
        self.assertFalse(matches("docsx/a.png", ["docs/**"]))


class Repository(unittest.TestCase):
    def setUp(self):
        self.files = subprocess.run(
            ["git", "ls-files"], cwd=ROOT, check=True, capture_output=True, text=True,
        ).stdout.splitlines()

    def test_every_harness_path_matches_a_tracked_file(self):
        for pattern in HARNESS:
            with self.subTest(pattern):
                self.assertTrue(any(matches(f, [pattern]) for f in self.files))

    def test_ui_test_files_declare_only_their_own_class(self):
        """A changed UI test file runs its own class, so it may hold nothing else."""
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
