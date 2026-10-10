import copy
from pathlib import Path
import unittest

from check_editor_regression_results import (
    NATIVE_CLASSES, NATIVE_REQUIRED_METHODS, UI_METHODS, check,
)


def valid_results(phase="native"):
    if phase == "native":
        cases = sorted(NATIVE_REQUIRED_METHODS)
        required_classes = {case.split("/")[0] for case in cases}
        for name, count in NATIVE_CLASSES.items():
            if name not in required_classes:
                cases.extend(f"{name}/testFixture{index}()" for index in range(count))
    else:
        cases = sorted(UI_METHODS)
    summary = {
        "passedTests": len(cases), "failedTests": 0, "skippedTests": 0,
        "expectedFailures": 0, "totalTestCount": len(cases), "result": "Passed",
        "devicesAndConfigurations": [{"device": {
            "modelName": "iPhone 12 Pro Max", "platform": "iOS Simulator",
            "osVersion": "27.0",
        }}],
    }
    tests = {"testNodes": [{"nodeType": "Test Suite", "children": [
        {"nodeType": "Test Case", "nodeIdentifier": case, "result": "Passed"}
        for case in cases
    ]}]}
    return summary, tests


class CheckEditorRegressionResultsTests(unittest.TestCase):
    def test_accepts_all_47_native_and_5_ui_cases(self):
        for phase, count in (("native", 47), ("ui", 5)):
            with self.subTest(phase=phase):
                self.assertEqual(len(check(phase, *valid_results(phase))), count)

    def test_rejects_old_native_selection_even_with_passing_summary(self):
        summary, tests = valid_results()
        nodes = tests["testNodes"][0]["children"]
        nodes[:] = [node for node in nodes
                    if node["nodeIdentifier"] not in NATIVE_REQUIRED_METHODS]
        summary["passedTests"] = summary["totalTestCount"] = len(nodes)
        with self.assertRaisesRegex(ValueError, "passedTests must be 47"):
            check("native", summary, tests)

    def test_rejects_missing_replaced_or_duplicate_required_methods(self):
        for mutation in ("missing", "replaced", "duplicate"):
            with self.subTest(mutation=mutation):
                summary, tests = valid_results()
                nodes = tests["testNodes"][0]["children"]
                if mutation == "missing":
                    nodes.pop(0)
                elif mutation == "replaced":
                    nodes[0]["nodeIdentifier"] = "MarkdownNativeTextChangeTests/testOther()"
                else:
                    nodes[0]["nodeIdentifier"] = nodes[1]["nodeIdentifier"]
                with self.assertRaises(ValueError):
                    check("native", summary, tests)

    def test_rejects_failed_skipped_and_expected_failure_cases(self):
        for result in ("Failed", "Skipped", "Expected Failure"):
            with self.subTest(result=result):
                summary, tests = valid_results()
                tests["testNodes"][0]["children"][0]["result"] = result
                with self.assertRaisesRegex(ValueError, "test did not pass"):
                    check("native", summary, tests)

    def test_rejects_nonpassing_or_incomplete_summary(self):
        for field in ("passedTests", "failedTests", "skippedTests",
                      "expectedFailures", "totalTestCount", "result"):
            with self.subTest(field=field):
                summary, tests = valid_results()
                summary.pop(field)
                with self.assertRaises(ValueError):
                    check("native", summary, tests)

    def test_rejects_wrong_class_count_or_ui_selection(self):
        for phase in ("native", "ui"):
            with self.subTest(phase=phase):
                summary, tests = valid_results(phase)
                tests["testNodes"][0]["children"][0]["nodeIdentifier"] = "Other/testOther()"
                with self.assertRaises(ValueError):
                    check(phase, summary, tests)

    def test_rejects_missing_identifier(self):
        summary, tests = valid_results()
        tests["testNodes"][0]["children"][0].pop("nodeIdentifier")
        with self.assertRaisesRegex(ValueError, "missing or invalid identifier"):
            check("native", summary, tests)

    def test_rejects_wrong_or_multiple_simulator_configurations(self):
        original, tests = valid_results()
        for field, value in (("modelName", "iPhone 18 Pro"),
                             ("platform", "macOS"), ("osVersion", "26.0")):
            with self.subTest(field=field):
                summary = copy.deepcopy(original)
                summary["devicesAndConfigurations"][0]["device"][field] = value
                with self.assertRaisesRegex(ValueError, "unexpected simulator"):
                    check("native", summary, tests)
        for configurations in ([], original["devicesAndConfigurations"] * 2):
            summary = copy.deepcopy(original)
            summary["devicesAndConfigurations"] = configurations
            with self.assertRaisesRegex(ValueError, "one simulator configuration"):
                check("native", summary, tests)

    def test_rejects_unknown_phase(self):
        with self.assertRaisesRegex(ValueError, "unexpected phase"):
            check("other", *valid_results())


if __name__ == "__main__":
    unittest.main()
