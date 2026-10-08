#!/usr/bin/env python3
"""Prove source test coverage from result files, or audit a PR through GitHub's API.

A successful build or xcodebuild exit code alone is not coverage evidence.
Every selected test must appear exactly once and pass. Only explicit platform
inapplicability and the live iCloud suite are excluded from the selection.
"""

import argparse
import hashlib
import json
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

from ci_test_inventory import inventory

ROOT = Path(__file__).resolve().parents[1]
REPORT_VERSION = 1
MATRIX = {("host", "python"), ("macos", "package"), ("iphone", "native"),
          ("iphone", "ui"), ("ipad", "ui"), ("macos", "ui")}
REQUIRED_CHECKS = {"Deterministic replica and loopback checks",
                   "Release build (IOS)", "Release build (MAC_OS)",
                   "editor-performance", "editor-regressions",
                   "All feasible tests"}


def selected_records(root, platform, scope):
    records = inventory(root, platform)
    if scope == "ui":
        ui = [r for r in records if r["target"] == "meh.mdUITests"]
        if platform != "iphone":
            for record in ui:
                if record["category"] in {"ordered-loopback", "import-fixture"}:
                    record["expected_skip"] = True
                    record["skip_reason"] = "Proven by the iPhone job with dedicated import/sync fixtures"
        return ui
    if scope == "native":
        return [r for r in records if r["target"] == "NativeEditorTests"]
    if scope == "package":
        return [r for r in records if r["target"] != "meh.mdUITests"]
    raise ValueError(f"Unknown scope: {scope}")


def inventory_digest(records):
    return hashlib.sha256(json.dumps(records, sort_keys=True).encode()).hexdigest()


def expected_ids(records):
    return {r["id"] for r in records
            if r["category"] != "live-icloud" and (not r["expected_skip"] or r["category"] == "app-host")}


def normalize_id(value, target=None):
    value = value.removesuffix("()")
    parts = value.split("/")
    if len(parts) == 3:
        return value
    if len(parts) == 2 and target:
        return f"{target}/{value}"
    raise ValueError(f"Invalid test identifier: {value!r}")


def xcresult_cases(summary, tests, target):
    if summary.get("result") != "Passed":
        raise ValueError(f"XCTest did not pass: {summary.get('result')}")
    for key in ("failedTests", "skippedTests", "expectedFailures"):
        if summary.get(key) != 0:
            raise ValueError(f"Unexpected {key}: {summary.get(key)}")
    cases = []

    def visit(node):
        if node.get("nodeType") == "Test Case":
            if node.get("result") != "Passed":
                raise ValueError(f"Test did not pass: {node.get('nodeIdentifier')}")
            cases.append(normalize_id(node["nodeIdentifier"], target))
        for child in node.get("children", []):
            visit(child)

    for node in tests.get("testNodes", []):
        visit(node)
    if not cases or len(cases) != len(set(cases)):
        raise ValueError("XCTest result has empty or duplicate test cases")
    if summary.get("passedTests") != len(cases) or summary.get("totalTestCount") != len(cases):
        raise ValueError("XCTest summary does not match individual results")
    return cases


def xunit_cases(path):
    cases = []
    skipped = []
    for case in ET.parse(path).getroot().iter("testcase"):
        classname = case.attrib["classname"]
        parts = classname.split(".")
        if len(parts) != 2:
            raise ValueError(f"Unexpected xUnit classname: {classname}")
        identifier = f"{parts[0]}/{parts[1]}/{case.attrib['name'].removesuffix('()')}"
        if case.find("failure") is not None or case.find("error") is not None:
            raise ValueError(f"Package test failed: {identifier}")
        (skipped if case.find("skipped") is not None else cases).append(identifier)
    if not cases or len(cases + skipped) != len(set(cases + skipped)):
        raise ValueError("Package result has empty or duplicate test cases")
    return cases, skipped


def swift_log_cases(path, discovered, records):
    declared = {r["id"] for r in records}
    compiled = set()
    for line in discovered.read_text().splitlines():
        match = re.fullmatch(r"(\w+)\.(\w+)/(test\w+)", line)
        if match:
            compiled.add("/".join(match.groups()))
        elif line.strip():
            raise ValueError(f"Unexpected Swift test enumeration: {line}")
    if compiled != declared:
        raise ValueError(f"Compiler/source mismatch: missing={sorted(declared - compiled)}, "
                         f"unexpected={sorted(compiled - declared)}")
    started, finished, passed, skipped = [], [], [], []
    # Benchmark counters can omit their trailing newline before XCTest writes.
    # Accept only a numeric counter prefix, not arbitrary prose containing a case.
    pattern = r"(?:[0-9]+)?Test Case '-\[(\w+)\.(\w+) (test\w+)\]' (started|passed|skipped|failed)"
    for line in path.read_text().splitlines():
        match = re.match(pattern, line.lstrip())
        if not match:
            continue
        identifier = "/".join(match.groups()[:3])
        status = match[4]
        if status == "started":
            started.append(identifier)
        else:
            finished.append(identifier)
            if status == "failed":
                raise ValueError(f"Package test failed: {identifier}")
            (passed if status == "passed" else skipped).append(identifier)
    if sorted(started) != sorted(finished) or set(started) != compiled:
        raise ValueError("Package log is incomplete or omits compiled tests")
    if len(finished) != len(set(finished)):
        raise ValueError("Package log contains duplicate test executions")
    return passed, skipped


def check_coverage(records, passed, skipped=(), caret_proof=None):
    expected = expected_ids(records)
    allowed_skips = {r["id"] for r in records if r["category"] == "app-host"}
    actual = set(passed)
    missing = expected - actual
    unexpected = actual - expected
    # The native insertion-indicator check is repeated by a real AppKit app
    # because the SwiftPM executable does not always supply that OS subview.
    if skipped:
        if set(skipped) - allowed_skips:
            raise ValueError(f"Unexpected skipped tests: {sorted(set(skipped) - allowed_skips)}")
        if caret_proof is None or not caret_proof.read_text().startswith("PASS:"):
            raise ValueError("Skipped insertion-indicator test requires passing app-host proof")
        missing -= set(skipped)
    if missing or unexpected or len(passed) != len(actual):
        raise ValueError(f"Coverage mismatch: missing={sorted(missing)}, "
                         f"unexpected={sorted(unexpected)}, duplicate={len(passed) != len(actual)}")
    return {"passed": sorted(actual), "replaced_by_app_host": sorted(skipped),
            "excluded": [{"id": r["id"], "reason": r.get("skip_reason", r["category"])}
                         for r in records if r["id"] not in expected]}


def audit_reports(root, reports):
    found = set()
    for report in reports:
        key = (report["platform"], report["scope"])
        if key not in MATRIX or key in found:
            raise ValueError(f"Unexpected or duplicate coverage report: {key}")
        if report.get("version") != REPORT_VERSION:
            raise ValueError("Unsupported coverage report version")
        if key == ("host", "python"):
            from run_python_test_coverage import declared_tests
            expected = declared_tests(root)
            digest = hashlib.sha256(json.dumps(sorted(expected)).encode()).hexdigest()
            if (report.get("inventory_sha256") != digest
                    or set(report.get("passed", [])) != expected
                    or len(report["passed"]) != len(expected)):
                raise ValueError("Python evidence omits or duplicates declared tests")
            found.add(key)
            continue
        records = selected_records(root, *key)
        if report.get("inventory_sha256") != inventory_digest(records):
            raise ValueError(f"Stale inventory in {key}")
        # Recheck exact coverage; report success is never trusted on its own.
        replacements = report.get("replaced_by_app_host", [])
        allowed = {r["id"] for r in records if r["category"] == "app-host"}
        if set(replacements) - allowed or (replacements and not report.get("app_host_passed")):
            raise ValueError(f"Unproven replacement tests in {key}")
        check_coverage(records, report["passed"] + replacements)
        found.add(key)
    if found != MATRIX:
        raise ValueError(f"Missing matrix reports: {sorted(MATRIX - found)}")
    return sum(len(r["passed"]) + len(r.get("replaced_by_app_host", [])) for r in reports)


def gh_json(*arguments):
    return json.loads(subprocess.check_output(["gh", *arguments], text=True))


def audit_pr(root, number, ignore_editor_performance=False):
    repo = gh_json("repo", "view", "--json", "nameWithOwner")["nameWithOwner"]
    pr = gh_json("api", f"repos/{repo}/pulls/{number}")
    sha = pr["head"]["sha"]
    local_sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
    if local_sha != sha:
        raise ValueError("Check out the PR's exact head before auditing its evidence")
    if subprocess.check_output(["git", "status", "--porcelain"], cwd=root, text=True).strip():
        raise ValueError("Use a clean checkout of the exact PR head before auditing its evidence")
    checks = gh_json("api", "--paginate", "--slurp",
                     f"repos/{repo}/commits/{sha}/check-runs?per_page=100")
    latest = {}
    for page in checks:
        for check in page["check_runs"]:
            if check["name"] not in latest or check["id"] > latest[check["name"]]["id"]:
                latest[check["name"]] = check
    required = REQUIRED_CHECKS - ({"editor-performance"} if ignore_editor_performance else set())
    failed = {name: latest.get(name, {}).get("conclusion", "missing")
              for name in required
              if latest.get(name, {}).get("conclusion") != "success"}
    if failed:
        raise ValueError(f"Required CI is not green at {sha}: {failed}")
    runs = gh_json("api", "--paginate", "--slurp",
                   f"repos/{repo}/actions/runs?head_sha={sha}&per_page=100")
    coverage = [run for page in runs for run in page["workflow_runs"]
                if run["path"] == ".github/workflows/test-coverage.yml"
                and run["event"] == "pull_request" and run["head_sha"] == sha]
    if not coverage:
        raise ValueError("No PR test coverage workflow run at this head")
    run = max(coverage, key=lambda item: item["id"])
    if run["conclusion"] != "success":
        raise ValueError("Latest coverage workflow has not succeeded")
    with tempfile.TemporaryDirectory(prefix="meh-ci-api-") as temporary:
        subprocess.run(["gh", "run", "download", str(run["id"]), "--repo", repo,
                        "--pattern", "test-coverage-*", "--dir", temporary], check=True)
        paths = list(Path(temporary).rglob("coverage-report.json"))
        reports = [json.loads(path.read_text()) for path in paths]
        total = audit_reports(root, reports)
    ignored = []
    if ignore_editor_performance:
        check = latest.get("editor-performance", {})
        ignored.append({"name": "editor-performance",
                        "conclusion": check.get("conclusion", "missing"),
                        "url": check.get("html_url"),
                        "reason": "Explicit --ignore-editor-performance exception"})
    return {"pr": pr["html_url"], "head_sha": sha, "run": run["html_url"],
            "proven_test_executions": total, "required_checks": sorted(required),
            "ignored_checks": ignored,
            "live_icloud": "Excluded: requires signed-in accounts and real CloudKit"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--platform", choices=["macos", "iphone", "ipad"])
    parser.add_argument("--scope", choices=["package", "native", "ui"])
    parser.add_argument("--results", type=Path, help="JSON list of {summary, tests} files")
    parser.add_argument("--xunit", type=Path)
    parser.add_argument("--swift-log", type=Path)
    parser.add_argument("--discovered", type=Path)
    parser.add_argument("--caret-proof", type=Path)
    parser.add_argument("--reports", type=Path, help="Audit all coverage-report.json files below directory")
    parser.add_argument("--pr", type=int, help="Audit exact PR head via gh API and downloaded artifacts")
    parser.add_argument("--ignore-editor-performance", action="store_true",
                        help="Explicitly report and ignore only the separate performance check")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--inventory", action="store_true")
    args = parser.parse_args()
    if args.ignore_editor_performance and not args.pr:
        parser.error("--ignore-editor-performance requires --pr")
    try:
        if args.pr:
            result = audit_pr(args.root, args.pr, args.ignore_editor_performance)
        elif args.reports:
            reports = [json.loads(p.read_text()) for p in args.reports.rglob("coverage-report.json")]
            result = {"proven_test_executions": audit_reports(args.root, reports)}
        elif args.platform and args.scope:
            records = selected_records(args.root, args.platform, args.scope)
            if args.inventory:
                result = records
            else:
                skipped = []
                if args.swift_log:
                    if not args.discovered:
                        raise ValueError("Provide --discovered Swift compiler test list")
                    passed, skipped = swift_log_cases(args.swift_log, args.discovered, records)
                elif args.xunit:
                    passed, skipped = xunit_cases(args.xunit)
                elif args.results:
                    target = "meh.mdUITests" if args.scope == "ui" else "NativeEditorTests"
                    passed = []
                    for entry in json.loads(args.results.read_text()):
                        passed += xcresult_cases(json.loads(Path(entry["summary"]).read_text()),
                                                json.loads(Path(entry["tests"]).read_text()), target)
                else:
                    raise ValueError("Provide --results or --xunit")
                result = check_coverage(records, passed, skipped, args.caret_proof)
                result.update(version=REPORT_VERSION, platform=args.platform, scope=args.scope,
                              inventory_sha256=inventory_digest(records),
                              app_host_passed=bool(skipped and args.caret_proof))
        else:
            raise ValueError("Provide --pr, --reports, or --platform and --scope")
        rendered = json.dumps(result, indent=2) + "\n"
        if args.output:
            args.output.write_text(rendered)
        if args.output and isinstance(result, dict) and "passed" in result:
            print(json.dumps({"passed": len(result["passed"]),
                              "excluded": len(result.get("excluded", [])),
                              "replaced_by_app_host": result.get("replaced_by_app_host", [])}))
        else:
            print(rendered)
    except (ValueError, KeyError, TypeError, OSError, ET.ParseError,
            subprocess.CalledProcessError) as error:
        sys.exit(str(error))


if __name__ == "__main__":
    main()
