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


def check(summary, tests, expected, platform):
    if not expected:
        raise ValueError("Empty expected inventory")
    for key, value in {
        "passedTests": len(expected),
        "totalTestCount": len(expected),
        "failedTests": 0,
        "skippedTests": 0,
        "expectedFailures": 0,
    }.items():
        if summary.get(key) != value:
            raise ValueError(f"{key}: expected {value}, got {summary.get(key)}")
    if summary.get("result") != "Passed":
        raise ValueError("Test summary did not pass")
    cases = []
    retried = {}

    def visit(node):
        if node.get("nodeType") == "Test Case":
            if node.get("result") != "Passed":
                raise ValueError(f"Test did not pass: {node}")
            identifier = canonical(node.get("nodeIdentifier"))
            repetitions = [
                child for child in node.get("children", [])
                if child.get("nodeType") == "Repetition"
            ]
            if repetitions:
                results = [run.get("result") for run in repetitions]
                if (
                    len(results) not in {1, 2}
                    or any(result not in {"Passed", "Failed"} for result in results)
                    or "Passed" not in results
                ):
                    raise ValueError(f"Unexpected native retry sequence: {identifier}")
                for index, run in enumerate(repetitions, 1):
                    if (
                        run.get("nodeIdentifier") != str(index)
                        or not node.get("nodeIdentifierURL")
                        or run.get("nodeIdentifierURL") != node["nodeIdentifierURL"]
                    ):
                        raise ValueError(f"Mismatched native retry: {identifier}")
                if len(repetitions) == 2:
                    retried[identifier] = results
            cases.append(identifier)
        for child in node.get("children", []):
            visit(child)

    for node in tests.get("testNodes", []):
        visit(node)
    if collections.Counter(cases) != collections.Counter(expected):
        raise ValueError(f"Missing/unexpected/duplicate cases: {cases}")
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
    return {identifier: retried[identifier] for identifier in sorted(retried)}
