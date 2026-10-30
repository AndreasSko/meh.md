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
    failed,
    results,
)
from run_ui_foundation import (
    WATCHDOG_SECONDS,
    report_retries,
    retry_arguments,
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
        # Both passes' exports, two simulator cleanup commands and four minutes
        # for metadata/setup must fit even if every major phase hits its cap.
        maximum_lane = (
            sum(
                WATCHDOG_SECONDS[key]
                for key in (
                    "startup",
                    "build",
                    "discovery",
                    "test",
                    "retry",
                )
            )
            + 2 * WATCHDOG_SECONDS["attachment_export"]
            + 4 * WATCHDOG_SECONDS["json_export"]
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

    def test_device_specific_point_runtime_falls_back_to_older_runtime(self):
        general = {
            "isAvailable": True,
            "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
            "version": "27.0",
            "supportedDeviceTypes": [{"identifier": "phone"}, {"identifier": "ipad"}],
        }
        duo_only = {
            "isAvailable": True,
            "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-1",
            "version": "27.1",
            "supportedDeviceTypes": [{"identifier": "duo"}],
        }
        inventory = {
            "runtimes": [general, duo_only],
            "devicetypes": [
                {"name": "iPhone Duo", "identifier": "duo"},
                {"name": "iPhone 12 Pro Max", "identifier": "phone"},
                {"name": "iPad Air 11-inch (M4)", "identifier": "ipad"},
            ],
        }
        for platform, identifier in (("iphone", "phone"), ("ipad", "ipad")):
            runtime, device = select_simulator(inventory, platform)
            self.assertEqual(runtime, general)
            self.assertEqual(device["identifier"], identifier)

    def test_valid_exact_results(self):
        first = results(self.summary, self.tests, "iphone")
        self.assertEqual(first, {case: "Passed" for case in self.expected})
        self.assertEqual(check(first, self.expected), {})

    def fail(self, summary, tests, case):
        node = next(
            n for n in tests["testNodes"] if n["nodeIdentifier"] == case + "()"
        )
        node["result"] = "Failed"
        summary["passedTests"] -= 1
        summary["failedTests"] += 1
        summary["result"] = "Failed"

    def test_only_failed_cases_are_retried_and_reported(self):
        self.fail(self.summary, self.tests, "Case/testA")
        first = results(self.summary, self.tests, "iphone")
        self.assertEqual(failed(first, self.expected), {"Case/testA"})
        self.assertEqual(
            retry_arguments({"Case/testA"}),
            ["-only-testing:meh.mdUITests/Case/testA"],
        )
        retry = {"Case/testA": "Passed"}
        retried = check(first, self.expected, retry)
        self.assertEqual(retried, {"Case/testA": ["Failed", "Passed"]})
        manifest = {}
        with patch("run_ui_foundation.print") as output:
            report_retries(manifest, retried)
        self.assertEqual(manifest["retriedTests"], ["Case/testA"])
        self.assertIn("::warning", output.call_args.args[0])
        self.assertIn("Case/testA: Failed -> Passed", output.call_args.args[0])

    def test_invalid_retries_fail_closed(self):
        first = {"Case/testA": "Failed", "Case/testB": "Passed"}
        for name, retry in {
            "missing retry": None,
            "failed again": {"Case/testA": "Failed"},
            "extra case": {"Case/testA": "Passed", "Case/testB": "Passed"},
            "other case": {"Case/testB": "Passed"},
        }.items():
            with self.subTest(name):
                with self.assertRaises(ValueError):
                    check(first, self.expected, retry)
        with self.assertRaises(ValueError):
            check({c: "Passed" for c in self.expected}, self.expected, {})

    def test_native_repetitions_are_rejected(self):
        case = self.tests["testNodes"][0]
        case["children"] = [{"nodeType": "Repetition", "result": "Passed"}]
        with self.assertRaisesRegex(ValueError, "native repetition"):
            results(self.summary, self.tests, "iphone")

    def test_summary_must_match_case_results(self):
        self.tests["testNodes"][0]["result"] = "Failed"
        with self.assertRaises(ValueError):
            results(self.summary, self.tests, "iphone")

    def test_missing_unexpected_duplicate_skipped(self):
        for kind in ["missing", "unexpected", "duplicate", "skipped"]:
            with self.subTest(kind=kind):
                summary = copy.deepcopy(self.summary)
                tests = copy.deepcopy(self.tests)
                if kind == "missing":
                    tests["testNodes"].pop()
                    summary["passedTests"] = summary["totalTestCount"] = 1
                if kind == "unexpected":
                    tests["testNodes"][0]["nodeIdentifier"] = "Case/testC()"
                if kind == "duplicate":
                    tests["testNodes"][1] = tests["testNodes"][0]
                if kind == "skipped":
                    tests["testNodes"][0]["result"] = "Skipped"
                with self.assertRaises(ValueError):
                    check(results(summary, tests, "iphone"), self.expected)

    def test_wrong_device_and_false_zero_pass(self):
        self.summary["devicesAndConfigurations"][0]["device"][
            "modelName"
        ] = "iPhone 17 Pro"
        with self.assertRaises(ValueError):
            results(self.summary, self.tests, "iphone")
        with self.assertRaises(ValueError):
            check({}, set())

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
