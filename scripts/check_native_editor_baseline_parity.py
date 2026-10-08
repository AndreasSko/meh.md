#!/usr/bin/env python3
"""Report existing native failures and reject new or incomplete results."""

import json
import sys
from pathlib import Path


REQUIRED_METHODS = {
    "EditorSearchNavigationTests/testNativeFindAndMatchRevealDoNotEditOrFocusEditor()",
    "MarkdownEditorPositionTests/testCaptureAndRestorePreserveSelectionViewportAndEditorState()",
    "MarkdownEditorPositionTests/testNavigationPreviewStartsAtSavedAnchorBeforeAsyncAttachment()",
}


CURRENT_INVARIANT_METHODS = {
    "MarkdownNativeTextChangeTests/testAttributeFixingKeepsExactMiddleInsertionIntent()",
    "MarkdownRenderingIndexTests/testSelectionReusesSyntaxIndexAndEverySyntaxChangeInvalidatesIt()",
    "MarkdownRenderingIndexTests/testParsedRenderingAndConcealmentMatchLegacyForEveryCharacter()",
    "MarkdownRenderingIndexTests/testNestedAndBoundaryCodeSpansPreserveExactLegacyPredicate()",
    "MarkdownSelectionSnapshotTests/testSelectionReportsLiteralCurrentSnapshotWithoutRebuildingIt()",
}

# Pinned main 64a7267 has 240 methods; this branch adds five invariants.
PINNED_BASELINE_METHOD_COUNT = 240
MINIMUM_CURRENT_METHOD_COUNT = 245


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
        for child in node.get("children", []):
            visit(child)

    for node in tree.get("testNodes", []):
        visit(node)
    if not cases or not REQUIRED_METHODS <= cases.keys():
        raise ValueError("full native suite and all diagnostic methods must be present")
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
    if skipped & REQUIRED_METHODS:
        raise ValueError("diagnostic methods must execute, not skip")
    if status != (65 if failed else 0):
        raise ValueError(f"unexpected test process status {status}; possible infrastructure failure")
    if summary.get("result") != ("Failed" if failed else "Passed"):
        raise ValueError("result disagrees with method failures")
    configurations = summary.get("devicesAndConfigurations", [])
    if len(configurations) != 1:
        raise ValueError("one simulator configuration is required")
    device = configurations[0].get("device", {})
    configuration = (device.get("modelName"), device.get("platform"), device.get("osVersion"))
    if configuration[:2] != ("iPhone 18 Pro", "iOS Simulator") or configuration[2] != "27.0":
        raise ValueError(f"unexpected simulator configuration: {configuration}")
    return cases, failed, skipped, configuration


def compare(baseline_summary, baseline_tree, baseline_status,
            current_summary, current_tree, current_status):
    baseline, old_failures, old_skips, configuration = inspect(
        baseline_summary, baseline_tree, baseline_status)
    current, failures, skips, current_configuration = inspect(
        current_summary, current_tree, current_status)
    if len(baseline) != PINNED_BASELINE_METHOD_COUNT:
        raise ValueError("pinned baseline must contain exactly 240 native methods")
    if len(current) < MINIMUM_CURRENT_METHOD_COUNT or not CURRENT_INVARIANT_METHODS <= current.keys():
        raise ValueError("current must contain at least 245 native methods and all five new invariants")
    if any(current[method] != "Passed" for method in CURRENT_INVARIANT_METHODS):
        raise ValueError("all five new invariant methods must pass")
    if configuration != current_configuration:
        raise ValueError("baseline and current simulator configurations differ")
    if not baseline.keys() <= current.keys():
        raise ValueError(f"current omitted baseline methods: {sorted(baseline.keys() - current.keys())}")
    if not skips <= old_skips:
        raise ValueError(f"new skipped methods: {sorted(skips - old_skips)}")
    if failures - old_failures:
        raise ValueError(f"NEW current failing methods: {sorted(failures - old_failures)}")
    return old_failures, failures, old_skips


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: check_native_editor_baseline_parity.py EVIDENCE_ROOT")
    root = Path(sys.argv[1])
    arguments = []
    try:
        for label in ("baseline", "current"):
            arguments.extend((json.loads((root / f"{label}-summary.json").read_text()),
                              json.loads((root / f"{label}-tests.json").read_text()),
                              int((root / f"{label}-status.txt").read_text())))
        existing, failures, skips = compare(*arguments)
    except (ValueError, TypeError, KeyError, OSError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print(f"METHOD COVERAGE: baseline {arguments[0]['totalTestCount']}, "
          f"current {arguments[3]['totalTestCount']}")
    print("BASELINE failing methods:", *sorted(existing or {"none"}), sep="\n  ")
    print("CURRENT existing failing methods:", *sorted(failures or {"none"}), sep="\n  ")
    print("BASELINE skipped methods:", *sorted(skips or {"none"}), sep="\n  ")
    print("PASS: full native suite has no new failing or skipped methods")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
