import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from check_native_editor_baseline_parity import CURRENT_INVARIANT_METHODS, REQUIRED_METHODS, compare, inspect


def results(failing=(), skipped=(), additional=()):
    names = (REQUIRED_METHODS | {"OtherNativeTests/testOrdinaryEditing()"}
             | {f"SyntheticNativeTests/testExisting{index}()" for index in range(236)}
             | set(additional))
    nodes = [{"nodeType": "Test Case", "nodeIdentifier": name,
              "result": "Failed" if name in failing else
              "Skipped" if name in skipped else "Passed"} for name in sorted(names)]
    summary = {
        "totalTestCount": len(nodes), "passedTests": len(nodes) - len(failing) - len(skipped),
        "failedTests": len(failing), "skippedTests": len(skipped), "expectedFailures": 0,
        "result": "Failed" if failing else "Passed",
        "devicesAndConfigurations": [{"device": {
            "modelName": "iPhone 18 Pro", "platform": "iOS Simulator", "osVersion": "27.0",
        }}],
    }
    return summary, {"testNodes": [{"nodeType": "Test Suite", "children": nodes}]}, 65 if failing else 0


def current_results(failing=(), skipped=(), additional=()):
    return results(failing, skipped, CURRENT_INVARIANT_METHODS | set(additional))


class NativeBaselineParityTests(unittest.TestCase):
    def test_reports_existing_method_failures_and_allows_new_passing_tests(self):
        baseline = results(failing=REQUIRED_METHODS)
        current = current_results(failing=REQUIRED_METHODS,
                          additional={"NewNativeTests/testLiteralSelection()"})
        old, failed, skipped = compare(*baseline, *current)
        self.assertEqual(old, REQUIRED_METHODS)
        self.assertEqual(failed, REQUIRED_METHODS)
        self.assertEqual(skipped, set())
        self.assertEqual(compare(*baseline, *current_results())[1], set())

    def test_rejects_new_failure_or_removed_baseline_method(self):
        with self.assertRaisesRegex(ValueError, "NEW current"):
            compare(*results(), *current_results(failing=REQUIRED_METHODS))
        with self.assertRaisesRegex(ValueError, "omitted baseline"):
            baseline = results()
            current = current_results()
            next(node for node in current[1]["testNodes"][0]["children"]
                 if node["nodeIdentifier"] == "OtherNativeTests/testOrdinaryEditing()")[
                     "nodeIdentifier"] = "ReplacedTests/testUnexpected()"
            compare(*baseline, *current)

    def test_rejects_new_skip_but_reports_existing_opt_in_skip(self):
        skip = {"OtherNativeTests/testOrdinaryEditing()"}
        self.assertEqual(compare(*results(skipped=skip), *current_results(skipped=skip))[2], skip)
        with self.assertRaisesRegex(ValueError, "new skipped"):
            compare(*results(), *current_results(skipped=skip))
        with self.assertRaisesRegex(ValueError, "must execute"):
            inspect(*results(skipped=REQUIRED_METHODS))

    def test_truncated_suite_and_missing_new_invariants_fail_closed(self):
        summary, tree, status = results(failing=REQUIRED_METHODS)
        tree["testNodes"][0]["children"] = [
            node for node in tree["testNodes"][0]["children"]
            if node["nodeIdentifier"] in REQUIRED_METHODS]
        summary.update(totalTestCount=3, passedTests=0, failedTests=3)
        with self.assertRaisesRegex(ValueError, "exactly 240"):
            compare(summary, tree, status, *current_results())
        with self.assertRaisesRegex(ValueError, "at least 245"):
            compare(*results(), *results())
        current = current_results()
        nodes = current[1]["testNodes"][0]["children"]
        next(node for node in nodes if node["nodeIdentifier"] in
             CURRENT_INVARIANT_METHODS)["nodeIdentifier"] = "SyntheticTests/testReplacement()"
        with self.assertRaisesRegex(ValueError, "five new invariants"):
            compare(*results(), *current)
        with self.assertRaisesRegex(ValueError, "must pass"):
            compare(*results(), *current_results(failing=CURRENT_INVARIANT_METHODS))

    def test_missing_summary_tree_and_duplicate_cases_fail_closed(self):
        for field in ("totalTestCount", "passedTests", "failedTests", "skippedTests",
                      "expectedFailures", "devicesAndConfigurations"):
            summary, tree, status = results()
            summary.pop(field)
            with self.assertRaises(ValueError):
                inspect(summary, tree, status)
        summary, tree, status = results()
        tree["testNodes"][0]["children"].append(copy.deepcopy(tree["testNodes"][0]["children"][0]))
        with self.assertRaisesRegex(ValueError, "duplicate"):
            inspect(summary, tree, status)
        for tree in ({}, {"testNodes": []}, [], {"testNodes": [{"nodeType": "Test Case"}]}):
            with self.assertRaises(ValueError):
                inspect(results()[0], tree, 0)

    def test_infrastructure_status_result_and_device_mismatch_fail(self):
        for status in (65, 70, 124, 143):
            with self.assertRaisesRegex(ValueError, "infrastructure"):
                inspect(*results()[:2], status)
        summary, tree, status = results(failing=REQUIRED_METHODS)
        with self.assertRaises(ValueError):
            inspect(summary, tree, 0)
        summary["result"] = "Passed"
        with self.assertRaisesRegex(ValueError, "result disagrees"):
            inspect(summary, tree, status)
        for field, value in (("osVersion", "27.1"), ("modelName", "iPhone 12 Pro Max"),
                             ("platform", "iOS")):
            summary, tree, status = results()
            summary["devicesAndConfigurations"][0]["device"][field] = value
            with self.assertRaisesRegex(ValueError, "configuration"):
                inspect(summary, tree, status)

    def test_cli_preserves_distinct_baseline_report_and_rejects_missing_bundle_export(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for label in ("baseline", "current"):
                fixture = results if label == "baseline" else current_results
                summary, tree, status = fixture(failing=REQUIRED_METHODS)
                (root / f"{label}-summary.json").write_text(json.dumps(summary))
                (root / f"{label}-tests.json").write_text(json.dumps(tree))
                (root / f"{label}-status.txt").write_text(str(status))
            command = [sys.executable, str(Path(__file__).with_name(
                "check_native_editor_baseline_parity.py")), str(root)]
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("BASELINE failing methods:", result.stdout)
            self.assertIn("CURRENT existing failing methods:", result.stdout)
            (root / "current-tests.json").unlink()
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)


if __name__ == "__main__":
    unittest.main()
