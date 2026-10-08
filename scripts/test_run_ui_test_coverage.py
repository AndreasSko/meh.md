"""Guard explicit test selection independently of Xcode or simulator state."""
import copy
import json
from pathlib import Path
import signal
import tempfile
import unittest
from urllib.error import URLError
from urllib.request import urlopen
from unittest.mock import patch

from run_ui_test_coverage import (loopback_fixture, macos_runner_path, require_available_macos_ui, select_runtime_device, selected_plan,
                                  standard_identifiers, stop_owned_macos_apps, targets)


class UIPlanTests(unittest.TestCase):
    def test_loopback_fixture_serves_real_routes_and_closes_after_failure(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            with self.assertRaisesRegex(RuntimeError, "UI phase failed"), \
                    patch("socket.getfqdn", side_effect=AssertionError("Unexpected DNS lookup")):
                with loopback_fixture(root / "server", root / "loopback.log") as endpoint:
                    with urlopen(endpoint + "/v1/records?scope=fictional", timeout=2) as response:
                        self.assertEqual(json.load(response)["records"], [])
                    raise RuntimeError("UI phase failed")
            self.assertIn("scope=fictional", (root / "loopback.log").read_text())
            with self.assertRaises(URLError):
                urlopen(endpoint + "/v1/records?scope=fictional", timeout=2)
            # Closing also releases the real data-directory lock.
            with loopback_fixture(root / "server", root / "second.log"):
                pass

    def test_macos_signing_rejects_a_runner_outside_owned_products(self):
        with tempfile.TemporaryDirectory() as temp:
            products = Path(temp) / "Products"
            runner = products / "Debug/meh.mdUITests-Runner.app"
            runner.mkdir(parents=True)
            plan = {"UI": {"BlueprintName": "meh.mdUITests",
                            "TestHostPath": "__TESTROOT__/Debug/meh.mdUITests-Runner.app"}}
            self.assertEqual(macos_runner_path(products, plan), runner.resolve())
            plan["UI"]["TestHostPath"] = str(products / "../meh.mdUITests-Runner.app")
            with self.assertRaisesRegex(ValueError, "disposable"):
                macos_runner_path(products, plan)

    def test_macos_cleanup_only_terminates_its_exact_product_namespace(self):
        with tempfile.TemporaryDirectory() as temp:
            products = Path(temp) / "Products"
            products.mkdir()
            processes = (f"101 {products}/Debug/Runner.app/Contents/MacOS/Runner\n"
                         f"102 {products}-other/Debug/Runner\n"
                         "103 /Applications/Other.app/Contents/MacOS/Other\n")
            with patch("run_ui_test_coverage.capture", return_value=processes), \
                    patch("run_ui_test_coverage.os.kill") as kill, \
                    patch("run_ui_test_coverage.time.sleep"):
                stop_owned_macos_apps(products)
            self.assertEqual(kill.call_args_list, [unittest.mock.call(101, signal.SIGTERM),
                                                   unittest.mock.call(101, signal.SIGKILL)])
            with patch("run_ui_test_coverage.capture", side_effect=[processes, "101 /Applications/Other.app/Runner"]), \
                    patch("run_ui_test_coverage.os.kill") as kill, \
                    patch("run_ui_test_coverage.time.sleep"):
                stop_owned_macos_apps(products)
            kill.assert_called_once_with(101, signal.SIGTERM)
            harmless = (f"101 {products}/Debug/meh.mdUITests-Runner.app/Contents/MacOS/Runner\n"
                        "102 /bin/zsh\n103 /usr/bin/python3\n"
                        "/bin/zsh -c /other/meh.mdUITests-Runner.app/Contents/MacOS/Runner\n"
                        "104 /tmp/Debug-iphonesimulator/meh.mdUITests-Runner.app/Contents/MacOS/Runner\n"
                        "105 /Users/test/Library/Developer/CoreSimulator/Devices/A/data/Containers/Bundle/Application/B/meh.md iCloud Dev.app/Contents/MacOS/meh.md iCloud Dev\n"
                        "106 /Applications/Other.app/Contents/MacOS/Other\n")
            with patch("run_ui_test_coverage.capture", return_value=harmless), \
                    patch("run_ui_test_coverage.os.kill") as kill:
                require_available_macos_ui(products)
                kill.assert_not_called()
            for executable in (
                "/tmp/another/Debug/meh.mdUITests-Runner.app/Contents/MacOS/Runner",
                "/Applications/meh.md iCloud Dev.app/Contents/MacOS/meh.md iCloud Dev",
            ):
                with patch("run_ui_test_coverage.capture", return_value=f"201 {executable}"), \
                        patch("run_ui_test_coverage.os.kill") as kill:
                    with self.assertRaisesRegex(RuntimeError, "PID 201"):
                        require_available_macos_ui(products)
                    kill.assert_not_called()

    def test_device_selection_rejects_unsupported_old_ipad(self):
        listing = {"runtimes": [{"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
                                  "version": "27.0", "isAvailable": True}],
                   "devicetypes": [
                       {"identifier": "modern", "name": "iPad Pro", "minRuntimeVersion": 26 << 16,
                        "maxRuntimeVersion": 0xffffffff},
                       {"identifier": "old", "name": "iPad mini 4", "minRuntimeVersion": 9 << 16,
                        "maxRuntimeVersion": 15 << 16}]}
        runtime, device = select_runtime_device(listing, "ipad")
        self.assertEqual(device["identifier"], "modern")
        listing["devicetypes"].pop(0)
        with self.assertRaisesRegex(RuntimeError, "compatible"):
            select_runtime_device(listing, "ipad")

    def test_only_applicable_standard_methods_enter_bulk_phase(self):
        records = [
            {"id": "visible", "category": "standard", "expected_skip": False},
            {"id": "wrong-device", "category": "standard", "expected_skip": True},
            {"id": "cloud", "category": "live-icloud", "expected_skip": False},
            {"id": "ordered", "category": "ordered-loopback", "expected_skip": False},
            {"id": "picker", "category": "import-fixture", "expected_skip": False},
        ]
        self.assertEqual(standard_identifiers(records), ["visible"])

    def test_overrides_cloud_scheme_and_skip_defaults_in_both_schemas(self):
        target = {
            "BlueprintName": "meh.mdUITests",
            "OnlyTestIdentifiers": ["ICloudDevelopmentUITests"],
            "SkipTestIdentifiers": ["WritingFlowUITests"],
            "EnvironmentVariables": {"Existing": "value"},
        }
        for original in (
            {"UI": target},
            {"TestConfigurations": [{"TestTargets": [target]}]},
        ):
            with self.subTest(schema=list(original)):
                before = copy.deepcopy(original)
                plan = selected_plan(original, ["meh.mdUITests/WritingFlowUITests/testSync"],
                                     {"MEH_CI_SYNC_PORT": "1234"})
                selected = targets(plan)[0]
                self.assertEqual(selected["OnlyTestIdentifiers"],
                                 ["WritingFlowUITests/testSync"])
                self.assertNotIn("SkipTestIdentifiers", selected)
                self.assertFalse(selected["ParallelizationEnabled"])
                self.assertEqual(selected["EnvironmentVariables"]["Existing"], "value")
                for key in ("EnvironmentVariables", "TestingEnvironmentVariables"):
                    self.assertEqual(selected[key]["MEH_CI_SYNC_PORT"],
                                     "1234")
                self.assertEqual(original, before)

    def test_empty_unknown_target_or_missing_ui_target_fails_closed(self):
        for selection in ([], ["OtherTests/Class/testMethod"]):
            with self.assertRaises(ValueError):
                selected_plan({}, selection, {})
        with self.assertRaises(ValueError):
            selected_plan({"Other": {"BlueprintName": "OtherTests"}},
                          ["meh.mdUITests/Class/testMethod"], {})


if __name__ == "__main__":
    unittest.main()
