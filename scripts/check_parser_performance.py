#!/usr/bin/env python3
"""Validate the opt-in Unicode full-parser benchmark and its CI budgets."""

import argparse
import json
import math
import re
import statistics
import sys
from pathlib import Path


def finite_number(value):
    if type(value) not in (int, float):
        return False
    try:
        return math.isfinite(value) and value >= 0
    except OverflowError:
        return False


def _validate_report(report, *, enforce_budgets):
    if not isinstance(report, dict):
        return ["report must be an object"]
    rows = report.get("measurements")
    if not isinstance(rows, list) or len(rows) != 2:
        return ["measurements must contain exactly two fixtures"]
    errors = []
    seen = set()
    for index, row in enumerate(rows):
        prefix = f"fixture {index}: "
        if not isinstance(row, dict):
            errors.append(prefix + "must be an object")
            continue
        size = row.get("utf8_bytes")
        expected = next((value for value in (50_000, 500_000)
                         if type(size) is int and value <= size <= value + 500), None)
        if expected is None or expected in seen:
            errors.append(prefix + "size must uniquely match 50 KB or 500 KB")
        else:
            seen.add(expected)
        length = row.get("utf16_length")
        if not (type(length) is int and type(size) is int and 0 < length <= size):
            errors.append(prefix + "UTF-16 length must be positive and at most bytes")
        digest = row.get("syntax_sha256")
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-fA-F]{64}", digest):
            errors.append(prefix + "syntax_sha256 must contain 64 hexadecimal digits")
        samples = row.get("samples_ms")
        if (not isinstance(samples, list) or len(samples) != 21
                or not all(finite_number(value) for value in samples)):
            errors.append(prefix + "exactly 21 finite nonnegative timings required")
            continue
        summaries = {"median_ms": statistics.median(samples),
                     "p95_ms": sorted(samples)[math.ceil(.95 * len(samples)) - 1]}
        # Absolute CI ceilings: 50 ms at 50 KB, 300 ms at 500 KB.
        budget = 50 if expected == 50_000 else 300
        for field, calculated in summaries.items():
            provided = row.get(field)
            if (not finite_number(provided)
                    or not math.isclose(provided, calculated, rel_tol=1e-9, abs_tol=1e-7)):
                errors.append(prefix + f"{field} must match recomputed timings")
            if enforce_budgets and expected is not None and calculated > budget:
                errors.append(prefix + f"{field} exceeds {budget} ms CI budget")
    if seen != {50_000, 500_000}:
        errors.append("both 50 KB and 500 KB fixtures are required")
    return errors


def _compare_reports(current, comparison, *, label, ratio):
    errors = []
    current_rows = {row["utf8_bytes"] // 1000: row
                    for row in current["measurements"]}
    comparison_rows = {row["utf8_bytes"] // 1000: row
                       for row in comparison["measurements"]}
    for size in (50, 500):
        current_row = current_rows[size]
        comparison_row = comparison_rows[size]
        for field in ("utf8_bytes", "utf16_length", "syntax_sha256"):
            if current_row[field] != comparison_row[field]:
                errors.append(
                    f"{label}: {size} KB fixture {field} does not match"
                )
        fields = ("median_ms", "p95_ms") if label == "baseline" else ("median_ms",)
        for field in fields:
            comparison_value = comparison_row[field]
            if comparison_value == 0:
                errors.append(
                    f"{label}: {size} KB {field} must be greater than zero"
                )
            # Relative median comparisons tolerate the measured small-run
            # noise floor; absolute p95 ceilings still bound tail latency.
            allowance = (2 if size == 50 else 5) if label == "reference" else 0
            if comparison_value > 0 and current_row[field] > ratio * comparison_value + allowance:
                if label == "baseline":
                    errors.append(
                        f"{size} KB {field} must improve by at least 20%: "
                        f"{current_row[field]:.3f} ms vs baseline "
                        f"{comparison_value:.3f} ms"
                    )
                else:
                    errors.append(
                        f"{size} KB {field} exceeds 120% of reference + {allowance} ms: "
                        f"{current_row[field]:.3f} ms vs reference "
                        f"{comparison_value:.3f} ms"
                    )
    return errors


def check_report(report, baseline=None, reference=None):
    """Validate timings and optionally compare baseline and reference reports."""
    errors = _validate_report(report, enforce_budgets=True)
    comparisons = (("baseline", baseline, 0.8),
                   ("reference", reference, 1.2))
    for label, comparison, ratio in comparisons:
        if comparison is None:
            continue
        comparison_errors = _validate_report(
            comparison, enforce_budgets=False
        )
        if comparison_errors:
            errors.extend(
                f"{label}: {error}" for error in comparison_errors
            )
        elif not errors:
            errors.extend(_compare_reports(
                report, comparison, label=label, ratio=ratio
            ))
    return errors


def check_paired_reports(current, baseline, reference, *, emit=None):
    """Compare three independent launches after validating every raw report."""
    groups = {"current": current, "baseline": baseline, "reference": reference}
    errors = []
    for label, reports in groups.items():
        if not isinstance(reports, list) or len(reports) != 3:
            errors.append(f"{label}: exactly three independent reports required")
            continue
        for index, report in enumerate(reports):
            errors.extend(f"{label} run {index + 1}: {error}" for error in
                          _validate_report(report, enforce_budgets=label != "baseline"))
    if errors:
        return errors
    identity = {row["utf8_bytes"] // 1000: row
                for row in current[0]["measurements"]}
    for label, reports in groups.items():
        for index, report in enumerate(reports):
            for row in report["measurements"]:
                size = row["utf8_bytes"] // 1000
                for field in ("utf8_bytes", "utf16_length", "syntax_sha256"):
                    if row[field] != identity[size][field]:
                        errors.append(f"{label} run {index + 1}: {size} KB "
                                      f"fixture {field} does not match")
                if row["median_ms"] <= 0 or row["p95_ms"] <= 0:
                    errors.append(f"{label} run {index + 1}: timings must "
                                  "be greater than zero")
    if errors:
        return errors
    aggregates = {}
    for label, reports in groups.items():
        aggregate = {"measurements": []}
        for size in (50, 500):
            rows = [next(row for row in report["measurements"]
                         if row["utf8_bytes"] // 1000 == size)
                    for report in reports]
            row = dict(rows[0])
            for field in ("median_ms", "p95_ms"):
                row[field] = statistics.median(value[field] for value in rows)
            aggregate["measurements"].append(row)
        aggregates[label] = aggregate
        if emit is not None:
            for row in aggregate["measurements"]:
                emit(f"{label} {row['utf8_bytes'] // 1000} KB: "
                     f"median-of-medians={row['median_ms']:.3f} ms; "
                     f"median-of-p95={row['p95_ms']:.3f} ms")
    return (_compare_reports(aggregates["current"], aggregates["baseline"],
                             label="baseline", ratio=0.8)
            + _compare_reports(aggregates["current"], aggregates["reference"],
                               label="reference", ratio=1.2))


def read_paired_paths(groups):
    """Reject reused paths, including symlink aliases, before reading reports."""
    paths = [path.resolve() for group in groups for path in group]
    if any(len(group) != 3 for group in groups) or len(set(paths)) != 9:
        raise ValueError("exactly three distinct paths per variant required")
    return [[json.loads(path.read_text()) for path in group] for group in groups]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path, nargs="?")
    for label in ("current", "baseline", "reference"):
        parser.add_argument(f"--paired-{label}-report", type=Path, action="append")
    parser.add_argument("--baseline-report", type=Path)
    parser.add_argument("--reference-report", type=Path)
    arguments = parser.parse_args()
    try:
        groups = [getattr(arguments, f"paired_{label}_report")
                  for label in ("current", "baseline", "reference")]
        if any(group is not None for group in groups):
            if arguments.report or arguments.baseline_report or arguments.reference_report:
                raise ValueError("paired and single report modes cannot be combined")
            errors = check_paired_reports(*read_paired_paths(
                [group or [] for group in groups]), emit=print)
        else:
            if arguments.report is None:
                raise ValueError("a report or three paired groups are required")
            errors = check_report(
                json.loads(arguments.report.read_text()),
                json.loads(arguments.baseline_report.read_text())
                if arguments.baseline_report else None,
                json.loads(arguments.reference_report.read_text())
                if arguments.reference_report else None)

    except (OSError, ValueError, TypeError, OverflowError) as error:
        errors = [f"cannot validate report: {error}"]
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("Unicode full-parser performance guard passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
