import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from check_ci_test_coverage import (check_coverage, normalize_id, swift_log_cases,
                                   xcresult_cases, audit_reports, audit_pr,
                                   REQUIRED_CHECKS)


def record(identifier, **kwargs):
    return {"id": identifier, "category": "standard", "expected_skip": False, **kwargs}


class CoverageTests(unittest.TestCase):
    def test_missing_extra_duplicate_and_skipped_tests_fail(self):
        records = [record("T/C/testOne"), record("T/C/testTwo")]
        check_coverage(records, [r["id"] for r in records])
        for passed in (["T/C/testOne"], ["T/C/testOne", "T/C/testTwo", "T/C/testThree"],
                       ["T/C/testOne", "T/C/testTwo", "T/C/testOne"]):
            with self.assertRaises(ValueError):
                check_coverage(records, passed)
        with self.assertRaises(ValueError):
            check_coverage(records, ["T/C/testOne"], ["T/C/testTwo"])

    def test_platform_exclusions_and_caret_replacement_are_explicit(self):
        records = [record("T/C/testOne"), record("T/C/testCloud", category="live-icloud"),
                   record("T/C/testPad", expected_skip=True, skip_reason="Requires iPad"),
                   record("T/C/testCaret", category="app-host", expected_skip=True)]
        with tempfile.TemporaryDirectory() as temp:
            proof = Path(temp) / "proof"
            proof.write_text("PASS: indicator visible\n")
            result = check_coverage(records, ["T/C/testOne"], ["T/C/testCaret"], proof)
            self.assertEqual(result["replaced_by_app_host"], ["T/C/testCaret"])
            with self.assertRaises(ValueError):
                check_coverage(records, ["T/C/testOne"], ["T/C/testCaret"])
            proof.write_text("FAIL: indicator absent")
            with self.assertRaises(ValueError):
                check_coverage(records, ["T/C/testOne"], ["T/C/testCaret"], proof)
            check_coverage(records, ["T/C/testOne", "T/C/testCaret"])

    def test_xcresult_requires_individual_success_and_counts(self):
        summary = dict(result="Passed", failedTests=0, skippedTests=0,
                       expectedFailures=0, passedTests=1, totalTestCount=1)
        case = dict(nodeType="Test Case", nodeIdentifier="C/testOne()", result="Passed")
        tests = {"testNodes": [{"children": [case]}]}
        self.assertEqual(xcresult_cases(summary, tests, "T"), ["T/C/testOne"])
        for changed in ({"skippedTests": 1}, {"result": "Failed"}, {"passedTests": 2}):
            with self.assertRaises(ValueError):
                xcresult_cases({**summary, **changed}, tests, "T")
        case["result"] = "Skipped"
        with self.assertRaises(ValueError):
            xcresult_cases(summary, tests, "T")

    def test_compiler_enumeration_and_finished_log_must_agree(self):
        records = [record("T/C/testOne")]
        with tempfile.TemporaryDirectory() as temp:
            discovery = Path(temp) / "list"
            log = Path(temp) / "log"
            discovery.write_text("T.C/testOne\n")
            log.write_text("Test Case '-[T.C testOne]' started.\n"
                           "   Test Case '-[T.C testOne]' passed (0.001 seconds).\n")
            self.assertEqual(swift_log_cases(log, discovery, records), (["T/C/testOne"], []))
            for prefix in ("0.0004999999418942024", "4.99e-05", "1E+3"):
                log.write_text("Test Case '-[T.C testOne]' started.\n"
                               f"{prefix}Test Case '-[T.C testOne]' passed (35.595 seconds).\n")
                self.assertEqual(swift_log_cases(log, discovery, records), (["T/C/testOne"], []))
            log.write_text("Test Case '-[T.C testOne]' started.\n"
                           "          0Test Case '-[T.C testOne]' passed (27.084 seconds).\n")
            self.assertEqual(swift_log_cases(log, discovery, records), (["T/C/testOne"], []))
            log.write_text("Test Case '-[T.C testOne]' started.\n"
                           "prose Test Case '-[T.C testOne]' passed (0.001 seconds).\n")
            with self.assertRaises(ValueError):
                swift_log_cases(log, discovery, records)
            log.write_text("Test Case '-[T.C testOne]' started.\n"
                           "0Test Case '-[T.C testOne]' passed (0.001 seconds).\n"
                           "0Test Case '-[T.C testOne]' passed (0.001 seconds).\n")
            with self.assertRaises(ValueError):
                swift_log_cases(log, discovery, records)
            log.write_text("Test Case '-[T.C testOne]' started.\n")
            with self.assertRaises(ValueError):
                swift_log_cases(log, discovery, records)
            discovery.write_text("T.C/testExtra\n")
            with self.assertRaises(ValueError):
                swift_log_cases(log, discovery, records)

    def test_api_rejects_stale_head_and_latest_failed_check(self):
        root = Path(__file__).parents[1]
        pr = {"head": {"sha": "expected-sha"}}
        with patch("check_ci_test_coverage.gh_json", side_effect=[{"nameWithOwner": "owner/repo"}, pr]):
            with patch("check_ci_test_coverage.subprocess.check_output", return_value="old-sha\n"):
                with self.assertRaisesRegex(ValueError, "exact head"):
                    audit_pr(root, 123)
        with patch("check_ci_test_coverage.gh_json", side_effect=[{"nameWithOwner": "owner/repo"}, pr]):
            with patch("check_ci_test_coverage.subprocess.check_output",
                       side_effect=["expected-sha\n", " M Tests/Test.swift\n"]):
                with self.assertRaisesRegex(ValueError, "clean checkout"):
                    audit_pr(root, 123)
        checks = [{"check_runs": [{"id": 1, "name": name, "conclusion": "success"}
                                  for name in REQUIRED_CHECKS] +
                                 [{"id": 2, "name": "All feasible tests", "conclusion": "failure"}]}]
        with patch("check_ci_test_coverage.gh_json", side_effect=[{"nameWithOwner": "owner/repo"}, pr, checks]):
            with patch("check_ci_test_coverage.subprocess.check_output", side_effect=["expected-sha\n", ""]):
                with self.assertRaisesRegex(ValueError, "not green"):
                    audit_pr(root, 123)

    def test_matrix_cannot_succeed_without_all_reports(self):
        with self.assertRaises(ValueError):
            audit_reports(Path(__file__).parents[1], [])
        self.assertEqual(normalize_id("C/testOne()", "T"), "T/C/testOne")
        with self.assertRaises(ValueError):
            normalize_id("garbage")

    def test_performance_exception_is_explicit_and_preserves_coverage_gate(self):
        root = Path(__file__).parents[1]
        pr = {"head": {"sha": "expected-sha"}, "html_url": "https://example/pr"}
        checks = [{"check_runs": [
            {"id": 1, "name": name,
             "conclusion": "failure" if name == "editor-performance" else "success",
             "html_url": "https://example/performance"}
            for name in REQUIRED_CHECKS]}]
        run = {"id": 5, "path": ".github/workflows/test-coverage.yml",
               "event": "pull_request", "head_sha": "expected-sha",
               "conclusion": "success", "html_url": "https://example/run"}

        def responses():
            return [{"nameWithOwner": "owner/repo"}, pr, checks,
                    [{"workflow_runs": [run]}]]

        with patch("check_ci_test_coverage.subprocess.check_output",
                   side_effect=["expected-sha\n", ""]):
            with patch("check_ci_test_coverage.gh_json", side_effect=responses()):
                with self.assertRaisesRegex(ValueError, "editor-performance"):
                    audit_pr(root, 123)
        with patch("check_ci_test_coverage.subprocess.check_output",
                   side_effect=["expected-sha\n", ""]), \
                patch("check_ci_test_coverage.gh_json", side_effect=responses()), \
                patch("check_ci_test_coverage.subprocess.run"), \
                patch("check_ci_test_coverage.audit_reports", return_value=1578):
            result = audit_pr(root, 123, ignore_editor_performance=True)
            self.assertNotIn("editor-performance", result["required_checks"])
            self.assertIn("All feasible tests", result["required_checks"])
            self.assertEqual(result["ignored_checks"][0]["conclusion"], "failure")
            self.assertEqual(result["ignored_checks"][0]["url"], "https://example/performance")
        checks[0]["check_runs"].append(
            {"id": 2, "name": "All feasible tests", "conclusion": "failure"})
        with patch("check_ci_test_coverage.subprocess.check_output",
                   side_effect=["expected-sha\n", ""]):
            with patch("check_ci_test_coverage.gh_json", side_effect=responses()):
                with self.assertRaisesRegex(ValueError, "All feasible tests"):
                    audit_pr(root, 123, ignore_editor_performance=True)


if __name__ == "__main__":
    unittest.main()
