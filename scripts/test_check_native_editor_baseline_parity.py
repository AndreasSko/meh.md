"""Exercise the recorded native inventory contract."""

import copy
import json
from pathlib import Path
import unittest

from scripts.check_native_editor_baseline_parity import INVENTORY, RETIRED_METHODS, compare


def results(extra=(), skipped=None, failed=()):
    inventory = json.loads(INVENTORY.read_text())
    if skipped is None:
        skipped = set(inventory["allowedSkips"])
    names = set(inventory["methods"]) | set(extra)
    cases = sorted(names)
    nodes = [{"nodeType": "Test Case", "nodeIdentifier": name,
              "result": "Skipped" if name in skipped else
              "Failed" if name in failed else "Passed"} for name in cases]
    skip_count, fail_count = len(skipped), len(failed)
    summary = {"totalTestCount": len(nodes), "passedTests": len(nodes) - skip_count - fail_count,
               "failedTests": fail_count, "skippedTests": skip_count, "expectedFailures": 0,
               "result": "Failed" if fail_count else "Passed", "runtimeWarnings": [],
               "testFailures": [], "devicesAndConfigurations": [{"device": {
                   "modelName": "iPhone 18 Pro", "platform": "iOS Simulator", "osVersion": "27.0"}}]}
    return inventory, summary, {"testNodes": [{"nodeType": "Test Suite", "children": nodes}]}, 0


class RecordedInventoryTests(unittest.TestCase):
    def test_approved_inventory_and_future_passing_addition(self):
        args = results(extra={"NewNativeTests/testFutureCoverage()"})
        self.assertEqual(compare(*args)[0], set(args[0]["methods"]))

    def test_rejects_omission_and_count_preserving_replacement(self):
        inventory, summary, tree, status = results()
        cases = tree["testNodes"][0]["children"]
        cases.pop(0)
        cases.append({"nodeType": "Test Case", "nodeIdentifier": "Replacement/testSameCount()",
                      "result": "Passed"})
        summary["totalTestCount"] = len(cases)
        summary["passedTests"] = len(cases) - summary["skippedTests"]
        with self.assertRaisesRegex(ValueError, "omitted recorded"):
            compare(inventory, summary, tree, status)

    def test_rejects_duplicate_failure_unapproved_skip_and_bad_status(self):
        inventory, summary, tree, status = results()
        tree["testNodes"][0]["children"].append(
            copy.deepcopy(tree["testNodes"][0]["children"][0]))
        with self.assertRaisesRegex(ValueError, "duplicate"):
            compare(inventory, summary, tree, status)
        for kwargs, expected in (({"failed": {inventory["methods"][0]}}, "failed"),
                                 ({"skipped": {inventory["methods"][0]}}, "new skipped")):
            with self.subTest(expected=expected):
                with self.assertRaisesRegex(ValueError, expected):
                    compare(*results(**kwargs))
        args = results()
        with self.assertRaisesRegex(ValueError, "infrastructure status"):
            compare(args[0], args[1], args[2], 65)

    def test_opt_in_pass_and_informational_warning_do_not_fail(self):
        args = results(skipped=set())
        args[1]["runtimeWarnings"] = [{"message": "Informational runtime warning"}]
        compare(*args)

    def test_empty_inventory_and_unknown_allowed_skip_fail(self):
        for fields in ({"methods": []}, {"allowedSkips": ["Unknown/testMissing()"]}):
            args = results()
            args[0].update(fields)
            with self.assertRaises(ValueError):
                compare(*args)

    def test_retired_methods_stay_absent(self):
        args = results(extra=RETIRED_METHODS)
        with self.assertRaisesRegex(ValueError, "retired methods"):
            compare(*args)


if __name__ == "__main__":
    unittest.main()
