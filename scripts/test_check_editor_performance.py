import unittest

from check_editor_performance import COUNTS, check_report


def valid_report(size=500, context="standard"):
    report = {
        "scenario": "large-note",
        "mode": "livePreview",
        "context": context,
        "requested_kb": size,
        "utf8_bytes": size * 1000,
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
        report["measurements"]["deletion_to_idle_ms"] = [251.0] * COUNTS["deletion"]
        errors = check_report(report, 500)
        self.assertTrue(any("deletion_to_idle_ms p95" in e for e in errors))

    def test_bulk_insert_uses_separate_single_sample_ceiling(self):
        report = valid_report()
        report["measurements"]["bulk_insert_to_idle_ms"] = [1_200.0]
        bulk_step = next(step for step in report["steps"]
                         if step["action"] == "bulk_insert")
        bulk_step["to_idle_ms"] = 1_200.0
        errors = check_report(report, 500)
        self.assertEqual(errors, [])

        report["measurements"]["bulk_insert_to_idle_ms"] = [1_501.0]
        bulk_step["to_idle_ms"] = 1_501.0
        errors = check_report(report, 500)
        self.assertTrue(any("single-sample ceiling 1500 ms" in e for e in errors))

        report = valid_report()
        report["measurements"]["typing_to_idle_ms"][-2:] = [251.0, 251.0]
        typing_steps = [step for step in report["steps"]
                        if step["action"] == "typing"]
        for step in typing_steps[-2:]:
            step["to_idle_ms"] = 251.0
        errors = check_report(report, 500)
        self.assertTrue(any("typing_to_idle_ms p95" in e for e in errors))

    def test_fails_wrong_context_or_mode(self):
        report = valid_report(50, "standard")
        errors = check_report(report, 50, "livePreview", "mixed")
        self.assertTrue(any("context must be mixed" in e for e in errors))
        errors = check_report(report, 50, "source", "standard")
        self.assertTrue(any("mode must be source" in e for e in errors))

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
