import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

from coverage_selection import DIFF, ROOT, Index, coverage_index, matches, parse_diff
from run_editor_coverage import SWIFT, checkout_path, lcov_lines
from select_editor_steps import (
    ALL_STEPS,
    INDEX_VERSION,
    NO_IMPACT,
    STEPS,
    load_index,
    pick,
    select,
)

EDITOR = "meh.md/MarkdownEditor.swift"
# Line numbers matter: RAN says which step ran which line.
SOURCE = """\
import SwiftUI

struct Editor {
    var text: String

    func bold() {
        print("bold")
    }

    func paste() {
        print("paste")
    }
#if os(macOS)
    func scrollWheel() {
        print("wheel")
    }
#endif
}
"""
EXECUTABLE = [6, 7, 8, 10, 11, 12, 15, 16, 17]
RAN = {
    "native": [6, 7, 8],
    "probes": [6, 7, 8, 10, 11, 12],
    "formatting": [15, 16, 17],
}
TEST = "Tests/NoteCoreTests/NoteHistoryTests.swift"


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


def index_data(step, compiled=None):
    """A step's index; SwiftPM steps on the Mac also build the unit tests."""
    root = str(ROOT) + "/"
    anchor = STEPS[step]["anchor"]
    ran = {root + anchor: [1], root + EDITOR: RAN.get(step, [])}
    executable = {root + anchor: [1], root + EDITOR: EXECUTABLE}
    if compiled is None:
        compiled = [EDITOR, anchor] + ([TEST] if "filter" in STEPS[step] else [])
    data = coverage_index(
        STEPS[step]["platform"], "abc", {step: ran}, executable,
        [root + path for path in compiled],
    )
    data["version"] = INDEX_VERSION
    return data


class Selection(unittest.TestCase):
    def indexes(self, available=True):
        return {step: Index(index_data(step)) if available else None for step in STEPS}

    def chosen(self, changes, available=True):
        steps, _ = select(changes, self.indexes(available))
        return {step for step, run in steps.items() if run}

    def swift(self, new, old=SOURCE, path=EDITOR, available=True):
        return self.chosen({path: change(old, new)}, available)


class FileRules(Selection):
    def test_docs_and_unrelated_files_run_nothing(self):
        for path in [
            "README.md", "docs/editor-performance.md", "scripts/release_notes.py",
            ".github/workflows/ui-regressions.yml", "meh.md.xcodeproj/project.pbxproj",
            "meh.md/Assets.xcassets/Contents.json", "meh.md/Localizable.xcstrings",
            "meh.mdUITests/FlairUITests.swift", "meh.mdWidgets/Widgets.swift",
            "TestPlans/CIIPhone.xctestplan", "Tools/Import/README.md",
        ]:
            with self.subTest(path):
                self.assertEqual(self.chosen({path: {}}), set())

    def test_selection_workflows_and_dependencies_run_every_step(self):
        for path in [
            ".github/workflows/editor-performance.yml",
            ".github/workflows/editor-coverage.yml",
            "scripts/coverage_selection.py",
            "scripts/select_editor_steps.py",
            "scripts/run_editor_coverage.py",
            "scripts/test_check_editor_performance.py",
            "Package.swift",
            "Package.resolved",
        ]:
            with self.subTest(path):
                self.assertEqual(self.chosen({path: {}}), set(STEPS))

    def test_a_step_s_own_files_run_that_step(self):
        for path, step in [
            ("scripts/run_native_editor_baseline_parity.sh", "native"),
            ("scripts/fixtures/native-editor-inventory.json", "native"),
            ("scripts/fixtures/performance/parser-reference-af516.json", "parser"),
            ("scripts/check_catalog_performance.py", "catalog"),
            ("Tools/EditorQuoteCheck/Info.plist", "probes"),
            ("scripts/run_editor_performance_check.sh", "probes"),
            ("scripts/check_native_editor_baseline_parity.py", "native"),
            ("scripts/editor_performance_app_cache.py", "probes"),
        ]:
            with self.subTest(path):
                self.assertEqual(self.chosen({path: {}}), {step})

    def test_other_files_that_are_not_swift_run_every_step(self):
        self.assertEqual(self.chosen({"Sources/NoteCore/Data.json": {}}), set(STEPS))


class SwiftRules(Selection):
    def test_comments_run_nothing(self):
        new = edited("struct Editor {", "/// Edits.\nstruct Editor {")
        self.assertEqual(self.swift(new, available=False), set())

    def test_mac_only_code_skips_iphone_steps_without_an_index(self):
        new = edited('print("wheel")', 'print("wheel turned")')
        self.assertEqual(
            self.swift(new, available=False),
            {step for step in STEPS if STEPS[step]["platform"] == "mac"},
        )

    def test_without_an_index_a_swift_change_runs_every_step(self):
        new = edited('print("bold")', 'print("Bold")')
        self.assertEqual(self.swift(new, available=False), set(STEPS))

    def test_a_changed_line_runs_the_steps_that_ran_it(self):
        self.assertEqual(self.swift(edited('print("bold")', 'print("Bold")')), {"native", "probes"})
        self.assertEqual(self.swift(edited('print("paste")', 'print("Paste")')), {"probes"})

    def test_code_that_runs_without_a_changed_caller_runs_the_step(self):
        new = edited("    var text: String\n", "    var text: String\n\n    init() { text = \"\" }\n")
        self.assertEqual(self.swift(new), set(STEPS))

    def test_a_new_file_in_a_new_subfolder_still_builds(self):
        """SwiftPM builds a target's subfolders too."""
        extension = "import XCTest\n\nextension NoteHistoryTests {\n    func testSlow() {}\n}\n"
        path = "Tests/NoteCoreTests/Extra/SlowHistoryTests.swift"
        self.assertEqual(self.chosen({path: change(None, extension)}), {"history"})

    def test_files_a_step_does_not_build_skip_it(self):
        path = "Sources/NoteCore/Sync.swift"
        self.assertEqual(self.swift(edited('print("bold")', 'print("Bold")'), path=path), set())

    def test_new_tests_in_a_class_a_step_never_ran_skip_it(self):
        old = "import XCTest\n\nfinal class SnippetTests: XCTestCase {\n}\n"
        new = old.replace("{\n}", "{\n    func testMore() {}\n}")
        path = "Tests/NativeEditorTests/SnippetTests.swift"
        self.assertEqual(self.chosen({path: change(old, new)}), set())

    def test_a_new_test_file_runs_the_steps_that_filter_for_its_class(self):
        history = "import XCTest\n\nfinal class NoteHistoryReaderTests: XCTestCase {}\n"
        other = "import XCTest\n\nfinal class SnippetTests: XCTestCase {}\n"
        folder = "Tests/NoteCoreTests/"
        self.assertEqual(self.chosen({folder + "New.swift": change(None, history)}), {"history"})
        self.assertEqual(self.chosen({folder + "Other.swift": change(None, other)}), set())
        extension = "import XCTest\n\nextension NoteHistoryTests {\n    func testMore() {}\n}\n"
        self.assertEqual(
            self.chosen({folder + "More.swift": change(None, extension)}), {"history"}
        )


class Indexes(unittest.TestCase):
    def load(self, data, step="native"):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, f"coverage-{step}.json").write_text(json.dumps(data))
            original = load_index.__globals__["read_index"]
            # The fake index's commit is not in the checkout.
            load_index.__globals__["read_index"] = lambda path, platform: (
                Index(json.loads(path.read_text())), None
            )
            try:
                return load_index(directory, step)
            finally:
                load_index.__globals__["read_index"] = original

    def test_a_complete_index_loads(self):
        index, reason = self.load(index_data("native"))
        self.assertIsNotNone(index, reason)

    def test_an_old_format_is_ignored(self):
        data = index_data("native")
        data["version"] = INDEX_VERSION - 1
        self.assertIsNone(self.load(data)[0])

    def test_an_index_without_its_anchor_is_ignored(self):
        data = index_data("probes", compiled=[EDITOR])
        self.assertIsNone(self.load(data, "probes")[0])

    def test_an_index_whose_anchor_never_ran_is_ignored(self):
        data = index_data("probes")
        data["files"][STEPS["probes"]["anchor"]]["ran"] = {}
        self.assertIsNone(self.load(data, "probes")[0])

    def test_an_index_of_another_step_is_ignored(self):
        self.assertIsNone(self.load(index_data("probes"), "native")[0])


class Commits(unittest.TestCase):
    def test_each_step_diffs_from_its_own_index_commit(self):
        """Line numbers only match the commit the index was taken at."""
        edit = change(SOURCE, edited('print("bold")', 'print("Bold")'))
        seen = []

        def changes(commit):
            seen.append(commit)
            return {EDITOR: edit} if commit == "abc" else {}

        indexes = {step: Index(index_data(step)) for step in STEPS}
        indexes["probes"] = None
        chosen, _ = pick(indexes, "base", changes)
        self.assertEqual(sorted(seen), ["abc", "base"])
        self.assertTrue(chosen["native"])
        self.assertFalse(chosen["probes"])

    def test_all_runs_every_step(self):
        with tempfile.NamedTemporaryFile("r") as output:
            subprocess.run(
                [sys.executable, str(ROOT / "scripts/select_editor_steps.py"),
                 "--all", "--github-output"],
                check=True, capture_output=True,
                env={**os.environ, "GITHUB_OUTPUT": output.name, "GITHUB_STEP_SUMMARY": ""},
            )
            lines = dict(line.split("=", 1) for line in output.read().splitlines())
        self.assertEqual(json.loads(lines["steps"]), {step: True for step in STEPS})
        self.assertEqual(lines["any"], "true")


class Recording(unittest.TestCase):
    def test_lcov_lines(self):
        executable, ran = lcov_lines(
            "SF:/a.swift\nDA:3,0\nDA:4,2\nend_of_record\nSF:/b.swift\nDA:1,1\nend_of_record\n"
        )
        self.assertEqual(executable, {"/a.swift": {3, 4}, "/b.swift": {1}})
        self.assertEqual(ran, {"/a.swift": {4}, "/b.swift": {1}})

    def test_built_copies_map_to_the_checkout(self):
        for built, path in [
            ("/var/folders/x/meh-editor-performance.AbC123/sources/MarkdownEditor.swift", EDITOR),
            ("/tmp/native-editor-parity-work.X/current-package/Sources/NoteCore/A.swift",
             "Sources/NoteCore/A.swift"),
            (str(ROOT / "Tools/EditorQuoteCheck/EditorQuoteCheck.swift"),
             "Tools/EditorQuoteCheck/EditorQuoteCheck.swift"),
            (str(ROOT / ".build/checkouts/automerge-swift/A.swift"), None),
            ("/usr/lib/swift/A.swift", None),
        ]:
            with self.subTest(built):
                self.assertEqual(checkout_path(built), path)


class Repository(unittest.TestCase):
    def setUp(self):
        self.files = subprocess.run(
            ["git", "ls-files"], cwd=ROOT, check=True, capture_output=True, text=True,
        ).stdout.splitlines()
        self.workflow = (ROOT / ".github/workflows/editor-performance.yml").read_text()

    def test_every_listed_path_matches_a_tracked_file(self):
        patterns = ALL_STEPS + [p for step in STEPS.values() for p in step["paths"]]
        patterns += [step["anchor"] for step in STEPS.values()]
        for pattern in patterns:
            with self.subTest(pattern):
                self.assertTrue(any(matches(f, [pattern]) for f in self.files))

    def test_every_file_the_steps_use_belongs_to_one(self):
        """A script or fixture a step reads must run it when it changes."""
        sources = [".github/workflows/editor-performance.yml", ".github/workflows/editor-coverage.yml"]
        sources += [path for path in self.files if path.endswith((".sh", ".py")) and any(
            matches(path, STEPS[step]["paths"]) for step in STEPS
        )]
        used = set()
        for source in sources:
            text = (ROOT / source).read_text()
            used.update(re.findall(r"scripts/[\w./-]+\.(?:py|sh|json)", text))
            # Scripts that call siblings by name.
            used.update("scripts/" + name for name in re.findall(r"\b([\w-]+\.(?:py|sh))\b", text))
        for path in sorted(used & set(self.files)):
            # Tests run as gates; the diagnostic only runs by hand.
            if matches(path, [
                "scripts/test_*", "scripts/run_editor_performance_fresh_diagnostic.sh",
            ]):
                continue
            with self.subTest(path):
                steps, _ = select({path: {}}, {})
                self.assertTrue(any(steps.values()), path)

    def test_each_step_s_files_run_that_step(self):
        for step in STEPS:
            for path in self.files:
                if matches(path, STEPS[step]["paths"]) and not matches(path, ALL_STEPS):
                    with self.subTest(path):
                        steps, _ = select({path: {}}, {})
                        self.assertTrue(steps[step])

    def test_files_that_change_how_steps_run_run_every_step(self):
        for path in self.files:
            if matches(path, ALL_STEPS):
                with self.subTest(path):
                    steps, _ = select({path: {}}, {})
                    self.assertEqual(steps, {step: True for step in STEPS})

    def test_every_step_has_a_condition_in_the_workflow(self):
        for step in STEPS:
            with self.subTest(step):
                self.assertIn(f"fromJSON(needs.select.outputs.steps).{step}", self.workflow)

    def test_history_coverage_runs_every_size_the_workflow_runs(self):
        """Each size takes its own branches, so each needs coverage."""
        sizes = set(re.findall(r'MEH_HISTORY_BENCHMARK_LINES: "(\d+)"', self.workflow))
        recorded = {run["MEH_HISTORY_BENCHMARK_LINES"] for run in SWIFT["history"]["runs"]}
        self.assertEqual(recorded, sizes)

    def test_coverage_runs_the_workflow_s_swift_tests(self):
        """run_editor_coverage.py must run what the workflow runs, or the index lies."""
        runs = self.workflow + (ROOT / "scripts/run_parser_performance_ci.sh").read_text()
        self.assertEqual(set(SWIFT), {s for s in STEPS if "filter" in STEPS[s]})
        for step, settings in SWIFT.items():
            with self.subTest(step):
                release = "-c release " if settings["configuration"] == "release" else ""
                filter_ = re.escape(STEPS[step]["filter"])
                pattern = re.escape(f"swift test {release}") + rf"[^\n]*?\\?\s*--filter '?{filter_}'?\s"
                self.assertRegex(runs, pattern)
                for name in settings["environment"]:
                    self.assertIn(name, runs)
                for extra in settings.get("runs", []):
                    for name, value in extra.items():
                        self.assertIn(value if name == "filter" else f'{name}: "{value}"', runs)


if __name__ == "__main__":
    unittest.main()
