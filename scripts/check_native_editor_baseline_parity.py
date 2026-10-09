#!/usr/bin/env python3
"""Check current native results against an approved recorded inventory."""

import json
import sys
from pathlib import Path


INVENTORY = Path(__file__).with_name("fixtures") / "native-editor-inventory.json"
RETIRED_METHODS = {
    "EditorSearchNavigationTests/testNativeFindAndMatchRevealDoNotEditOrFocusEditor()",
    "MarkdownEditorPositionTests/testCaptureAndRestorePreserveSelectionViewportAndEditorState()",
    "MarkdownEditorPositionTests/testNavigationPreviewStartsAtSavedAnchorBeforeAsyncAttachment()",
}


def inspect(summary, tree, status):
    if not isinstance(summary, dict) or not isinstance(tree, dict):
        raise ValueError("summary and test tree must be objects")
    cases = {}

    def visit(node):
        if not isinstance(node, dict):
            raise ValueError("invalid test node")
        if node.get("nodeType") == "Test Case":
            identifier, result = node.get("nodeIdentifier"), node.get("result")
            if (not isinstance(identifier, str) or "/test" not in identifier
                    or identifier in cases or result not in ("Passed", "Failed", "Skipped")):
                raise ValueError("missing, duplicate, or invalid test case")
            cases[identifier] = result
        children = node.get("children", [])
        if not isinstance(children, list):
            raise ValueError("invalid test children")
        for child in children:
            visit(child)

    for node in tree.get("testNodes", []):
        visit(node)
    if not cases:
        raise ValueError("full native suite must be present")
    counts = {result: sum(value == result for value in cases.values())
              for result in ("Passed", "Failed", "Skipped")}
    for field, expected in (("totalTestCount", len(cases)),
                            ("passedTests", counts["Passed"]),
                            ("failedTests", counts["Failed"]),
                            ("skippedTests", counts["Skipped"]),
                            ("expectedFailures", 0)):
        if type(summary.get(field)) is not int or summary[field] != expected:
            raise ValueError(f"{field} disagrees with test tree")
    failed = {name for name, result in cases.items() if result == "Failed"}
    skipped = {name for name, result in cases.items() if result == "Skipped"}
    if status != 0 or failed or summary.get("result") != "Passed":
        raise ValueError(f"native test run failed or infrastructure status is invalid: {status}")
    if summary.get("testFailures"):
        raise ValueError("native result contains failure details")
    configurations = summary.get("devicesAndConfigurations", [])
    if len(configurations) != 1:
        raise ValueError("one simulator configuration is required")
    device = configurations[0].get("device", {})
    configuration = (device.get("modelName"), device.get("platform"), device.get("osVersion"))
    if configuration != ("iPhone 18 Pro", "iOS Simulator", "27.0"):
        raise ValueError(f"unexpected simulator configuration: {configuration}")
    return cases, skipped


def compare(inventory, summary, tree, status):
    expected = set(inventory["methods"])
    allowed_skips = set(inventory["allowedSkips"])
    if not expected or not allowed_skips <= expected:
        raise ValueError("recorded inventory is empty or has unknown allowed skips")
    cases, skipped = inspect(summary, tree, status)
    if len(expected) != len(inventory["methods"]):
        raise ValueError("recorded inventory contains duplicate methods")
    missing = expected - cases.keys()
    if missing:
        raise ValueError(f"current omitted recorded methods: {sorted(missing)}")
    if RETIRED_METHODS & cases.keys():
        raise ValueError("retired methods must be absent from current")
    unexpected_skips = skipped - allowed_skips
    if unexpected_skips:
        raise ValueError(f"new skipped methods: {sorted(unexpected_skips)}")
    if any(cases[name] != "Passed" for name in expected - allowed_skips):
        raise ValueError("recorded native methods must pass")
    if any(result != "Passed" for name, result in cases.items() if name not in expected):
        raise ValueError("new native methods must pass")
    return expected, skipped


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: check_native_editor_baseline_parity.py EVIDENCE_ROOT")
    root = Path(sys.argv[1])
    try:
        inventory = json.loads(INVENTORY.read_text())
        summary = json.loads((root / "current-summary.json").read_text())
        tree = json.loads((root / "current-tests.json").read_text())
        status = int((root / "current-status.txt").read_text())
        methods, skips = compare(inventory, summary, tree, status)
    except (ValueError, TypeError, KeyError, OSError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print(f"METHOD COVERAGE: {len(methods)} recorded, {summary['totalTestCount']} current")
    print(f"RECORDED SOURCE: {inventory['sourceCommit']} (CI {inventory['ciRun']})")
    print("CURRENT failing methods: none")
    print("CURRENT skipped methods:", *sorted(skips), sep="\n  ")
    print("PASS: all recorded methods are present and passing")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
