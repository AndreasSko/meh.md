import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from check_editor_performance import COUNTS, check_report, check_paired_reports


def valid_report(size=500, context="standard", shape="standard"):
    shape_suffix = {"standard": 0, "long-line": 65_538,
                    "nearby-table": 52}[shape]
    report = {
        "scenario": "large-note",
        "mode": "livePreview",
        "host": "editor",
        "context": context,
        "shape": shape,
        "requested_kb": size,
        "fixture_sha256": "a" * 64,
        "utf8_bytes": size * 1000 + shape_suffix,
        "utf16_length": size * 1000 + shape_suffix,
        "source_and_selection_preserved": True,
        "saved_text_preserved": True,
        "final_presentation_verified": True,
        "full_parses_during_edits": 0,
        "incremental_parses_during_edits": sum(COUNTS.values()),
        "measurements": {
            "open_to_idle_ms": [100.0],
            "main_actor_scheduling_delay_ms": [1.0],
            "autosave_wait_including_debounce_ms": [500.0],
        },
        "steps": [],
    }
    for kind, count in COUNTS.items():
        report["measurements"][f"{kind}_synchronous_ms"] = [10.0] * count
        report["measurements"][f"{kind}_to_idle_ms"] = [20.0] * count
        report["steps"].extend({
            "action": kind,
            "full_parses": 0,
            "incremental_parses": 1,
            "synchronous_ms": 10.0,
            "to_idle_ms": 20.0,
            "formatted_utf16_length": 512 if kind == "bulk_insert" else 256,
            "presentation_current_at_idle": True,
        } for _ in range(count))
    return report


def set_metric(report, action, suffix, value):
    report["measurements"][f"{action}_{suffix}"] = [value] * COUNTS[action]
    for step in report["steps"]:
        if step["action"] == action:
            step[suffix] = value


def set_samples(report, action, suffix, samples):
    report["measurements"][f"{action}_{suffix}"] = samples
    steps = [step for step in report["steps"] if step["action"] == action]
    for step, sample in zip(steps, samples):
        step[suffix] = sample


class CheckEditorPerformanceTests(unittest.TestCase):
    def test_accepts_complete_report_within_budget(self):
        self.assertEqual(check_report(valid_report(), 500), [])

    def cpu_report(self):
        report = valid_report()
        report["main_thread_cpu_captured"] = True
        for kind in COUNTS:
            set_metric(report, kind, "synchronous_main_thread_cpu_ms", 2.0)
            set_metric(report, kind, "to_idle_main_thread_cpu_ms", 5.0)
        return report

    def test_additive_cpu_diagnostics_keep_wall_budgets(self):
        report = self.cpu_report()
        self.assertEqual(check_report(report, 500), [])
        set_metric(report, "bulk_insert", "to_idle_ms", 2344)
        self.assertTrue(any("ceiling" in e for e in check_report(report, 500)))

    def test_cpu_capture_missing_malformed_or_inconsistent_fails_closed(self):
        for value in (False, None, 0):
            report = self.cpu_report()
            report["main_thread_cpu_captured"] = value
            self.assertTrue(check_report(report, 500))
        for value in (None, True, -1, float("nan"), float("inf")):
            report = self.cpu_report()
            set_metric(report, "typing", "synchronous_main_thread_cpu_ms", value)
            self.assertTrue(check_report(report, 500))
        report = self.cpu_report()
        report["steps"][0]["to_idle_main_thread_cpu_ms"] = 1
        self.assertTrue(check_report(report, 500))
        report = self.cpu_report()
        del report["measurements"]["typing_to_idle_main_thread_cpu_ms"]
        self.assertTrue(check_report(report, 500))

    def test_fails_missing_samples(self):
        report = valid_report()
        report["measurements"]["typing_to_idle_ms"] = [20.0]
        errors = check_report(report, 500)
        self.assertTrue(any("typing_to_idle_ms needs exactly" in e for e in errors))

    def test_fails_false_fidelity_and_full_parse_flags(self):
        report = valid_report()
        report["saved_text_preserved"] = False
        report["steps"][0]["full_parses"] = 1
        errors = check_report(report, 500)
        self.assertTrue(any("saved_text_preserved" in e for e in errors))
        self.assertTrue(any("full_parses must be zero" in e for e in errors))

    def test_fails_malformed_and_nonfinite_measurements(self):
        report = valid_report()
        report["measurements"]["typing_synchronous_ms"][0] = float("nan")
        errors = check_report(report, 50)
        self.assertTrue(any("finite nonnegative" in e for e in errors))

    def test_fails_latency_budget(self):
        report = valid_report()
        report["measurements"]["deletion_to_idle_ms"] = [1001.0] * COUNTS["deletion"]
        errors = check_report(report, 500)
        self.assertTrue(any("deletion_to_idle_ms p95" in e for e in errors))

    def test_mixed_50kb_typing_idle_budget_boundary(self):
        for value, accepted in ((300.0, True), (301.0, False)):
            with self.subTest(value=value):
                report = valid_report(50, "mixed")
                report["measurements"]["typing_to_idle_ms"][-2:] = [value] * 2
                typing_steps = [step for step in report["steps"]
                                if step["action"] == "typing"]
                for step in typing_steps[-2:]:
                    step["to_idle_ms"] = value
                errors = check_report(report, 50, context="mixed")
                self.assertEqual(errors, [] if accepted else [
                    "typing_to_idle_ms p95 301.0 ms exceeds 300 ms"
                ])

    def test_mixed_typing_allowance_preserves_other_budgets(self):
        cases = ((50, "standard", "standard", "typing", 251.0),
                 (50, "mixed", "long-line", "typing", 251.0),
                 (50, "mixed", "nearby-table", "typing", 501.0),
                 (50, "mixed", "standard", "deletion", 251.0))
        for size, context, shape, action, value in cases:
            with self.subTest(context=context, shape=shape, action=action):
                report = valid_report(size, context, shape)
                metric = f"{action}_to_idle_ms"
                report["measurements"][metric] = [value] * COUNTS[action]
                for step in report["steps"]:
                    if step["action"] == action:
                        step["to_idle_ms"] = value
                errors = check_report(report, size, context=context, shape=shape)
                self.assertTrue(any(f"{metric} p95" in e for e in errors))

    def test_mixed_50kb_keeps_individual_typing_ceiling(self):
        report = valid_report(50, "mixed")
        report["measurements"]["typing_to_idle_ms"][-1] = 501.0
        typing_steps = [step for step in report["steps"]
                        if step["action"] == "typing"]
        typing_steps[-1]["to_idle_ms"] = 501.0
        self.assertEqual(check_report(report, 50, context="mixed"), [
            "subsequent typing sample exceeds 500 ms ceiling"
        ])

    def test_500kb_sync_budget_catches_old_fastpath_regression(self):
        current = valid_report()
        baseline = copy.deepcopy(current)
        for value, sync, idle in ((current, 55.0, 20.0),
                                  (baseline, 55.0, 100.0)):
            value["measurements"]["typing_synchronous_ms"] = [sync] * COUNTS["typing"]
            value["measurements"]["typing_to_idle_ms"] = [idle] * COUNTS["typing"]
            for step in value["steps"]:
                if step["action"] == "typing":
                    step.update(synchronous_ms=sync, to_idle_ms=idle)
        self.assertEqual(check_report(current, 500), [])
        errors = check_report(current, 500, baseline=baseline)
        self.assertTrue(any("typing_synchronous_ms p95 must improve" in e
                            for e in errors))
        self.assertFalse(any("typing_to_idle_ms" in e for e in errors))

    def test_baseline_comparison_rejects_regression_and_bad_reports(self):
        current = valid_report()
        baseline = valid_report()
        for kind in COUNTS:
            for suffix in ("synchronous_ms", "to_idle_ms"):
                key = f"{kind}_{suffix}"
                baseline["measurements"][key] = [100.0] * COUNTS[kind]
        for step in baseline["steps"]:
            step.update(synchronous_ms=100.0, to_idle_ms=100.0)
        self.assertEqual(check_report(current, 500, baseline=baseline), [])
        self.assertTrue(check_report(baseline, 500, baseline=baseline))
        broken = copy.deepcopy(baseline)
        broken["saved_text_preserved"] = False
        self.assertTrue(any("baseline:" in e for e in
                            check_report(current, 500, baseline=broken)))
        broken = copy.deepcopy(baseline)
        broken["utf8_bytes"] += 1
        self.assertTrue(any("fixture utf8_bytes" in e for e in
                            check_report(current, 500, baseline=broken)))

    def test_comparison_rejects_same_size_different_literal_fixture(self):
        for digest in (None, "broken", "b" * 64):
            baseline = valid_report()
            baseline["fixture_sha256"] = digest
            self.assertTrue(any("fixture_sha256" in error for error in
                                check_report(valid_report(), 500, baseline=baseline)))

    def test_comparison_requires_valid_fixture_and_positive_baseline(self):
        for value in (None, True, 0, 500_001):
            report = valid_report()
            report["utf16_length"] = value
            self.assertTrue(any("utf16_length" in error for error in
                                check_report(report, 500)))
        baseline = valid_report()
        baseline["measurements"]["typing_synchronous_ms"] = [0.0] * COUNTS["typing"]
        for step in baseline["steps"]:
            if step["action"] == "typing":
                step["synchronous_ms"] = 0.0
        self.assertTrue(any("must be positive" in error for error in
                            check_report(valid_report(), 500, baseline=baseline)))

    def test_fixed_reference_catches_partial_regression(self):
        baseline, reference, current = valid_report(), valid_report(), valid_report()
        for report, synchronous, idle in ((baseline, 100, 200), (current, 25, 50)):
            for metric, value in (("synchronous_ms", synchronous), ("to_idle_ms", idle)):
                report["measurements"]["typing_" + metric] = [value] * COUNTS["typing"]
                for step in report["steps"]:
                    if step["action"] == "typing":
                        step[metric] = value
        self.assertEqual(check_report(current, 500, baseline=baseline), [])
        errors = check_report(current, 500, baseline=baseline, reference=reference)
        self.assertTrue(any("fixed reference" in error for error in errors))
        self.assertEqual(check_report(reference, 500, baseline=baseline,
                                      reference=reference), [])
        for field, value in (("fixture_sha256", "b" * 64), ("saved_text_preserved", False)):
            broken = copy.deepcopy(reference)
            broken[field] = value
            self.assertTrue(check_report(reference, 500, reference=broken))

    def test_measured_500kb_cold_windows_preserve_raw_samples_and_accept_warm_session(self):
        for cold in ([778, 624, 177], [1613, 461, 165], [595, 531, 445]):
            report = valid_report()
            samples = cold + [203] * 18
            set_samples(report, "typing", "to_idle_ms", samples)
            set_samples(report, "middle_bold_open", "synchronous_ms", [217, 119])
            self.assertEqual(check_report(report, 500), [])
            self.assertEqual(report["measurements"]["typing_to_idle_ms"], samples)

    def test_cold_extremes_cumulative_work_and_warm_stalls_fail(self):
        for samples, message in (
            ([2001, 100, 100] + [20] * 18, "first typing sample"),
            ([100, 1001, 100] + [20] * 18, "cold second or third"),
            ([100, 100, 1001] + [20] * 18, "cold second or third"),
            ([1500, 800, 701] + [20] * 18, "3000 ms cumulative"),
            ([778, 624, 177, 301] + [20] * 17, "subsequent typing sample exceeds 300"),
        ):
            report = valid_report()
            set_samples(report, "typing", "to_idle_ms", samples)
            self.assertTrue(any(message in error for error in check_report(report, 500)))
        report = valid_report()
        set_samples(report, "typing", "to_idle_ms", [2000, 500, 500] + [300] * 18)
        self.assertEqual(check_report(report, 500), [])
        set_samples(report, "middle_bold_open", "synchronous_ms", [301, 150])
        self.assertTrue(any("first middle bold" in error for error in check_report(report, 500)))

    def test_cold_work_cannot_move_to_later_keystroke_or_bold_marker(self):
        report = valid_report()
        set_samples(report, "typing", "to_idle_ms", [778, 624, 177] + [20] * 18)
        set_samples(report, "middle_bold_open", "synchronous_ms", [217, 119])
        self.assertEqual(check_report(report, 500), [])
        set_samples(report, "typing", "to_idle_ms", [778, 20, 177, 624] + [20] * 17)
        self.assertTrue(any("subsequent typing" in error for error in check_report(report, 500)))
        report = valid_report()
        set_samples(report, "middle_bold_open", "synchronous_ms", [119, 217])
        self.assertTrue(any("middle_bold_open_synchronous_ms p95" in error
                            for error in check_report(report, 500)))
        for action in ("middle_bold_typing", "middle_bold_close"):
            report = valid_report()
            set_metric(report, action, "synchronous_ms", 151)
            self.assertTrue(check_report(report, 500))

    def test_50kb_first_three_events_and_bold_opening_keep_existing_limits(self):
        report = valid_report(50, "mixed")
        set_samples(report, "typing", "to_idle_ms", [100, 501, 100] + [20] * 18)
        self.assertTrue(any("subsequent typing sample exceeds 500" in error
                            for error in check_report(report, 50)))
        report = valid_report(50, "mixed")
        set_samples(report, "middle_bold_open", "synchronous_ms", [51, 10])
        self.assertTrue(any("middle_bold_open_synchronous_ms p95" in error
                            for error in check_report(report, 50)))

    def test_paired_cold_maximum_total_and_first_bold_are_independent_guards(self):
        for cold, message in (([700, 200, 100], "cold_typing_max"),
                              ([600, 400, 300], "cold_typing_total")):
            current = [valid_report() for _ in range(3)]
            references = copy.deepcopy(current)
            for report in references:
                set_samples(report, "typing", "to_idle_ms", [500, 200, 100] + [20] * 18)
            for report in current:
                set_samples(report, "typing", "to_idle_ms", cold + [20] * 18)
            self.assertTrue(any(message in error for error in
                                check_paired_reports(current, references)))
        current = [valid_report() for _ in range(3)]
        references = copy.deepcopy(current)
        for report in references:
            set_samples(report, "middle_bold_open", "synchronous_ms", [100, 80])
        for report in current:
            set_samples(report, "middle_bold_open", "synchronous_ms", [150, 30])
        self.assertTrue(any("cold_middle_bold_open" in error for error in
                            check_paired_reports(current, references)))

    def test_paired_warm_tail_cannot_hide_behind_matching_whole_run_median(self):
        current = [valid_report() for _ in range(3)]
        references = copy.deepcopy(current)
        for report in references:
            set_samples(report, "typing", "to_idle_ms", [700, 500, 200] + [100] * 18)
        for report in current:
            set_samples(report, "typing", "to_idle_ms", [700, 500, 200] + [100] * 17 + [200])
        errors = check_paired_reports(current, references)
        self.assertTrue(any("warm typing_to_idle_ms p95" in error for error in errors))
        self.assertFalse(any("typing_to_idle_ms median of run medians" in error for error in errors))

    def test_historical_warm_gain_is_required_even_when_cold_tail_improves(self):
        baseline, current = valid_report(), valid_report()
        set_metric(baseline, "typing", "synchronous_ms", 100)
        set_metric(current, "typing", "synchronous_ms", 70)
        set_samples(baseline, "typing", "to_idle_ms", [1000, 500, 500] + [100] * 18)
        set_samples(current, "typing", "to_idle_ms", [200, 100, 100] + [70] * 17 + [90])
        errors = check_report(current, 500, baseline=baseline)
        self.assertTrue(any("typing_to_idle_ms p95 must improve" in error for error in errors))
        self.assertFalse(any("typing_to_idle_ms median must improve" in error for error in errors))
        set_samples(current, "typing", "to_idle_ms", [200, 100, 100] + [70] * 17 + [80])
        self.assertEqual(check_report(current, 500, baseline=baseline), [])
        # Cold extremes remain independently rejected despite a warm gain.
        set_samples(current, "typing", "to_idle_ms", [2001, 100, 100] + [70] * 17 + [80])
        self.assertTrue(any("first typing sample" in error for error in
                            check_report(current, 500, baseline=baseline)))

    def test_paired_comparison_requires_three_valid_identical_fixtures(self):
        current = [valid_report() for _ in range(3)]
        references = copy.deepcopy(current)
        self.assertEqual(check_paired_reports(current, references), [])
        for broken in (None, [], current[:2], current + current[:1]):
            self.assertTrue(check_paired_reports(broken, references))
            self.assertTrue(check_paired_reports(current, broken))
        for field, value in (("fixture_sha256", "b" * 64),
                             ("saved_text_preserved", False),
                             ("utf16_length", 499_900)):
            broken = copy.deepcopy(references)
            broken[1][field] = value
            self.assertTrue(check_paired_reports(current, broken))
        references[0] = None
        self.assertTrue(check_paired_reports(current, references))

    def test_paired_guard_catches_known_bold_regression(self):
        current = [valid_report() for _ in range(3)]
        references = copy.deepcopy(current)
        for reports, cost in ((current, 144.36), (references, 58.36)):
            for report in reports:
                set_metric(report, "middle_bold_typing", "synchronous_ms", cost)
        errors = check_paired_reports(current, references)
        self.assertTrue(any("middle_bold_typing_synchronous_ms median of run medians"
                            in error for error in errors))

    def test_paired_median_tolerates_one_noisy_run_but_checks_every_ceiling(self):
        current = [valid_report() for _ in range(3)]
        references = copy.deepcopy(current)
        set_metric(current[0], "middle_bold_typing", "synchronous_ms", 100)
        self.assertEqual(check_paired_reports(current, references), [])
        set_metric(current[0], "middle_bold_typing", "synchronous_ms", 151)
        self.assertTrue(any("current run 1:" in error and "exceeds" in error
                            for error in check_paired_reports(current, references)))
        current = [valid_report() for _ in range(3)]
        set_metric(current[2], "bulk_insert", "to_idle_ms", 2001)
        self.assertTrue(any("current run 3:" in error and "bulk_insert" in error
                            for error in check_paired_reports(current, references)))

    def test_paired_idle_guard_rejects_measured_selection_regression(self):
        current = [valid_report() for _ in range(3)]
        references = copy.deepcopy(current)
        for report in references:
            set_metric(report, "typing", "to_idle_ms", 69.26)
        for report in current:
            set_metric(report, "typing", "to_idle_ms", 100.93)
        errors = check_paired_reports(current, references)
        self.assertTrue(any("typing_to_idle_ms median of run medians" in error
                            for error in errors))
        # One delayed launch does not override two fast independent launches.
        for report in current[1:]:
            set_metric(report, "typing", "to_idle_ms", 69.26)
        self.assertEqual(check_paired_reports(current, references), [])

    def test_paired_allowances_and_baseline_proof_remain_independent(self):
        current = [valid_report() for _ in range(3)]
        references = copy.deepcopy(current)
        for report in current:
            for action in ("typing", "deletion", "middle_bold_open",
                           "middle_bold_typing", "middle_bold_close"):
                set_metric(report, action, "synchronous_ms", 22)
            set_metric(report, "typing", "to_idle_ms", 34)
        self.assertEqual(check_paired_reports(current, references), [])
        set_metric(current[0], "deletion", "synchronous_ms", 22.01)
        set_metric(current[1], "deletion", "synchronous_ms", 22.01)
        self.assertTrue(any("deletion_synchronous_ms" in error
                            for error in check_paired_reports(current, references)))
        baseline = valid_report()
        self.assertTrue(any("at least 20%" in error for error in
                            check_report(valid_report(), 500, baseline=baseline)))

    def test_cli_paired_reports_fail_closed_for_missing_and_duplicate_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = []
            for index in range(6):
                path = root / f"run-{index}.json"
                path.write_text(json.dumps(valid_report()))
                paths.append(path)
            command = [sys.executable,
                       str(Path(__file__).with_name("check_editor_performance.py")),
                       str(paths[0]), "--size-kb", "500"]
            for path in paths[:3]:
                command += ["--paired-current-report", str(path)]
            for path in paths[3:]:
                command += ["--paired-reference-report", str(path)]
            self.assertEqual(subprocess.run(command, capture_output=True).returncode, 0)
            duplicate = command.copy()
            duplicate[-1] = str(paths[0])
            result = subprocess.run(duplicate, capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn("distinct report files", result.stderr)
            paths[-1].unlink()
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertIn("Cannot read performance report", result.stderr)

    def test_cli_paired_context_defaults_match_primary_validation(self):
        cases = ((50, "mixed", []), (500, "standard", []),
                 (50, "standard", ["--context", "standard"]))
        for size, context, options in cases:
            with self.subTest(size=size, context=context):
                with tempfile.TemporaryDirectory() as directory:
                    paths = [Path(directory) / f"run-{i}.json" for i in range(6)]
                    for path in paths:
                        path.write_text(json.dumps(valid_report(size, context)))
                    command = [sys.executable,
                               str(Path(__file__).with_name("check_editor_performance.py")),
                               str(paths[0]), "--size-kb", str(size), *options]
                    for path in paths[:3]:
                        command += ["--paired-current-report", str(path)]
                    for path in paths[3:]:
                        command += ["--paired-reference-report", str(path)]
                    result = subprocess.run(command, capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    wrong = valid_report(size, "standard" if context == "mixed" else "mixed")
                    paths[-1].write_text(json.dumps(wrong))
                    result = subprocess.run(command, capture_output=True, text=True)
                    self.assertEqual(result.returncode, 1)
                    self.assertIn(f"context must be {context}", result.stderr)

    def test_cli_enforces_fixed_reference(self):
        with tempfile.TemporaryDirectory() as directory:
            current = Path(directory) / "current.json"
            reference = Path(directory) / "reference.json"
            current.write_text(json.dumps(valid_report()))
            reference.write_text(json.dumps(valid_report()))
            command = [sys.executable, str(Path(__file__).with_name("check_editor_performance.py")),
                       str(current), "--size-kb", "500", "--reference-report", str(reference)]
            self.assertEqual(subprocess.run(command, capture_output=True).returncode, 0)
            broken = valid_report()
            broken["fixture_sha256"] = "b" * 64
            reference.write_text(json.dumps(broken))
            self.assertEqual(subprocess.run(command, capture_output=True).returncode, 1)

    def test_single_typing_hang_cannot_hide_beyond_p95(self):
        for index, value, expected in ((0, 2001, "first typing"),
                                       (20, 501, "subsequent typing")):
            report = valid_report()
            report["measurements"]["typing_to_idle_ms"][index] = value
            steps = [step for step in report["steps"] if step["action"] == "typing"]
            steps[index]["to_idle_ms"] = value
            errors = check_report(report, 500)
            self.assertTrue(any(expected in error for error in errors))
            self.assertFalse(any("typing_to_idle_ms p95" in error for error in errors))
            self.assertEqual(check_report(report, 500, enforce_budgets=False), [])

    def test_cold_first_typing_is_retained_with_its_own_ceiling(self):
        report = valid_report()
        report["measurements"]["typing_to_idle_ms"][0] = 1735.0
        report["steps"][0]["to_idle_ms"] = 1735.0
        self.assertEqual(check_report(report, 500), [])

    def test_bulk_insert_uses_separate_single_sample_ceiling(self):
        report = valid_report()
        report["measurements"]["bulk_insert_to_idle_ms"] = [1_200.0]
        bulk_step = next(step for step in report["steps"]
                         if step["action"] == "bulk_insert")
        bulk_step["to_idle_ms"] = 1_200.0
        errors = check_report(report, 500)
        self.assertEqual(errors, [])

        report["measurements"]["bulk_insert_to_idle_ms"] = [2_001.0]
        bulk_step["to_idle_ms"] = 2_001.0
        errors = check_report(report, 500)
        self.assertTrue(any("single-sample ceiling 2000 ms" in e for e in errors))

        report = valid_report()
        report["measurements"]["typing_to_idle_ms"][-2:] = [1001.0, 1001.0]
        typing_steps = [step for step in report["steps"]
                        if step["action"] == "typing"]
        for step in typing_steps[-2:]:
            step["to_idle_ms"] = 1001.0
        errors = check_report(report, 500)
        self.assertTrue(any("typing_to_idle_ms p95" in e for e in errors))

    def test_fails_wrong_context_or_mode(self):
        report = valid_report(50, "standard")
        errors = check_report(report, 50, "livePreview", "mixed")
        self.assertTrue(any("context must be mixed" in e for e in errors))
        errors = check_report(report, 50, "source", "standard")
        self.assertTrue(any("mode must be source" in e for e in errors))

    def test_fails_wrong_host(self):
        report = valid_report()
        errors = check_report(report, 500, host="notebook")
        self.assertTrue(any("host must be notebook" in e for e in errors))
        report["host"] = "notebook"
        self.assertEqual(check_report(report, 500, host="notebook"), [])

    def test_fails_missing_or_wrong_shape(self):
        report = valid_report()
        del report["shape"]
        errors = check_report(report, 500)
        self.assertTrue(any("shape must be standard" in e for e in errors))
        report = valid_report(shape="nearby-table")
        errors = check_report(report, 500)
        self.assertTrue(any("shape must be standard" in e for e in errors))
        self.assertEqual(
            check_report(report, 500, shape="nearby-table"), []
        )

    def test_long_line_allows_full_parse_but_keeps_idle_budget(self):
        report = valid_report(50, "mixed", "long-line")
        for step in report["steps"]:
            step["full_parses"] = 1
            step["incremental_parses"] = 0
            step["formatted_utf16_length"] = 256
        report["full_parses_during_edits"] = len(report["steps"])
        report["incremental_parses_during_edits"] = 0
        for kind, count in COUNTS.items():
            report["measurements"][f"{kind}_synchronous_ms"] = [20.0] * count
            report["measurements"][f"{kind}_to_idle_ms"] = [100.0] * count
            for step in report["steps"]:
                if step["action"] == kind:
                    step["synchronous_ms"] = 20.0
                    step["to_idle_ms"] = 100.0
        self.assertEqual(
            check_report(report, 50, context="mixed", shape="long-line"), []
        )
        report["measurements"]["typing_to_idle_ms"][-2:] = [250.1, 250.1]
        typing_steps = [step for step in report["steps"]
                        if step["action"] == "typing"]
        for step in typing_steps[-2:]:
            step["to_idle_ms"] = 250.1
        errors = check_report(report, 50, context="mixed", shape="long-line")
        self.assertTrue(any("typing_to_idle_ms p95" in e for e in errors))

    def test_long_line_full_parse_still_requires_bounded_format_range(self):
        report = valid_report(50, "mixed", "long-line")
        for step in report["steps"]:
            step["full_parses"] = 1
            step["incremental_parses"] = 0
            step["formatted_utf16_length"] = 256
        report["full_parses_during_edits"] = len(report["steps"])
        report["incremental_parses_during_edits"] = 0
        self.assertEqual(
            check_report(report, 50, context="mixed", shape="long-line"), []
        )
        report["steps"][0]["formatted_utf16_length"] = 257
        errors = check_report(report, 50, context="mixed", shape="long-line")
        self.assertTrue(any("formatted_utf16_length must be 0..256" in e
                            for e in errors))

    def test_nearby_table_allows_structural_fallback_with_fidelity(self):
        report = valid_report(50, "standard", "nearby-table")
        for step in report["steps"]:
            step["full_parses"] = 1
            step["incremental_parses"] = 0
            step["formatted_utf16_length"] = report["utf16_length"]
        report["full_parses_during_edits"] = len(report["steps"])
        report["incremental_parses_during_edits"] = 0
        self.assertEqual(
            check_report(report, 50, context="standard", shape="nearby-table"), []
        )
        report["final_presentation_verified"] = False
        errors = check_report(
            report, 50, context="standard", shape="nearby-table"
        )
        self.assertTrue(any("final_presentation_verified must be true" in e
                            for e in errors))

    def test_malformed_fallback_parse_counts_return_validation_errors(self):
        report = valid_report(50, "standard", "nearby-table")
        report["steps"][0]["full_parses"] = None
        report["steps"][0]["incremental_parses"] = "one"
        errors = check_report(report, 50, shape="nearby-table")
        self.assertTrue(any("full_parses must be an integer" in e for e in errors))
        self.assertTrue(any("incremental_parses must be an integer" in e
                            for e in errors))

    def test_fails_inconsistent_parse_aggregates(self):
        report = valid_report()
        report["steps"][0]["incremental_parses"] = 2
        errors = check_report(report, 500)
        self.assertTrue(any("incremental_parses must be one" in e for e in errors))
        self.assertTrue(any("sum does not match report aggregate" in e for e in errors))

    def test_fails_step_timing_hidden_by_valid_metric_samples(self):
        report = valid_report()
        report["steps"][0]["to_idle_ms"] = 1_000.0
        errors = check_report(report, 500)
        self.assertTrue(any("does not match step timings in order" in e
                            for e in errors))


if __name__ == "__main__":
    unittest.main()
