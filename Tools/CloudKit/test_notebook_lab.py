import plistlib
import json
import subprocess
import tempfile
from pathlib import Path
import unittest
from unittest.mock import patch

from run_notebook_lab import BUNDLE, CONTAINER, TEAM, read_lab_log, verify
from run_notebook_lab_simulator import (
    check_existing_app, check_simulator, ensure_fresh_phase, lab_report_path,
    read_lab_report,
)


class LabLaunchGuardTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.app = Path(self.temporary.name) / "Lab.app"
        (self.app / "Contents/MacOS").mkdir(parents=True)
        self.info = {"CFBundleIdentifier": BUNDLE, "CFBundleExecutable": "Lab", "CFBundleSupportedPlatforms": ["MacOSX"]}
        self.entitlements = {
            "com.apple.developer.icloud-container-environment": "Development",
            "com.apple.developer.icloud-container-identifiers": [CONTAINER],
        }
        self.symbols = b"T _$sExample18NotebookSyncLabAppV5$mainyyFZ"

    def run_verify(self, **kwargs):
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(self.info))

        def fake_command(*args):
            if args[0] == "nm":
                return subprocess.CompletedProcess(args, 0, self.symbols, b"")
            if "--entitlements" in args:
                return subprocess.CompletedProcess(args, 0, plistlib.dumps(self.entitlements), b"")
            return subprocess.CompletedProcess(args, 0, b"", b"")

        with patch("run_notebook_lab.command", side_effect=fake_command):
            return verify(self.app, **kwargs)

    def test_accepts_only_explicit_lab_entry_with_development_entitlements(self):
        executable, _ = self.run_verify()
        self.assertEqual(executable, self.app / "Contents/MacOS/Lab")

    def test_rejects_production_or_missing_environment(self):
        for value in ("Production", None):
            with self.subTest(value=value):
                if value is None:
                    self.entitlements.pop("com.apple.developer.icloud-container-environment", None)
                else:
                    self.entitlements["com.apple.developer.icloud-container-environment"] = value
                with self.assertRaises(ValueError):
                    self.run_verify()

    def test_rejects_wrong_bundle_or_container(self):
        self.info["CFBundleIdentifier"] = "de.andreas-sk.meh-md"
        with self.assertRaises(ValueError):
            self.run_verify()
        self.info["CFBundleIdentifier"] = BUNDLE
        self.entitlements["com.apple.developer.icloud-container-identifiers"] = ["other"]
        with self.assertRaises(ValueError):
            self.run_verify()

    def test_rejects_normal_or_ambiguous_app_entry(self):
        for symbols in (b"T MyAppV5$main", self.symbols + b"\nT MyAppV5$main", b""):
            with self.subTest(symbols=symbols):
                self.symbols = symbols
                with self.assertRaises(ValueError):
                    self.run_verify()

    def test_restoration_requires_normal_development_entry(self):
        with self.assertRaises(ValueError):
            self.run_verify(lab=False)
        self.symbols = b"T MyAppV5$main"
        self.run_verify(lab=False)
        self.entitlements["com.apple.developer.icloud-container-environment"] = "Production"
        with self.assertRaises(ValueError):
            self.run_verify(lab=False)

    def test_wrong_platform_is_rejected(self):
        self.info["CFBundleSupportedPlatforms"] = ["iPhoneOS"]
        with self.assertRaises(ValueError):
            self.run_verify()

    def test_signature_failure_prevents_launch_verification(self):
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(self.info))
        with patch("run_notebook_lab.command", side_effect=subprocess.CalledProcessError(1, "codesign")):
            with self.assertRaises(subprocess.CalledProcessError):
                verify(self.app)

    def test_log_readback_checks_run_and_phase(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "process.log"
            report = {"runID": "RUN", "phase": "exchange", "status": "passed"}
            log.write_text("SYNC_LAB_REPORT " + json.dumps(report) + "\n")
            self.assertEqual(read_lab_log(log, "run", "exchange"), report)
            with self.assertRaises(RuntimeError):
                read_lab_log(log, "other", "exchange")
            with self.assertRaises(RuntimeError):
                read_lab_log(log, "run", "receive")

    def test_process_exit_rechecks_log_for_final_report(self):
        from run_notebook_lab import main

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            executable = root / "Lab"
            executable.write_bytes(b"lab")
            evidence = root / "evidence"
            run = "2ac5bbe7-2d9c-47a0-8632-8c6b685ad9fa"
            report = {
                "runID": run, "phase": "exchange", "status": "passed",
                "stage": "complete", "events": [],
            }

            class ExitedAfterFinalWrite:
                returncode = 0
                wrote_final_report = False

                def poll(self):
                    if not self.wrote_final_report:
                        with (evidence / "process.log").open("a") as log:
                            log.write("SYNC_LAB_REPORT " + json.dumps(report) + "\n")
                        self.wrote_final_report = True
                    return self.returncode

                def terminate(self):
                    raise AssertionError("Completed process should not be terminated")

            def fake_command(*args):
                output = b"revision\n" if args[1] == "rev-parse" else b""
                return subprocess.CompletedProcess(args, 0, output, b"")

            argv = [
                "run_notebook_lab.py", str(root / "Lab.app"), str(evidence),
                "--phase", "exchange", "--run-id", run,
                "--allow-development-cloud", "--timeout", "10",
            ]
            with patch("sys.argv", argv), \
                 patch("run_notebook_lab.verify", return_value=(executable, executable)), \
                 patch("run_notebook_lab.command", side_effect=fake_command), \
                 patch("run_notebook_lab.subprocess.Popen", return_value=ExitedAfterFinalWrite()), \
                 patch("run_notebook_lab.time.monotonic", return_value=0):
                main()

            self.assertEqual(json.loads((evidence / "report.json").read_text()), report)


class SimulatorLabLaunchGuardTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.app = Path(self.temporary.name) / "Lab.app"
        self.app.mkdir()
        self.executable = self.app / "Lab"
        (self.app / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": BUNDLE,
            "CFBundleExecutable": "Lab",
            "CFBundleSupportedPlatforms": ["iPhoneSimulator"],
        }))
        self.embedded = {
            "application-identifier": f"{TEAM}.{BUNDLE}",
            "com.apple.developer.icloud-container-environment": "Development",
            "com.apple.developer.icloud-container-identifiers": [CONTAINER],
            "com.apple.developer.icloud-services": ["CloudKit"],
        }
        self.host = {}
        self.sections = 1
        self.offset = 64
        self.plist = None

    def run_verify(self):
        payload = self.plist if self.plist is not None else plistlib.dumps(self.embedded)
        self.executable.write_bytes(b"\xcf\xfa\xed\xfe" + b"\0" * 60 + payload)
        section = (
            "Section\n"
            "  sectname __entitlements\n"
            "   segname __TEXT\n"
            f"      size 0x{len(payload):x}\n"
            f"    offset {self.offset}\n"
        )
        otool = (
            "Load command 0\n"
            "      cmd LC_SEGMENT_64\n"
            "  segname __TEXT\n"
            "  fileoff 0\n"
            f" filesize {self.executable.stat().st_size}\n"
            + section * self.sections
            + "Load command 1\n"
            "      cmd LC_BUILD_VERSION\n"
            " platform 7\n"
        ).encode()

        def fake_command(*args):
            if args[0] == "nm":
                return subprocess.CompletedProcess(args, 0, b"T NotebookSyncLabAppV5$main", b"")
            if args[0] == "otool":
                return subprocess.CompletedProcess(args, 0, otool, b"")
            if "--entitlements" in args:
                return subprocess.CompletedProcess(args, 0, plistlib.dumps(self.host), b"")
            return subprocess.CompletedProcess(args, 0, b"", b"")

        with patch("run_notebook_lab.command", side_effect=fake_command):
            return verify(self.app, platform="iPhoneSimulator")

    def test_accepts_one_bounded_development_section(self):
        executable, _ = self.run_verify()
        self.assertEqual(executable, self.executable)

    def test_rejects_production_missing_or_wrong_container(self):
        for key, value in (
            ("com.apple.developer.icloud-container-environment", "Production"),
            ("com.apple.developer.icloud-container-environment", None),
            ("com.apple.developer.icloud-container-identifiers", ["other"]),
            ("application-identifier", "other"),
        ):
            with self.subTest(key=key, value=value):
                saved = self.embedded.get(key)
                if value is None:
                    self.embedded.pop(key, None)
                else:
                    self.embedded[key] = value
                with self.assertRaises(ValueError):
                    self.run_verify()
                self.embedded[key] = saved

    def test_rejects_missing_duplicate_malformed_or_out_of_bounds_section(self):
        for sections, offset, plist in (
            (0, 64, None),
            (2, 64, None),
            (1, 100_000, None),
            (1, 64, b"not a plist"),
        ):
            with self.subTest(sections=sections, offset=offset, plist=plist):
                self.sections, self.offset, self.plist = sections, offset, plist
                with self.assertRaises(ValueError):
                    self.run_verify()

    def test_rejects_fat_or_host_entitlements(self):
        self.host = {"com.apple.developer.icloud-container-environment": "Production"}
        with self.assertRaises(ValueError):
            self.run_verify()
        self.host = {}
        payload = plistlib.dumps(self.embedded)
        self.executable.write_bytes(b"\xca\xfe\xba\xbe" + b"\0" * 60 + payload)
        with patch("run_notebook_lab.command"):
            # Parsing a universal binary is deliberately unsupported.
            from run_notebook_lab import simulator_entitlements
            with self.assertRaises(ValueError):
                simulator_entitlements(self.executable)


class DedicatedSimulatorTests(unittest.TestCase):
    def test_requires_exact_booted_udid(self):
        listing = {"devices": {"iOS 27.0": [
            {"udid": "A3C32B1C-2854-464B-86D9-5345740304C4", "state": "Booted"},
        ]}}
        with patch("run_notebook_lab_simulator.command", return_value=
                   subprocess.CompletedProcess([], 0, json_bytes(listing), b"")):
            check_simulator("A3C32B1C-2854-464B-86D9-5345740304C4")
            with self.assertRaises(ValueError):
                check_simulator("00000000-0000-0000-0000-000000000000")

    def test_refuses_an_installed_normal_dev_app(self):
        existing = subprocess.CompletedProcess([], 0, "/tmp/Normal.app\n", "")
        with patch("run_notebook_lab_simulator.subprocess.run", return_value=existing), \
             patch("run_notebook_lab_simulator.verify", side_effect=ValueError("normal app")):
            with self.assertRaises(ValueError):
                check_existing_app("A3C32B1C-2854-464B-86D9-5345740304C4")

    def test_report_path_reads_only_the_exact_lab_phase(self):
        data = subprocess.CompletedProcess([], 0, b"/tmp/simulator-data\n", b"")
        with patch("run_notebook_lab_simulator.command", return_value=data) as called:
            path = lab_report_path(
                "A3C32B1C-2854-464B-86D9-5345740304C4",
                "2AC5BBE7-2D9C-47A0-8632-8C6B685AD9FA", "receive",
            )
        self.assertEqual(path, Path(
            "/tmp/simulator-data/Documents/SyncLab/"
            "2ac5bbe7-2d9c-47a0-8632-8c6b685ad9fa/receive/report.json"
        ))
        self.assertEqual(called.call_args.args[3:],
                         ("A3C32B1C-2854-464B-86D9-5345740304C4", BUNDLE, "data"))

    def test_initial_run_and_each_phase_must_be_fresh(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory) / "Documents/SyncLab/run"
            report = run / "receive/report.json"
            ensure_fresh_phase(report, "receive")
            ensure_fresh_phase(run / "publish/report.json", "publish")
            report.parent.mkdir(parents=True)
            with self.assertRaises(RuntimeError):
                ensure_fresh_phase(run / "publish/report.json", "publish")
            report.write_text("{}")
            with self.assertRaises(RuntimeError):
                ensure_fresh_phase(report, "receive")

    def test_report_readback_checks_run_and_phase(self):
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "report.json"
            self.assertIsNone(read_lab_report(report, "run", "receive"))
            report.write_text("partial json")
            self.assertIsNone(read_lab_report(report, "run", "receive"))
            report.write_text(json.dumps({
                "runID": "RUN", "phase": "receive", "status": "failed"
            }))
            self.assertEqual(read_lab_report(report, "run", "receive")["status"], "failed")
            with self.assertRaises(RuntimeError):
                read_lab_report(report, "other", "receive")
            with self.assertRaises(RuntimeError):
                read_lab_report(report, "run", "verify")

    def test_timeout_preserves_running_report_and_terminates_lab(self):
        from run_notebook_lab_simulator import main

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            executable = root / "symbol-file"
            executable.write_bytes(b"lab")
            evidence = root / "evidence"
            device = "A3C32B1C-2854-464B-86D9-5345740304C4"
            run = "2ac5bbe7-2d9c-47a0-8632-8c6b685ad9fa"
            report = root / "sim-data/Documents/SyncLab" / run / "receive/report.json"
            running = {"runID": run, "phase": "receive", "status": "running"}
            argv = [
                "run_notebook_lab_simulator.py", str(root / "Lab.app"),
                device, str(evidence), "--phase", "receive", "--run-id", run,
                "--allow-development-cloud", "--dedicated-simulator",
                "--timeout", "10",
            ]
            with patch("sys.argv", argv), \
                 patch("run_notebook_lab_simulator.verify", return_value=(None, executable)), \
                 patch("run_notebook_lab_simulator.check_simulator"), \
                 patch("run_notebook_lab_simulator.check_existing_app"), \
                 patch("run_notebook_lab_simulator.lab_report_path", return_value=report), \
                 patch("run_notebook_lab_simulator.command"), \
                 patch("run_notebook_lab_simulator.subprocess.run", return_value=
                       subprocess.CompletedProcess([], 0, b"launched", b"")), \
                 patch("run_notebook_lab_simulator.read_lab_report", return_value=running), \
                 patch("run_notebook_lab_simulator.time.monotonic", side_effect=[0, 100]), \
                 patch("run_notebook_lab_simulator.terminate_lab") as terminate:
                with self.assertRaises(TimeoutError):
                    main()
            self.assertEqual(json.loads((evidence / "report.json").read_text()), running)
            terminate.assert_called_once_with(device)


def json_bytes(value):
    return json.dumps(value).encode()


if __name__ == "__main__":
    unittest.main()
