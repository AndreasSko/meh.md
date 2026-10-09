import copy
import json
import math
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from check_parser_performance import check_report, check_paired_reports, read_paired_paths


def report():
    return {"measurements": [
        {"utf8_bytes": size + 40, "utf16_length": size - 100,
         "samples_ms": [10] * 6 + [13] * 9 + [16] * 6,
         "median_ms": 13, "p95_ms": 16, "syntax_sha256": "a" * 64}
        for size in (50_000, 500_000)
    ]}


class ParserPerformanceGateTests(unittest.TestCase):
    def test_valid_report_and_reversed_order(self):
        value = report()
        self.assertEqual(check_report(value), [])
        value["measurements"].reverse()
        self.assertEqual(check_report(value), [])

    def test_21_samples_distinguish_p95_from_worst(self):
        value = report()
        row = value["measurements"][0]
        row.update(samples_ms=[10] * 19 + [20, 100], median_ms=10, p95_ms=20)
        self.assertEqual(check_report(value), [])
        row["p95_ms"] = 100
        self.assertTrue(any("p95_ms must match" in error
                            for error in check_report(value)))
        row.update(samples_ms=[10] * 20, median_ms=10, p95_ms=10)
        self.assertTrue(any("exactly 21" in error for error in check_report(value)))

    def test_reference_median_noise_floor_and_sustained_regression(self):
        reference = report()
        current = report()
        for index, reference_cost, allowed in ((0, 10, 30), (1, 100, 225)):
            reference["measurements"][index].update(
                samples_ms=[reference_cost] * 21,
                median_ms=reference_cost, p95_ms=reference_cost)
            current["measurements"][index].update(
                samples_ms=[allowed] * 21, median_ms=allowed, p95_ms=allowed)
        self.assertEqual(check_report(current, reference=reference), [])
        for index in (0, 1):
            with self.subTest(size=index):
                regressed = copy.deepcopy(current)
                cost = regressed["measurements"][index]["median_ms"] + .01
                regressed["measurements"][index].update(
                    samples_ms=[cost] * 21, median_ms=cost, p95_ms=cost)
                self.assertTrue(any("median_ms exceeds" in error
                                    for error in check_report(
                                        regressed, reference=reference)))

    def test_reference_tail_uses_absolute_budget(self):
        reference = report()
        current = report()
        current["measurements"][0].update(
            samples_ms=[13] * 19 + [40] * 2, median_ms=13, p95_ms=40)
        self.assertEqual(check_report(current, reference=reference), [])
        current["measurements"][0].update(
            samples_ms=[13] * 19 + [51] * 2, median_ms=13, p95_ms=51)
        self.assertTrue(any("CI budget" in error
                            for error in check_report(current, reference=reference)))

    def test_missing_wrong_and_duplicate_fixture_counts(self):
        for rows in (None, [], report()["measurements"][:1],
                     report()["measurements"] * 2,
                     report()["measurements"][:1] * 2):
            self.assertTrue(check_report({"measurements": rows}))
        self.assertTrue(check_report([]))

    def test_wrong_or_boolean_sizes(self):
        for size in (True, 50_000.0, 49_999, 50_501, 500_501, None):
            value = report()
            value["measurements"][0]["utf8_bytes"] = size
            self.assertTrue(check_report(value))

    def test_invalid_utf16_lengths(self):
        for length in (True, 0, -1, 50_041, 1.5, None):
            value = report()
            value["measurements"][0]["utf16_length"] = length
            self.assertTrue(check_report(value))

    def test_missing_extra_or_non_numeric_samples(self):
        for samples in (None, [], [1] * 6, [1] * 8,
                        [True] * 21, [math.nan] * 21, [math.inf] * 21, [10 ** 400] * 21,
                        [-1] * 21, ["1"] * 21):
            value = report()
            value["measurements"][0]["samples_ms"] = samples
            self.assertTrue(check_report(value))

    def test_wrong_or_boolean_summaries(self):
        for field in ("median_ms", "p95_ms"):
            for number in (True, math.nan, math.inf, -1, None, 99):
                value = report()
                value["measurements"][0][field] = number
                self.assertTrue(check_report(value))

    def test_missing_or_malformed_hash(self):
        for digest in (None, "", "a" * 63, "a" * 65, "g" * 64, True):
            value = report()
            value["measurements"][0]["syntax_sha256"] = digest
            self.assertTrue(check_report(value))

    def test_historical_gain_is_diagnostic(self):
        baseline = report()
        baseline["measurements"][0].update(
            samples_ms=[20] * 21, median_ms=20, p95_ms=20)
        baseline["measurements"][1].update(
            samples_ms=[175] * 21, median_ms=175, p95_ms=175)
        old = copy.deepcopy(baseline)
        old["measurements"][0].update(
            samples_ms=[15] * 21, median_ms=15, p95_ms=15)
        old["measurements"][1].update(
            samples_ms=[175] * 21, median_ms=175, p95_ms=175)
        self.assertEqual(check_report(old), [])
        errors = check_report(old, baseline)
        self.assertEqual(errors, [])

        improved = copy.deepcopy(old)
        improved["measurements"][0].update(
            samples_ms=[12] * 21, median_ms=12, p95_ms=12)
        improved["measurements"][1].update(
            samples_ms=[140] * 21, median_ms=140, p95_ms=140)
        self.assertEqual(check_report(improved, old), [])

    def test_relative_gate_pairs_reversed_fixtures_by_size(self):
        baseline = report()
        baseline["measurements"][0].update(
            samples_ms=[40] * 21, median_ms=40, p95_ms=40)
        baseline["measurements"][1].update(
            samples_ms=[100] * 21, median_ms=100, p95_ms=100)
        current = copy.deepcopy(baseline)
        current["measurements"][0].update(
            samples_ms=[30] * 21, median_ms=30, p95_ms=30)
        current["measurements"][1].update(
            samples_ms=[75] * 21, median_ms=75, p95_ms=75)
        current["measurements"].reverse()
        self.assertEqual(check_report(current, baseline), [])

    def test_historical_tail_is_diagnostic(self):
        baseline = report()
        baseline["measurements"][0].update(
            samples_ms=[20] * 21, median_ms=20, p95_ms=20)
        baseline["measurements"][1].update(
            samples_ms=[175] * 21, median_ms=175, p95_ms=175)
        current = copy.deepcopy(baseline)
        current["measurements"][0].update(
            samples_ms=[15] * 21, median_ms=15, p95_ms=15)
        current["measurements"][1].update(
            samples_ms=[100] * 19 + [175] * 2, median_ms=100, p95_ms=175)
        errors = check_report(current, baseline)
        self.assertEqual(errors, [])

    def test_reference_gate_allows_current_improvement_but_rejects_regression(self):
        old = report()
        old["measurements"][0].update(
            samples_ms=[20] * 21, median_ms=20, p95_ms=20)
        old["measurements"][1].update(
            samples_ms=[341] * 19 + [386] * 2, median_ms=341, p95_ms=386)

        current = copy.deepcopy(old)
        current["measurements"][0].update(
            samples_ms=[15] * 21, median_ms=15, p95_ms=15)
        current["measurements"][1].update(
            samples_ms=[199] * 19 + [211] * 2, median_ms=199, p95_ms=211)
        self.assertEqual(check_report(current, old), [])

        bad_reference = copy.deepcopy(old)
        bad_reference["measurements"][0].update(
            samples_ms=[15] * 21, median_ms=15, p95_ms=15)
        bad_reference["measurements"][1].update(
            samples_ms=[80] * 19 + [90] * 2, median_ms=80, p95_ms=90)
        errors = check_report(current, old, bad_reference)
        self.assertTrue(any("reference" in error and "500 KB median_ms"
                            in error for error in errors))
        self.assertFalse(any("reference" in error and "500 KB p95_ms"
                             in error for error in errors))

        good_reference = copy.deepcopy(old)
        good_reference["measurements"][0].update(
            samples_ms=[15] * 21, median_ms=15, p95_ms=15)
        good_reference["measurements"][1].update(
            samples_ms=[250] * 19 + [270] * 2, median_ms=250, p95_ms=270)
        self.assertEqual(check_report(current, old, good_reference), [])

    def test_reference_validation_rejects_malformed_zero_and_wrong_fixture(self):
        current = report()
        for reference in ([], {"measurements": []}):
            self.assertTrue(any(error.startswith("reference:")
                                for error in check_report(current, reference=reference)))

        reference = report()
        reference["measurements"][0]["samples_ms"] = [math.nan] * 21
        self.assertTrue(any(error.startswith("reference:")
                            for error in check_report(current, reference=reference)))

        reference = report()
        reference["measurements"][0].update(
            samples_ms=[0] * 21, median_ms=0, p95_ms=0)
        errors = check_report(current, reference=reference)
        self.assertTrue(any("reference: 50 KB median_ms must be greater than zero"
                            in error for error in errors))

        for field, value in (("utf8_bytes", 50_041),
                             ("utf16_length", 49_800),
                             ("syntax_sha256", "b" * 64)):
            reference = report()
            reference["measurements"][0][field] = value
            errors = check_report(current, reference=reference)
            self.assertTrue(any(f"reference: 50 KB fixture {field} does not match"
                                in error for error in errors))

    def test_relative_gate_rejects_fixture_identity_mismatch(self):
        for field, value in (("utf8_bytes", 500_041),
                             ("utf16_length", 49_800),
                             ("syntax_sha256", "b" * 64)):
            baseline = report()
            if field == "utf8_bytes":
                baseline["measurements"][0][field] = 50_041
                current = report()
            else:
                baseline["measurements"][0][field] = value
                current = report()
            errors = check_report(current, baseline)
            self.assertTrue(any(f"50 KB fixture {field} does not match" in e
                                for e in errors))

    def test_baseline_validation_fails_closed(self):
        for baseline in ([], {"measurements": []}):
            errors = check_report(report(), baseline)
            self.assertTrue(any(error.startswith("baseline:")
                                for error in errors))

        baseline = report()
        baseline["measurements"][0]["samples_ms"] = [math.nan] * 21
        errors = check_report(report(), baseline)
        self.assertTrue(any("baseline:" in error and "timings" in error
                            for error in errors))

        baseline = report()
        baseline["measurements"][0]["samples_ms"] = [True] * 21
        errors = check_report(report(), baseline)
        self.assertTrue(any("baseline:" in error and "timings" in error
                            for error in errors))

        baseline = report()
        baseline["measurements"][0]["median_ms"] = True
        errors = check_report(report(), baseline)
        self.assertTrue(any("baseline:" in error and "median_ms" in error
                            for error in errors))

        baseline = report()
        baseline["measurements"][0].update(
            samples_ms=[0] * 21, median_ms=0, p95_ms=0)
        errors = check_report(report(), baseline)
        self.assertTrue(any("baseline: 50 KB median_ms must be greater than zero"
                            in error for error in errors))

    def test_recorded_reference_cli_uses_archived_values_and_rejects_stall(self):
        fixtures = Path(__file__).parent / "fixtures/performance"
        with tempfile.TemporaryDirectory() as directory:
            paths = [Path(directory) / f"current-{index}.json" for index in range(3)]
            command = [sys.executable, str(Path(__file__).with_name("check_parser_performance.py")),
                       "--recorded-reference"]
            for path in paths:
                command += ["--current-report", str(path)]
            for name, status in (("current", 0), ("baseline", 1)):
                report = (fixtures / f"parser-{name}-af516.json").read_text()
                for path in paths:
                    path.write_text(report)
                result = subprocess.run(command, capture_output=True, text=True)
                self.assertEqual(result.returncode, status, result.stderr)
            self.assertEqual(subprocess.run(command[:-1] + [str(paths[0])],
                                            capture_output=True).returncode, 1)

    def test_archived_parser_controls_separate_stall_from_small_gain(self):
        fixtures = Path(__file__).parent / "fixtures/performance"
        current, baseline, reference = [json.loads(
            (fixtures / f"parser-{label}-af516.json").read_text())
            for label in ["current", "baseline", "reference"]]
        self.assertEqual(check_report(current, baseline, reference), [])
        self.assertEqual(check_report(reference, baseline, reference), [])
        self.assertTrue(any("300 ms CI budget" in error
                            for error in check_report(baseline)))
        self.assertEqual(check_paired_reports([current] * 3, [baseline] * 3,
                                              [reference] * 3), [])

    def test_cli_accepts_optional_baseline_and_reports_missing_file(self):
        with tempfile.TemporaryDirectory() as directory:
            report_path = Path(directory) / "report.json"
            report_path.write_text(json.dumps(report()), encoding="utf-8")
            script = Path(__file__).with_name("check_parser_performance.py")
            without_baseline = subprocess.run(
                [sys.executable, str(script), str(report_path)],
                capture_output=True, text=True, check=False)
            self.assertEqual(without_baseline.returncode, 0,
                             without_baseline.stderr)
            with_missing_baseline = subprocess.run(
                [sys.executable, str(script), str(report_path),
                 "--baseline-report", str(Path(directory) / "missing.json")],
                capture_output=True, text=True, check=False)
            self.assertEqual(with_missing_baseline.returncode, 1)
            self.assertIn("cannot validate report", with_missing_baseline.stderr)

            current = report()
            baseline = report()
            reference = report()
            for row in (current, baseline, reference):
                row["measurements"][0].update(
                    samples_ms=[20] * 21, median_ms=20, p95_ms=20)
                row["measurements"][1].update(
                    samples_ms=[40] * 21, median_ms=40, p95_ms=40)
            current["measurements"][0].update(
                samples_ms=[12] * 21, median_ms=12, p95_ms=12)
            current["measurements"][1].update(
                samples_ms=[24] * 21, median_ms=24, p95_ms=24)
            reference["measurements"][0].update(
                samples_ms=[15] * 21, median_ms=15, p95_ms=15)
            reference["measurements"][1].update(
                samples_ms=[30] * 21, median_ms=30, p95_ms=30)
            baseline_path = Path(directory) / "baseline.json"
            reference_path = Path(directory) / "reference.json"
            baseline_path.write_text(json.dumps(baseline), encoding="utf-8")
            reference_path.write_text(json.dumps(reference), encoding="utf-8")
            report_path.write_text(json.dumps(current), encoding="utf-8")
            both_comparisons = subprocess.run(
                [sys.executable, str(script), str(report_path),
                 "--baseline-report", str(baseline_path),
                 "--reference-report", str(reference_path)],
                capture_output=True, text=True, check=False)
            self.assertEqual(both_comparisons.returncode, 0,
                             both_comparisons.stderr)

    def test_budgets_apply_to_recomputed_median_and_p95(self):
        for index, budget in ((0, 50), (1, 300)):
            for timings in ([budget + 1] * 21, [1] * 19 + [budget + 1] * 2):
                value = report()
                row = value["measurements"][index]
                row.update(samples_ms=timings, median_ms=sorted(timings)[10],
                           p95_ms=sorted(timings)[19])
                self.assertTrue(check_report(value))
            value = copy.deepcopy(report())
            value["measurements"][index].update(
                samples_ms=[budget] * 21, median_ms=budget, p95_ms=budget)
            self.assertEqual(check_report(value), [])


class PairedParserGateTests(unittest.TestCase):
    def groups(self):
        groups = []
        for cost in (10, 20, 10):
            runs = [report() for _ in range(3)]
            for run in runs:
                for row in run["measurements"]:
                    row.update(samples_ms=[cost] * 21,
                               median_ms=cost, p95_ms=cost)
            groups.append(runs)
        return groups

    def test_small_tail_variance_is_diagnostic(self):
        groups = self.groups()
        row = groups[0][0]["measurements"][1]
        row.update(samples_ms=[10] * 19 + [25] * 2, p95_ms=25)
        self.assertEqual(check_paired_reports(*groups), [])
        groups[0][1]["measurements"][1].update(
            samples_ms=[10] * 19 + [25] * 2, p95_ms=25)
        self.assertEqual(check_paired_reports(*groups), [])

    def test_absolute_ceiling_in_one_run_cannot_be_hidden(self):
        groups = self.groups()
        groups[0][0]["measurements"][1].update(
            samples_ms=[301] * 21, median_ms=301, p95_ms=301)
        self.assertTrue(any("CI budget" in error
                            for error in check_paired_reports(*groups)))

    def test_controls_fail_closed_and_all_runs_match(self):
        for label in range(3):
            for field, value in (("syntax_sha256", "b" * 64),
                                 ("utf16_length", 49_899),
                                 ("utf8_bytes", 50_041),
                                 ("median_ms", True)):
                groups = self.groups()
                groups[label][2]["measurements"][0][field] = value
                self.assertTrue(check_paired_reports(*groups))
            groups = self.groups()
            groups[label].pop()
            self.assertTrue(check_paired_reports(*groups))

    def test_slow_historical_baseline_retains_fixture_validation(self):
        groups = self.groups()
        for run in groups[1]:
            run["measurements"][1].update(
                samples_ms=[386] * 21, median_ms=386, p95_ms=386)
        self.assertEqual(check_paired_reports(*groups), [])
        groups[1][0]["measurements"][1]["syntax_sha256"] = "b" * 64
        self.assertTrue(check_paired_reports(*groups))

    def test_reference_median_sustained_regression(self):
        groups = self.groups()
        for run in groups[0][:2]:
            run["measurements"][1].update(
                samples_ms=[46] * 21, median_ms=46, p95_ms=46)
        errors = check_paired_reports(*groups)
        self.assertTrue(any("reference" in error for error in errors))

    def test_reused_paths_and_symlink_aliases_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            groups = []
            for label in range(3):
                paths = []
                for index in range(3):
                    path = Path(directory) / f"{label}-{index}.json"
                    path.write_text(json.dumps(report()))
                    paths.append(path)
                groups.append(paths)
            self.assertEqual(len(read_paired_paths(groups)), 3)
            groups[1][0].unlink()
            groups[1][0].symlink_to(groups[0][0])
            with self.assertRaises(ValueError):
                read_paired_paths(groups)


if __name__ == "__main__":
    unittest.main()
