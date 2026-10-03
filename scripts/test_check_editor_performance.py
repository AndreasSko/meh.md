import copy
import unittest

from check_editor_performance import COUNTS, check_report


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


class CheckEditorPerformanceTests(unittest.TestCase):
    def test_accepts_complete_report_within_budget(self):
        self.assertEqual(check_report(valid_report(), 500), [])

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
