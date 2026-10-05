#!/usr/bin/env python3
"""Reject missing, skipped, or unexpected iPhone editor regression tests."""

import collections
import json
import sys
from pathlib import Path


NATIVE_CLASSES = {
    "MarkdownEditorScrollPaddingTests": 12,
    "MarkdownParagraphGapTests": 9,
    "MarkdownHeadingGeometryTests": 1,
    "MarkdownRenderingAttributeTests": 1,
    "NativeEditorIntegrationTests": 12,
}
UI_METHODS = {
    "EditorScrollTypingUITests/testSourceReopeningKeyboardNearEndRevealsCaret()",
    "EditorScrollTypingUITests/testLivePreviewReopeningKeyboardNearEndRevealsCaret()",
    "EditorScrollTypingUITests/testSourceTypingAtEndKeepsCaretStable()",
    "EditorScrollTypingUITests/testLivePreviewTypingAtEndKeepsCaretStable()",
    "EditorScrollTypingUITests/testLivePreviewListReturnAtEndKeepsCaretStable()",
    "EditorScrollTypingUITests/testLivePreviewTypingOnEmptyEndLineKeepsCaretStable()",
    "EditorLongNoteTapUITests/testTapNearEndReplacesPreviousEOFSelection()",
}


def check(phase, summary, tests):
    expected = sum(NATIVE_CLASSES.values()) if phase == "native" else len(UI_METHODS)
    counts = {
        "passedTests": expected,
        "failedTests": 0,
        "skippedTests": 0,
        "expectedFailures": 0,
        "totalTestCount": expected,
    }
    for field, value in counts.items():
        if summary.get(field) != value:
            raise ValueError(f"{phase}: {field} must be {value}, got {summary.get(field)}")
    if summary.get("result") != "Passed":
        raise ValueError(f"{phase}: result must be Passed")

    cases = []

    def visit(node):
        if node.get("nodeType") == "Test Case":
            if node.get("result") != "Passed":
                raise ValueError(f"{phase}: test did not pass: {node.get('nodeIdentifier')}")
            identifier = node.get("nodeIdentifier")
            if not isinstance(identifier, str) or not identifier:
                raise ValueError(f"{phase}: test case has missing or invalid identifier")
            cases.append(identifier)
        for child in node.get("children", []):
            visit(child)

    for node in tests.get("testNodes", []):
        visit(node)
    if len(cases) != expected or len(set(cases)) != expected:
        raise ValueError(f"{phase}: expected {expected} distinct test cases")
    if phase == "native":
        classes = collections.Counter(case.split("/")[0] for case in cases)
        if classes != NATIVE_CLASSES:
            raise ValueError(f"native: unexpected class counts: {dict(classes)}")
    elif set(cases) != UI_METHODS:
        raise ValueError(f"ui: unexpected test selection: {sorted(cases)}")

    configurations = summary.get("devicesAndConfigurations", [])
    if len(configurations) != 1:
        raise ValueError(f"{phase}: expected one simulator configuration")
    device = configurations[0].get("device", {})
    if (device.get("modelName") != "iPhone 12 Pro Max"
            or device.get("platform") != "iOS Simulator"
            or not str(device.get("osVersion", "")).startswith("27.")):
        raise ValueError(f"{phase}: unexpected simulator: {device}")
    return cases


if __name__ == "__main__":
    if len(sys.argv) != 4 or sys.argv[1] not in ("native", "ui"):
        sys.exit("usage: check_editor_regression_results.py native|ui SUMMARY TESTS")
    try:
        cases = check(sys.argv[1], json.loads(Path(sys.argv[2]).read_text()),
                      json.loads(Path(sys.argv[3]).read_text()))
    except (ValueError, KeyError, TypeError, OSError) as error:
        sys.exit(str(error))
    print(f"PASS: {len(cases)} distinct {sys.argv[1]} iOS regression tests; no skips")
