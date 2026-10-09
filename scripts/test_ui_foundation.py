import copy
import json
import re
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

from check_ui_foundation_results import (
    check,
    discovered,
    expected_cases,
)
from run_ui_foundation import (
    WATCHDOG_SECONDS,
    NATIVE_RETRY_ARGUMENTS,
    report_retries,
    bounded,
    finalize,
    select_simulator,
)


class FoundationTests(unittest.TestCase):
    def setUp(self):
        self.expected = {"Case/testA", "Case/testB"}
        self.summary = {
            "passedTests": 2,
            "totalTestCount": 2,
            "failedTests": 0,
            "skippedTests": 0,
            "expectedFailures": 0,
            "result": "Passed",
            "devicesAndConfigurations": [
                {
                    "device": {
                        "platform": "iOS Simulator",
                        "osVersion": "27.0",
                        "modelName": "iPhone 12 Pro Max",
                    }
                }
            ],
        }
        self.tests = {
            "testNodes": [
                {
                    "nodeType": "Test Case",
                    "result": "Passed",
                    "nodeIdentifier": x + "()",
                }
                for x in self.expected
            ]
        }

    def test_watchdogs_leave_export_and_cleanup_headroom(self):
        workflow = (
            Path(__file__).resolve().parents[1] / ".github/workflows/ui-regressions.yml"
        ).read_text()
        job_minutes = int(re.search(r"timeout-minutes: (\d+)", workflow)[1])
        # Two JSON exports, two simulator cleanup commands and four minutes
        # for metadata/setup must fit even if every major phase hits its cap.
        maximum_lane = (
            sum(
                WATCHDOG_SECONDS[key]
                for key in (
                    "startup",
                    "build",
                    "discovery",
                    "test",
                    "attachment_export",
                )
            )
            + 2 * WATCHDOG_SECONDS["json_export"]
            + 2 * WATCHDOG_SECONDS["cleanup"]
            + 240
        )
        self.assertGreaterEqual(job_minutes * 60 - maximum_lane, 600)
    def test_missing_simulator_prerequisites_report_actionable_errors(self):
        with self.assertRaisesRegex(ValueError, "available iOS 27 simulator runtime"):
            select_simulator({"runtimes": [], "devicetypes": []}, "iphone")
        runtime = {
            "isAvailable": True,
            "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
            "version": "27.0",
            "supportedDeviceTypes": [{"identifier": "supported-ipad"}],
        }
        unsupported_phone = {
            "name": "iPhone 12 Pro Max",
            "identifier": "unsupported-phone",
        }
        inventory = {"runtimes": [runtime], "devicetypes": [unsupported_phone]}
        with self.assertRaisesRegex(
            ValueError, "No iPhone 12 Pro Max device type supported"
        ):
            select_simulator(inventory, "iphone")
        with self.assertRaisesRegex(ValueError, "No iPad device type supported"):
            select_simulator(inventory, "ipad")

    def test_valid_exact_results(self):
        self.assertEqual(
            check(self.summary, self.tests, self.expected, "iphone"),
            {},
        )

    def retry_case(self):
        # Minimal shape observed in the standalone Xcode 27 XCTest probe.
        case = self.tests["testNodes"][0]
        case["nodeIdentifierURL"] = "test://com.apple.xcode/Probe/Case/testA"
        case["children"] = [
            {
                "nodeType": "Repetition", "nodeIdentifier": str(index),
                "nodeIdentifierURL": case["nodeIdentifierURL"],
                "name": name, "result": result,
            }
            for index, name, result in [
                (1, "First Run", "Failed"), (2, "Retry 1", "Passed")
            ]
        ]
        case["children"][0]["children"] = [{
            "nodeType": "Failure Message", "name": "Synthetic failure",
        }]
        return case

    def test_native_retry_is_bounded_and_reported(self):
        case = self.retry_case()
        retried = check(self.summary, self.tests, self.expected, "iphone")
        identifier = case["nodeIdentifier"].removesuffix("()")
        self.assertEqual(retried, {identifier: ["Failed", "Passed"]})
        manifest = {}
        with patch("run_ui_foundation.print") as output:
            report_retries(manifest, retried)
        self.assertEqual(manifest["retriedTests"], [identifier])
        self.assertIn("::warning", output.call_args.args[0])
        self.assertIn("Failed -> Passed", output.call_args.args[0])
        self.assertIn(identifier, output.call_args.args[0])
        self.assertEqual(NATIVE_RETRY_ARGUMENTS, [
            "-retry-tests-on-failure", "-test-iterations", "2",
            "-test-repetition-relaunch-enabled", "YES",
        ])

    def test_single_native_repetition_passes(self):
        case = self.retry_case()
        case["children"] = case["children"][:1]
        case["children"][0]["result"] = "Passed"
        self.assertEqual(check(self.summary, self.tests, self.expected, "iphone"), {})

    def test_native_retry_passed_then_passed_is_reported(self):
        case = self.retry_case()
        case["children"] = case["children"][:1] + [
            {
                "nodeType": "Repetition",
                "nodeIdentifier": "2",
                "nodeIdentifierURL": case["nodeIdentifierURL"],
                "name": "Retry 1",
                "result": "Passed",
            }
        ]
        case["children"][0]["result"] = "Passed"
        case["children"][0].pop("children")
        self.assertEqual(
            check(self.summary, self.tests, self.expected, "iphone"),
            {case["nodeIdentifier"].removesuffix("()"): ["Passed", "Passed"]},
        )

    def test_native_retry_passed_then_failed_is_reported(self):
        case = self.retry_case()
        case["children"][0]["result"] = "Passed"
        case["children"][0].pop("children")
        case["children"][1]["result"] = "Failed"
        identifier = case["nodeIdentifier"].removesuffix("()")
        retried = check(self.summary, self.tests, self.expected, "iphone")
        self.assertEqual(retried, {identifier: ["Passed", "Failed"]})
        manifest = {}
        with patch("run_ui_foundation.print") as output:
            report_retries(manifest, retried)
        self.assertEqual(manifest["retriedTests"], [identifier])
        self.assertIn("Passed -> Failed", output.call_args.args[0])

    def test_invalid_native_retries_fail_closed(self):
        for mutation in [
            "all_failed", "extra", "unknown", "duplicate_parent",
            "parent_failed", "skipped", "identifier", "url",
        ]:
            with self.subTest(mutation=mutation):
                self.setUp()
                case = self.retry_case()
                runs = case["children"]
                if mutation == "all_failed":
                    runs[0]["result"] = runs[1]["result"] = "Failed"
                elif mutation == "unknown":
                    runs[0]["result"] = "Unexpected"
                elif mutation == "parent_failed":
                    case["result"] = "Failed"
                elif mutation == "extra":
                    runs.append(copy.deepcopy(runs[1]))
                elif mutation == "duplicate_parent":
                    self.tests["testNodes"].append(copy.deepcopy(case))
                elif mutation == "skipped":
                    runs[0]["result"] = "Skipped"
                elif mutation == "identifier":
                    runs[1]["nodeIdentifier"] = "1"
                elif mutation == "url":
                    runs[1]["nodeIdentifierURL"] += "Different"
                with self.assertRaises(ValueError):
                    check(self.summary, self.tests, self.expected, "iphone")

    def test_missing_unexpected_duplicate_skipped_failed(self):
        for kind in ["missing", "unexpected", "duplicate", "skipped", "failed"]:
            with self.subTest(kind=kind):
                tests = copy.deepcopy(self.tests)
                if kind == "missing":
                    tests["testNodes"].pop()
                if kind == "unexpected":
                    tests["testNodes"][0]["nodeIdentifier"] = "Case/testC()"
                if kind == "duplicate":
                    tests["testNodes"][1] = tests["testNodes"][0]
                if kind in {"skipped", "failed"}:
                    tests["testNodes"][0]["result"] = kind.title()
                with self.assertRaises(ValueError):
                    check(self.summary, tests, self.expected, "iphone")

    def test_wrong_device_and_false_zero_pass(self):
        self.summary["devicesAndConfigurations"][0]["device"][
            "modelName"
        ] = "iPhone 17 Pro"
        with self.assertRaises(ValueError):
            check(self.summary, self.tests, self.expected, "iphone")
        with self.assertRaises(ValueError):
            check({}, {"testNodes": []}, set(), "iphone")

    def test_independent_discovery_and_missing_selector(self):
        universe = discovered(
            {
                "errors": [],
                "values": [
                    {
                        "testPlan": "CIUniverse",
                        "disabledTests": [],
                        "enabledTests": [
                            {"identifier": "meh.mdUITests/Case/testA()"},
                            {"identifier": "meh.mdUITests/Case/testB()"},
                        ],
                    }
                ],
            }
        )
        plan = {
            "testTargets": [
                {"target": {"name": "meh.mdUITests"}, "selectedTests": ["Case"]}
            ]
        }
        self.assertEqual(expected_cases(plan, universe), self.expected)
        plan["testTargets"][0]["selectedTests"] = ["Case/testMissing"]
        with self.assertRaises(ValueError):
            expected_cases(plan, universe)
        with self.assertRaises(ValueError):
            discovered({"unknown": ["Case/testA()"]})

    def test_process_group_timeout_is_bounded(self):
        with tempfile.TemporaryDirectory() as root:
            started = time.monotonic()
            with self.assertRaises(subprocess.TimeoutExpired):
                bounded(
                    [
                        sys.executable,
                        "-c",
                        'import subprocess,time; subprocess.Popen(["sleep","30"]); time.sleep(30)',
                    ],
                    0.15,
                    Path(root) / "timeout.log",
                )
            self.assertLess(time.monotonic() - started, 6)

    def test_process_output_is_streamed_and_saved(self):
        with tempfile.TemporaryDirectory() as root:
            log = Path(root) / "live.log"
            with patch("run_ui_foundation.sys.stdout") as output:
                captured = bounded(
                    [sys.executable, "-c", "print('native build output', flush=True)"],
                    5, log,
                )
            self.assertEqual(captured, "native build output\n")
            output.buffer.write.assert_called_with(b"native build output\n")
            output.buffer.flush.assert_called()

    def test_failed_process_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaises(RuntimeError):
                bounded(
                    [sys.executable, "-c", "raise SystemExit(3)"],
                    5,
                    Path(root) / "failed.log",
                )

    def test_observed_xcode27_compiled_enumeration_schema(self):
        fixture = Path(__file__).parent / "fixtures/ui_enumeration_xcode27.json"
        payload = json.loads(fixture.read_text())
        universe = discovered(payload)
        self.assertEqual(
            universe,
            {
                "EditorScrollTypingUITests/testSourceReopeningKeyboardNearEndRevealsCaret",
                "NotebookDragUITests/testSortDragResortAndRelaunchPreserveOrderAndSource",
                "WritingDurabilityUITests/testFormattedWritingUndoAndRelaunchPreserveExactNote",
            },
        )
        for mutation in ["errors", "disabled", "duplicate"]:
            altered = copy.deepcopy(payload)
            if mutation == "errors":
                altered["errors"] = ["discovery failed"]
            if mutation == "disabled":
                altered["values"][0]["disabledTests"] = [
                    altered["values"][0]["enabledTests"].pop()
                ]
            if mutation == "duplicate":
                altered["values"][0]["enabledTests"].append(
                    altered["values"][0]["enabledTests"][0]
                )
            with self.assertRaises(ValueError):
                discovered(altered)

    def test_cleanup_failure_cannot_pass_and_preserves_prior_error(self):
        snapshots = []
        manifest = {"cleanupErrors": ["delete failed"]}
        with self.assertRaisesRegex(RuntimeError, "cleanup failed"):
            finalize(manifest, True, lambda: snapshots.append(copy.deepcopy(manifest)))
        self.assertFalse(snapshots[0]["verified"])
        manifest["error"] = "TimeoutExpired: original test deadline"
        finalize(manifest, False, lambda: snapshots.append(copy.deepcopy(manifest)))
        self.assertEqual(
            snapshots[-1]["error"], "TimeoutExpired: original test deadline"
        )
        self.assertFalse(snapshots[-1]["verified"])

    def test_native_platform_enumeration_rejects_missing_selector(self):
        payload = {
            "errors": [],
            "values": [{
                "testPlan": "CIIPhone", "disabledTests": [],
                "enabledTests": [{"identifier": "meh.mdUITests/Case/testA()"}],
            }],
        }
        plan = {"testTargets": [{
            "target": {"name": "meh.mdUITests"},
            "selectedTests": ["Case/testA", "Case/testMissing"],
        }]}
        with self.assertRaisesRegex(ValueError, "absent from compiled"):
            expected_cases(plan, discovered(payload, "CIIPhone"))
        with self.assertRaises(ValueError):
            discovered(payload, "CIMac")


if __name__ == "__main__":
    unittest.main()
