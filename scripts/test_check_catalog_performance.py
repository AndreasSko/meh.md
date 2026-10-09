import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from check_catalog_performance import (
    DEFAULT_MAIN_ACTOR_GAP_MS,
    METRICS,
    NOTEBOOK_ID,
    REPEATED_METRICS,
    check_report,
)


def valid_report():
    cases = []
    for count in (100, 500):
        cases.append({
            "item_count": count,
            "history_activity_count": count - 1,
            "snapshot_bytes": count * 100,
            "notebook_id": NOTEBOOK_ID,
            "measurements_ms": {
                metric: ([1.0, 2.0, 3.0] if metric in REPEATED_METRICS
                         else [4.0])
                for metric in METRICS
            },
        })
    return cases


class CheckCatalogPerformanceTests(unittest.TestCase):
    def test_fresh_catalog_control_is_validated_without_required_budget_failure(self):
        for name in ["current", "baseline"]:
            report = json.loads((Path(__file__).parent / "fixtures/performance" /
                                 f"catalog-{name}-af516.json").read_text())
            self.assertEqual(check_report(report, enforce_budgets=False), [])
            report[0]["notebook_id"] = "wrong"
            self.assertTrue(check_report(report, enforce_budgets=False))

    def test_archived_catalog_heartbeat_distinguishes_known_stall(self):
        fixtures = Path(__file__).parent / "fixtures/performance"
        current = json.loads((fixtures / "catalog-current-af516.json").read_text())
        baseline = json.loads((fixtures / "catalog-baseline-af516.json").read_text())
        self.assertEqual(check_report(current), [])
        errors = check_report(baseline)
        self.assertTrue(any("main_actor_gap_ms" in error for error in errors))
        self.assertTrue(any("200.0 ms" in error for error in errors))

    def test_accepts_exact_fixtures_and_measurements(self):
        self.assertEqual(check_report(valid_report()), [])

    def test_cli_and_function_share_default_load_budget(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "catalog.json"
            checker = Path(__file__).with_name("check_catalog_performance.py")
            for value, expected_status in ((200.0, 0), (250.0, 0), (251.0, 1)):
                with self.subTest(load_ms=value):
                    report = valid_report()
                    report[0]["measurements_ms"]["replica_load_ms"] = [value]
                    path.write_text(json.dumps(report), encoding="utf-8")
                    result = subprocess.run(
                        [sys.executable, str(checker), str(path)],
                        capture_output=True, text=True, check=False,
                    )
                    self.assertEqual(result.returncode, expected_status,
                                     result.stdout + result.stderr)
                    self.assertEqual(bool(check_report(report)),
                                     bool(expected_status))

    def test_rejects_missing_duplicate_and_unexpected_fixtures(self):
        self.assertTrue(check_report(valid_report()[:1]))
        report = valid_report()
        report[1]["item_count"] = 100
        errors = check_report(report)
        self.assertTrue(any("exactly once" in error for error in errors))
        report = valid_report()
        report[1]["item_count"] = 200
        self.assertTrue(any("100 or 500" in error for error in check_report(report)))

    def test_rejects_fixture_metadata_and_metric_shape_errors(self):
        report = valid_report()
        report[0]["history_activity_count"] = 100
        report[0]["snapshot_bytes"] = 0
        report[0]["notebook_id"] = "personal-note-id"
        report[0]["measurements_ms"]["snapshot_ms"] = [1.0]
        report[1]["measurements_ms"]["unexpected_metric"] = [1.0]
        errors = check_report(report)
        self.assertTrue(any("history activity count" in error for error in errors))
        self.assertTrue(any("snapshot_bytes" in error for error in errors))
        self.assertTrue(any("unexpected notebook fixture ID" in error
                            for error in errors))
        self.assertTrue(any("snapshot_ms needs exactly 3" in error
                            for error in errors))
        self.assertTrue(any("missing or unknown metrics" in error
                            for error in errors))

    def test_rejects_boolean_and_nonfinite_samples(self):
        for value in (True, float("nan"), float("inf"), -0.1):
            with self.subTest(value=value):
                report = valid_report()
                report[0]["measurements_ms"]["snapshot_ms"][0] = value
                errors = check_report(report)
                self.assertTrue(any("finite nonnegative numbers" in error
                                    for error in errors))

    def test_enforces_configured_replica_latency_ceilings(self):
        report = valid_report()
        report[1]["measurements_ms"]["replica_load_ms"] = [501.0]
        report[0]["measurements_ms"]["replica_first_activity_write_ms"] = [
            251.0
        ]
        errors = check_report(report)
        self.assertTrue(any("replica_load_ms for 500 items" in error
                            for error in errors))
        self.assertTrue(any("replica_first_activity_write_ms for 100 items"
                            in error for error in errors))

    def test_configured_budgets_accept_boundary_values(self):
        report = valid_report()
        report[0]["measurements_ms"]["replica_load_ms"] = [7.0]
        report[1]["measurements_ms"]["replica_first_activity_write_ms"] = [
            9.0
        ]
        self.assertEqual(
            check_report(
                report,
                max_load_ms={100: 7.0, 500: 8.0},
                max_write_ms={100: 8.0, 500: 9.0},
            ),
            [],
        )

    def test_requires_valid_single_sample_heartbeat_metrics(self):
        for value in (None, True, float("nan"), float("inf"), -1.0,
                      10 ** 400):
            with self.subTest(value=value):
                report = valid_report()
                report[0]["measurements_ms"][
                    "replica_load_max_main_actor_gap_ms"
                ] = [value]
                errors = check_report(report)
                self.assertTrue(any(
                    "replica_load_max_main_actor_gap_ms" in error
                    and ("exactly 1" in error or "finite nonnegative" in error)
                    for error in errors
                ))

        report = valid_report()
        del report[0]["measurements_ms"][
            "replica_first_activity_max_main_actor_gap_ms"
        ]
        errors = check_report(report)
        self.assertTrue(any("missing or unknown metrics" in error
                            for error in errors))
        self.assertTrue(any("replica_first_activity_max_main_actor_gap_ms"
                            in error for error in errors))

    def test_rejects_heartbeat_gap_regression_at_both_fixture_sizes(self):
        report = valid_report()
        report[0]["measurements_ms"][
            "replica_load_max_main_actor_gap_ms"
        ] = [DEFAULT_MAIN_ACTOR_GAP_MS + 0.1]
        report[1]["measurements_ms"][
            "replica_first_activity_max_main_actor_gap_ms"
        ] = [DEFAULT_MAIN_ACTOR_GAP_MS + 0.1]
        errors = check_report(report)
        self.assertTrue(any("replica_load_max_main_actor_gap_ms for 100 items"
                            in error for error in errors))
        self.assertTrue(any("replica_first_activity_max_main_actor_gap_ms "
                            "for 500 items" in error for error in errors))

    def test_accepts_heartbeat_gap_at_limit(self):
        report = valid_report()
        for case in report:
            for metric in (
                "replica_load_max_main_actor_gap_ms",
                "replica_first_activity_max_main_actor_gap_ms",
            ):
                case["measurements_ms"][metric] = [DEFAULT_MAIN_ACTOR_GAP_MS]
        self.assertEqual(check_report(report), [])


if __name__ == "__main__":
    unittest.main()
