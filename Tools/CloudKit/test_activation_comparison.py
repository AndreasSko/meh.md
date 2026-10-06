import copy
import math
from pathlib import Path
import sys
import tempfile
import json
import uuid
import unittest
from unittest import mock
from types import SimpleNamespace
from contextlib import nullcontext

sys.path.insert(0, str(Path(__file__).resolve().parent))
import run_activation_comparison as comparison


class ActivationComparisonTests(unittest.TestCase):
    def listing(self):
        return {"devices": {comparison.RUNTIME: [{
            "name": comparison.NAME, "udid": "11111111-1111-4111-8111-111111111111",
            "deviceTypeIdentifier": comparison.DEVICE_TYPE,
            "isAvailable": True, "state": "Shutdown",
        }]}}

    def test_foreground_callback_resolves_migrated_container_when_invoked(self):
        run = str(uuid.uuid4())
        old = Path("/old-container/Documents/SyncLab") / run / "activation-prepare/report.json"
        new = Path("/new-container/Documents/SyncLab") / run / "activation-prepare/report.json"
        report = {"runID": run, "phase": "activation-publish-foreground", "status": "passed",
                  "expectedText": "fictional"}
        with mock.patch.object(comparison, "lab_report_path", return_value=old) as locate, \
                mock.patch.object(comparison, "launch_host_phase", return_value=report), \
                mock.patch.object(comparison, "signal_foreground_ready") as signal:
            callback = comparison.publisher_foreground_callback({}, Path("/evidence"),
                                                               "device", run, 120)
            locate.assert_not_called()
            locate.return_value = new
            callback()
            locate.assert_called_once_with("device", run, "activation-prepare")
            signal.assert_called_once_with(new.parent.parent / "activation", run, report)

    def test_prepare_fixture_path_is_resolved_after_simulator_phase_install(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            prepared = root / "prepared"
            prepared.mkdir()
            manifest = {"simulator": "device", "variants": {"before": {"app": "before"},
                         "after": {"app": "after"}}, "publisher": {"app": "publisher"}}
            (prepared / "manifest.json").write_text(json.dumps(manifest))
            args = SimpleNamespace(prepared=prepared, evidence=root / "evidence", trials=1,
                                   notes=100, timeout=10, publisher_app=Path("publisher"))
            order = []
            def launch(*arguments, **kwargs):
                order.append("installed:" + arguments[3])
                return {"measurementsMS": {}}
            def locate(*arguments):
                order.append("resolve")
                return root / "new-container/activation"
            with mock.patch.object(comparison, "verify_prepared"), \
                    mock.patch.object(comparison, "verify_publisher", return_value={}), \
                    mock.patch.object(comparison, "simulator_lease", return_value=nullcontext()), \
                    mock.patch.object(comparison, "check_device"), \
                    mock.patch.object(comparison, "preflight"), \
                    mock.patch.object(comparison, "trial_sequence", return_value=[(1, "before", "activation-prepare")]), \
                    mock.patch.object(comparison, "launch_phase", side_effect=launch), \
                    mock.patch.object(comparison, "activation_directory", side_effect=locate), \
                    mock.patch.object(comparison, "copy_publisher_fixture", side_effect=lambda *args: order.append("copy")), \
                    mock.patch.object(comparison, "launch_host_phase"), \
                    mock.patch.object(comparison, "validate_trial_report"):
                # A nonempty identity enables the optional publisher path.
                with mock.patch.object(comparison, "verify_publisher", return_value={"app": "publisher"}):
                    comparison.run(args)
            self.assertEqual(order, ["installed:activation-prepare", "resolve", "copy"])

    def test_publisher_copies_only_source_notebook_and_manifest(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            run = str(uuid.uuid4())
            activation = root / "activation"
            notebook = activation / "source/notebook"
            notebook.mkdir(parents=True)
            (notebook / "fixture").write_text("fictional")
            (activation / "manifest.json").write_text(json.dumps({"runID": run}))
            (activation / "receiver-startup").mkdir()
            (activation / "other-secret").write_text("must not copy")
            target = comparison.copy_publisher_fixture(activation, run, root / "host")
            self.assertEqual(sorted(p.name for p in target.iterdir()),
                             ["manifest.json", "source"])
            self.assertEqual((target / "source/notebook/fixture").read_text(), "fictional")
            with self.assertRaises(FileExistsError):
                comparison.copy_publisher_fixture(activation, run, root / "host")

    def test_publisher_rejects_wrong_run_and_source_symlinks(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            run = str(uuid.uuid4())
            source = root / "activation/source/notebook"
            source.mkdir(parents=True)
            manifest = root / "activation/manifest.json"
            manifest.write_text(json.dumps({"runID": str(uuid.uuid4())}))
            with self.assertRaises(ValueError):
                comparison.copy_publisher_fixture(root / "activation", run, root / "host")
            manifest.write_text(json.dumps({"runID": run}))
            (source / "outside").symlink_to(root)
            with self.assertRaises(ValueError):
                comparison.copy_publisher_fixture(root / "activation", run, root / "host")

    def test_foreground_signal_requires_confirmed_exact_publisher_report(self):
        with tempfile.TemporaryDirectory() as temporary:
            activation = Path(temporary)
            run = str(uuid.uuid4())
            report = {"runID": run, "phase": "activation-publish-foreground",
                      "status": "passed", "expectedText": "fictional remote"}
            comparison.signal_foreground_ready(activation, run, report)
            signal = json.loads((activation / "external-foreground-ready.json").read_text())
            self.assertEqual(signal["phase"], "activation-publish-foreground")
            self.assertEqual(signal["runID"], run)
            self.assertEqual(signal["expectedText"], report["expectedText"])
            with self.assertRaises(ValueError):
                comparison.signal_foreground_ready(activation, run, report)
            with self.assertRaises(ValueError):
                comparison.signal_foreground_ready(activation, str(uuid.uuid4()), report)

    def test_mac_publisher_verification_uses_exact_platform_and_hashes(self):
        with tempfile.TemporaryDirectory() as temporary:
            executable = Path(temporary) / "lab"
            executable.write_bytes(b"signed fixture")
            with mock.patch.object(comparison, "verify", return_value=(executable, executable)) as verify:
                identity = comparison.publisher_identity(Path(temporary))
            verify.assert_called_once_with(Path(temporary).resolve(), platform="MacOSX")
            self.assertEqual(identity["executable_sha256"], comparison.digest(executable))

    def test_publisher_must_match_pinned_harness_revision_app_and_binaries(self):
        app = Path("/private/tmp/prepared-publisher.app")
        actual = {"app": str(app), "executable": str(app / "Contents/MacOS/lab"),
                  "executable_sha256": "executablehash", "binary_sha256": "binaryhash"}
        manifest = {"after": "afterrevision", "harness_sha256": "harnesshash",
                    "publisher": {**actual, "revision": "afterrevision",
                                  "harness_sha256": "harnesshash"}}
        with mock.patch.object(comparison, "publisher_identity", return_value=actual):
            self.assertEqual(comparison.verify_publisher(manifest, app), actual)
            for key, value in (("harness_sha256", "otherharness"),
                               ("revision", "otherrevision"),
                               ("app", "/private/tmp/other.app"),
                               ("executable_sha256", "changed"),
                               ("binary_sha256", "changed")):
                changed = {**manifest, "publisher": {**manifest["publisher"], key: value}}
                with self.assertRaises(ValueError):
                    comparison.verify_publisher(changed, app)
            with self.assertRaises(ValueError):
                comparison.verify_publisher({k: v for k, v in manifest.items()
                                             if k != "publisher"}, app)

    def test_host_launcher_uses_exact_binary_and_cleans_up_owned_process(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            run = str(uuid.uuid4())
            identity = {"app": str(root / "app"), "executable": str(root / "exact-lab")}
            report = {"runID": run, "phase": "account", "status": "passed"}
            process = mock.Mock()
            process.poll.return_value = None
            with mock.patch.object(comparison, "publisher_identity", return_value=identity), \
                    mock.patch.object(comparison, "read_lab_log", return_value=report), \
                    mock.patch.object(comparison.subprocess, "Popen", return_value=process) as spawn:
                result = comparison.launch_host_phase(identity, root / "evidence", run, "account", 10)
            self.assertEqual(result, report)
            self.assertEqual(spawn.call_args.args[0], [identity["executable"]])
            self.assertEqual(spawn.call_args.kwargs["env"]["MEH_SYNC_LAB_RUN"], run)
            process.terminate.assert_called_once()
            process.wait.assert_called_once_with(timeout=10)
            self.assertTrue((root / "evidence/report.json").exists())

    def test_safe_tar_filters_supported(self):
        comparison.require_safe_tar_extraction()

    def test_safe_tar_filters_require_callable_and_filter_parameter(self):
        with mock.patch.object(comparison.tarfile, "data_filter", None):
            with self.assertRaisesRegex(RuntimeError, "safe tar extraction filters"):
                comparison.require_safe_tar_extraction()
        with mock.patch.object(comparison.tarfile.TarFile, "extractall",
                               lambda self, path=None: None):
            with self.assertRaisesRegex(RuntimeError, "safe tar extraction filters"):
                comparison.require_safe_tar_extraction()

    def test_prepare_checks_tar_support_before_side_effects(self):
        with mock.patch.object(comparison, "require_safe_tar_extraction",
                               side_effect=RuntimeError("unsupported")), \
                mock.patch.object(comparison, "simulator_lease") as lease:
            with self.assertRaisesRegex(RuntimeError, "unsupported"):
                comparison.prepare(None)
            lease.assert_not_called()

    def test_artifacts_must_be_outside_repository(self):
        with self.assertRaises(ValueError):
            comparison.require_external_artifacts(comparison.REPO / "evidence")
        comparison.require_external_artifacts(Path("/private/tmp/task-evidence"))

    def test_exact_named_simulator(self):
        self.assertEqual(comparison.select_simulator(self.listing())["udid"],
                         "11111111-1111-4111-8111-111111111111")

    def test_rejects_duplicate_and_wrong_identity(self):
        listing = self.listing()
        listing["devices"][comparison.RUNTIME].append(
            copy.deepcopy(listing["devices"][comparison.RUNTIME][0]))
        with self.assertRaises(ValueError):
            comparison.select_simulator(listing)
        for field, value in (("udid", "wrong"), ("isAvailable", False),
                             ("deviceTypeIdentifier", "wrong"),
                             ("state", "Booting")):
            listing = self.listing()
            listing["devices"][comparison.RUNTIME][0][field] = value
            with self.assertRaises(ValueError):
                comparison.select_simulator(listing)

    def test_rejects_changed_pinned_simulator_uuid(self):
        with self.assertRaises(ValueError):
            comparison.select_simulator(self.listing(),
                                        "22222222-2222-4222-8222-222222222222")

    def test_rejects_wrong_runtime(self):
        listing = self.listing()
        listing["devices"]["iOS-old"] = listing["devices"].pop(comparison.RUNTIME)
        with self.assertRaises(ValueError):
            comparison.select_simulator(listing)

    def test_alternating_paired_sequence(self):
        sequence = comparison.trial_sequence(2)
        self.assertEqual(len(sequence), 16)
        self.assertEqual(sequence[:4], [(1, "before", phase)
                                      for phase in comparison.PHASES])
        self.assertEqual(sequence[8:12], [(2, "after", phase)
                                       for phase in comparison.PHASES])
        for trial in (1, 2):
            for variant in ("before", "after"):
                self.assertEqual([phase for number, name, phase in sequence
                                  if (number, name) == (trial, variant)],
                                 list(comparison.PHASES))

    def test_results_require_content_and_activation_timings(self):
        report = {"status": "passed", "phase": "activation-startup", "noteCount": 100,
                  "expectedText": "remote", "observedText": "remote",
                  "expectedLocalText": "local", "observedLocalText": "local",
                  "measurementsMS": {"activation_visible": [10],
                                     "activation_complete": [20]}}
        comparison.validate_trial_report(report, "activation-startup", 100)
        for field, value in (("status", "failed"), ("observedText", "old"),
                             ("observedLocalText", "lost"), ("measurementsMS", {})):
            broken = {**report, field: value}
            with self.assertRaises(ValueError):
                comparison.validate_trial_report(broken, "activation-startup", 100)

    def test_summary_preserves_raw_samples_and_median(self):
        records = [{"variant": "before", "phase": "activation-startup",
                    "report": {"measurementsMS": {"activation_visible": values}}}
                   for values in ([10, 20], [90])]
        summary = comparison.summarize(records)
        metric = summary["before"]["activation-startup:activation_visible"]
        self.assertEqual(metric["raw_ms"], [10, 20, 90])
        self.assertEqual(metric["median_ms"], 20)

    def test_summary_rejects_invalid_measurements(self):
        for value in (math.nan, math.inf, -1, True, "secret"):
            with self.assertRaises(ValueError):
                comparison.summarize([{"variant": "before", "phase": "sample",
                                       "report": {"measurementsMS": {"visible": [value]}}}])

    def test_isolated_factory_overlay_is_idempotent_and_bounded(self):
        source = """prefix
    public static func makeIsolatedNotebookLab(
        containerIdentifier: String,
        stateDirectory: URL,
        runID: UUID
    ) async throws -> CloudKitSyncTransport {
        try await make(automaticallySync: false,
            labRunID: runID)
    }
    #endif
suffix automaticallySync: false,
"""
        overlaid = comparison.overlay_factory(source)
        self.assertIn("automaticallySync: Bool = false", overlaid)
        self.assertTrue(overlaid.endswith("suffix automaticallySync: false,\n"))
        self.assertEqual(comparison.overlay_factory(overlaid), overlaid)


if __name__ == "__main__":
    unittest.main()
