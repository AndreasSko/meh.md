#!/usr/bin/env python3
"""Fail-closed matching of a compiled test universe, plan, and XCTest results."""

import collections
import re


def canonical(identifier):
    if not isinstance(identifier, str):
        raise ValueError("Invalid test identifier")
    value = identifier.removesuffix("()")
    value = value.removeprefix("meh.mdUITests/")
    if not re.fullmatch(r"\w+/test\w+", value):
        raise ValueError(f"Unsupported test identifier: {identifier!r}")
    return value


def discovered(payload, plan_name="CIUniverse"):
    # Xcode 27 flat JSON is captured in fixtures/ui_enumeration_xcode27.json.
    # Platform plans enumerate only their enabled compiled cases; resolving
    # every plan selector against those cases rejects disabled selections.
    if payload.get("errors") != []:
        raise ValueError("Enumeration reported errors or unsupported schema")
    values = payload.get("values")
    if not isinstance(values, list) or len(values) != 1:
        raise ValueError("Expected exactly one enumeration test plan")
    value = values[0]
    if value.get("testPlan") != plan_name or (
        plan_name == "CIUniverse" and value.get("disabledTests") != []
    ):
        raise ValueError("Unexpected compiled plan or disabled universe tests")
    tests = value.get("enabledTests")
    if not isinstance(tests, list):
        raise ValueError("Unsupported enabledTests schema")
    found = [canonical(test["identifier"]) for test in tests]
    if not found or len(found) != len(set(found)):
        raise ValueError("Enumeration has no cases or duplicate cases")
    return set(found)


def expected_cases(plan, universe):
    targets = plan["testTargets"]
    if len(targets) != 1 or targets[0]["target"]["name"] != "meh.mdUITests":
        raise ValueError("Expected exactly the UI test target")
    selected = targets[0]["selectedTests"]
    if not selected or len(selected) != len(set(selected)):
        raise ValueError("Missing or duplicate plan selectors")
    expected = set()
    for selector in selected:
        matches = {
            case
            for case in universe
            if case == selector or case.startswith(selector + "/")
        }
        if not matches:
            raise ValueError(f"Plan selector absent from compiled universe: {selector}")
        expected.update(matches)
    return expected


def results(summary, tests, platform):
    """Map each executed case to Passed or Failed for one result bundle."""
    cases = {}

    def visit(node):
        if node.get("nodeType") == "Test Case":
            identifier = canonical(node.get("nodeIdentifier"))
            if identifier in cases:
                raise ValueError(f"Duplicate case: {identifier}")
            if node.get("result") not in {"Passed", "Failed"}:
                raise ValueError(f"Test neither passed nor failed: {node}")
            if any(
                child.get("nodeType") == "Repetition"
                for child in node.get("children", [])
            ):
                raise ValueError(f"Unexpected native repetition: {identifier}")
            cases[identifier] = node["result"]
        for child in node.get("children", []):
            visit(child)

    for node in tests.get("testNodes", []):
        visit(node)
    failed = sum(result == "Failed" for result in cases.values())
    for key, value in {
        "passedTests": len(cases) - failed,
        "totalTestCount": len(cases),
        "failedTests": failed,
        "skippedTests": 0,
        "expectedFailures": 0,
    }.items():
        if summary.get(key) != value:
            raise ValueError(f"{key}: expected {value}, got {summary.get(key)}")
    if summary.get("result") != ("Failed" if failed else "Passed"):
        raise ValueError(f"Unexpected summary result: {summary.get('result')}")
    configurations = summary.get("devicesAndConfigurations", [])
    if len(configurations) != 1:
        raise ValueError("Expected one device configuration")
    device = configurations[0].get("device", {})
    if not str(device.get("osVersion", "")).startswith("27."):
        raise ValueError(f"Expected OS 27: {device}")
    if platform == "mac":
        valid = device.get("platform") == "macOS"
    else:
        model = str(device.get("modelName", ""))
        valid = device.get("platform") == "iOS Simulator" and (
            model == "iPhone 12 Pro Max"
            if platform == "iphone"
            else model.startswith("iPad")
        )
    if not valid:
        raise ValueError(f"Unexpected device: {device}")
    return cases


def failed(first, expected):
    """Cases to retry after the full run; every expected case must have run."""
    if not expected:
        raise ValueError("Empty expected inventory")
    if set(first) != set(expected):
        raise ValueError(
            f"Missing/unexpected cases: {sorted(set(first) ^ set(expected))}"
        )
    return {case for case, result in first.items() if result != "Passed"}


def check(first, expected, retry=None):
    """Pass when every case passed, once or on its single retry."""
    retried = failed(first, expected)
    if not retried:
        if retry is not None:
            raise ValueError("Retry results without a failed case")
        return {}
    if retry is None or set(retry) != retried:
        raise ValueError(f"Retry must run exactly the failed cases: {sorted(retried)}")
    still_failing = sorted(case for case in retried if retry[case] != "Passed")
    if still_failing:
        raise ValueError(f"Failed again on retry: {still_failing}")
    return {case: ["Failed", "Passed"] for case in sorted(retried)}
