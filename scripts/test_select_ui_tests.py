import json
import subprocess
import unittest

from select_ui_tests import (
    FULL,
    IMPACT,
    PLANS,
    PROJECT,
    ROOT,
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


class SelectionTests(unittest.TestCase):
    def setUp(self):
        self.impact = json.loads(IMPACT.read_text())

    def chosen(self, changes, platform="iphone", diff="", new=frozenset()):
        return select(changes, platform, self.impact, diff, new)[0]

    def test_docs_and_unit_tests_need_no_ui_goal(self):
        for platform in PLANS:
            self.assertEqual(
                self.chosen({"README.md", "docs/plan.md", "Tests/NoteCoreTests/A.swift"},
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

    def test_new_and_renamed_files_run_the_whole_plan(self):
        for path in ["meh.md/MarkdownNewThing.swift", "meh.mdUITests/FlairUITests.swift"]:
            with self.subTest(path):
                self.assertIs(self.chosen({path}, new={path}), FULL)
        # New docs still need no UI goal.
        self.assertEqual(self.chosen({"docs/new.md"}, new={"docs/new.md"}), set())

    def test_other_project_changes_run_the_whole_plan(self):
        diff = VERSION_BUMP + "+\t\t\t\tSWIFT_VERSION = 6.0;\n"
        self.assertFalse(version_only(diff))
        self.assertIs(self.chosen({PROJECT}, diff=diff), FULL)
        self.assertIs(self.chosen({PROJECT}), FULL)

    def test_unmapped_and_harness_files_run_the_whole_plan(self):
        for path in [
            "meh.md/NotebookView.swift",
            "meh.md/SomethingNew.swift",
            "meh.mdUITests/NotebookUITestSupport.swift",
            "scripts/run_ui_foundation.py",
            "TestPlans/CIIPhone.xctestplan",
            ".github/workflows/ui-regressions.yml",
        ]:
            with self.subTest(path):
                self.assertIs(self.chosen({path, "README.md"}), FULL)

    def test_area_runs_its_goals_and_smoke(self):
        chosen = self.chosen({"meh.md/NotebookStorageView.swift"})
        cases = plan_cases("iphone")
        self.assertEqual(
            chosen,
            expand(["NotebookStorageUITests", *self.impact["smoke"]], cases),
        )
        self.assertLess(len(chosen), len(cases))

    def test_area_goals_missing_from_a_plan_are_dropped(self):
        # iPad has no Storage goal, so only the smoke tests remain.
        self.assertEqual(
            self.chosen({"meh.md/NotebookStorageView.swift"}, "ipad"),
            expand(self.impact["smoke"], plan_cases("ipad")),
        )

    def test_platform_specific_area(self):
        path = "meh.md/NotebookBrowserNativeAppKitDrag.swift"
        self.assertEqual(self.chosen({path}, "iphone"), set())
        self.assertTrue(
            expand(["NotebookDragUITests"], plan_cases("mac"))
            <= self.chosen({path}, "mac")
        )

    def test_file_in_two_areas_runs_both(self):
        chosen = self.chosen({"meh.md/MarkdownHistoryMarks.swift"})
        cases = plan_cases("iphone")
        self.assertTrue(expand(["NoteHistoryUITests", "EditorScrollTypingUITests"], cases)
                        <= chosen)

    def test_class_entries_in_a_plan_stay_whole(self):
        # CIMac lists MacFormattingUITests as a class; the runner expands it.
        self.assertIn("MacFormattingUITests",
                      self.chosen({"meh.md/MarkdownEditor.swift"}, "mac"))

    def test_ui_test_file_runs_its_own_goals(self):
        self.assertEqual(
            self.chosen({"meh.mdUITests/FlairUITests.swift"}),
            expand(["FlairUITests"], plan_cases("iphone")),
        )
        # A nightly-only class has no PR goal to run.
        self.assertEqual(self.chosen({"meh.mdUITests/NotebookTrashUITests.swift"}), set())

    def test_globs(self):
        self.assertTrue(matches("meh.md/MarkdownEditor.swift", ["meh.md/Markdown*.swift"]))
        self.assertFalse(matches("meh.md/a/MarkdownEditor.swift", ["meh.md/Markdown*.swift"]))
        self.assertTrue(matches("Tools/Import/README.md", ["**.md"]))
        self.assertFalse(matches("meh.md/Welcome.md", self.impact["noUIImpact"]))
        self.assertTrue(matches("docs/a/b.png", ["docs/**"]))
        self.assertFalse(matches("docsx/a.png", ["docs/**"]))


class ImpactMapTests(unittest.TestCase):
    """Fail when a rename or removal leaves the map pointing at nothing."""

    def setUp(self):
        self.impact = json.loads(IMPACT.read_text())
        self.files = subprocess.run(
            ["git", "ls-files"], cwd=ROOT, check=True, capture_output=True, text=True,
        ).stdout.splitlines()

    def test_every_path_matches_a_tracked_file(self):
        patterns = self.impact["fullRun"] + self.impact["noUIImpact"] + [
            path for area in self.impact["areas"] for path in area["paths"]
        ]
        for pattern in patterns:
            with self.subTest(pattern):
                self.assertTrue(any(matches(f, [pattern]) for f in self.files))

    def test_every_test_selector_is_a_pr_goal(self):
        for area in self.impact["areas"]:
            for selector in area["tests"]:
                with self.subTest(area=area["name"], selector=selector):
                    self.assertTrue(any(
                        expand([selector], plan_cases(platform))
                        for platform in area.get("platforms", PLANS)
                    ))

    def test_smoke_tests_run_on_every_platform(self):
        for platform in PLANS:
            for selector in self.impact["smoke"]:
                with self.subTest(platform=platform, selector=selector):
                    self.assertTrue(expand([selector], plan_cases(platform)))

    def test_area_platforms_are_known(self):
        for area in self.impact["areas"]:
            self.assertLessEqual(set(area.get("platforms", PLANS)), set(PLANS))


if __name__ == "__main__":
    unittest.main()
