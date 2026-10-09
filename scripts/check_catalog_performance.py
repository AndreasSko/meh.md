#!/usr/bin/env python3
"""Fail closed when the synthetic notebook catalog benchmark is invalid."""

import argparse
import json
import math
import sys
from pathlib import Path
from typing import Any


FIXTURES = (100, 500)
DEFAULT_LOAD_MS = {100: 250.0, 500: 500.0}
DEFAULT_WRITE_MS = {100: 250.0, 500: 750.0}
# Includes scheduling variance on the shared CI runner. The known 0.10.6
# regression exceeds this ceiling with the same main-queue timer.
DEFAULT_MAIN_ACTOR_GAP_MS = 200.0
NOTEBOOK_ID = "11111111-1111-4111-8111-111111111111"
REPEATED_METRICS = (
    "snapshot_ms",
    "validated_startup_projection_ms",
    "activity_fork_and_snapshot_ms",
)
SINGLE_METRICS = (
    "replica_load_ms",
    "replica_first_activity_write_ms",
    "replica_load_max_main_actor_gap_ms",
    "replica_first_activity_max_main_actor_gap_ms",
)
METRICS = frozenset((*REPEATED_METRICS, *SINGLE_METRICS))
HEARTBEAT_METRICS = (
    "replica_load_max_main_actor_gap_ms",
    "replica_first_activity_max_main_actor_gap_ms",
)


def _nonnegative_number(value: Any) -> bool:
    if (not isinstance(value, (int, float)) or isinstance(value, bool)
            or value < 0):
        return False
    try:
        return math.isfinite(value)
    except OverflowError:
        return False


def check_report(
    report: Any,
    max_load_ms: dict[int, float] | None = None,
    max_write_ms: dict[int, float] | None = None,
    max_main_actor_gap_ms: float = DEFAULT_MAIN_ACTOR_GAP_MS,
    enforce_budgets: bool = True,
) -> list[str]:
    """Validate the exact synthetic fixture and enforce replica budgets."""
    load_limits = DEFAULT_LOAD_MS if max_load_ms is None else max_load_ms
    write_limits = DEFAULT_WRITE_MS if max_write_ms is None else max_write_ms
    if not _nonnegative_number(max_main_actor_gap_ms):
        return ["main actor gap budget must be finite and nonnegative"]
    if not isinstance(report, list):
        return ["report root must be an array"]
    if len(report) != len(FIXTURES):
        return ["report must contain exactly the 100 and 500 item fixtures"]

    errors: list[str] = []
    observed: dict[int, dict[str, list[float]]] = {}
    for index, case in enumerate(report):
        if not isinstance(case, dict):
            errors.append(f"cases[{index}] must be an object")
            continue
        count = case.get("item_count")
        if (not isinstance(count, int) or isinstance(count, bool)
                or count not in FIXTURES):
            errors.append(f"cases[{index}].item_count must be 100 or 500")
            continue
        if count in observed:
            errors.append(f"item_count {count} must occur exactly once")
            continue
        observed[count] = {}

        history_count = case.get("history_activity_count")
        if (not isinstance(history_count, int) or isinstance(history_count, bool)
                or history_count != count - 1):
            errors.append(f"item_count {count} has invalid history activity count")
        if case.get("notebook_id") != NOTEBOOK_ID:
            errors.append(f"item_count {count} has unexpected notebook fixture ID")
        snapshot_bytes = case.get("snapshot_bytes")
        if (not isinstance(snapshot_bytes, int) or isinstance(snapshot_bytes, bool)
                or snapshot_bytes <= 0):
            errors.append(f"item_count {count} snapshot_bytes must be positive")

        measurements = case.get("measurements_ms")
        if not isinstance(measurements, dict):
            errors.append(f"item_count {count} measurements_ms must be an object")
            continue
        if set(measurements) != METRICS:
            errors.append(f"item_count {count} has missing or unknown metrics")
        for metric in sorted(METRICS):
            samples = measurements.get(metric)
            expected = 3 if metric in REPEATED_METRICS else 1
            if not isinstance(samples, list) or len(samples) != expected:
                errors.append(
                    f"item_count {count} {metric} needs exactly {expected} samples"
                )
                continue
            if any(not _nonnegative_number(value) for value in samples):
                errors.append(
                    f"item_count {count} {metric} must contain finite "
                    "nonnegative numbers"
                )
                continue
            observed[count][metric] = [float(value) for value in samples]

    if set(observed) != set(FIXTURES):
        errors.append("report must contain each required fixture exactly once")

    if not enforce_budgets:
        return errors

    for count in FIXTURES:
        metrics = observed.get(count, {})
        for metric, limits in (
            ("replica_load_ms", load_limits),
            ("replica_first_activity_write_ms", write_limits),
        ):
            samples = metrics.get(metric)
            budget = limits.get(count)
            if budget is None or not _nonnegative_number(budget):
                errors.append(f"missing valid {metric} budget for {count} items")
            elif samples and samples[0] > budget:
                errors.append(
                    f"{metric} for {count} items is {samples[0]:.1f} ms; "
                    f"budget is {budget:.1f} ms"
                )
        for metric in HEARTBEAT_METRICS:
            samples = metrics.get(metric)
            if samples and samples[0] > max_main_actor_gap_ms:
                errors.append(
                    f"{metric} for {count} items is {samples[0]:.1f} ms; "
                    f"budget is {max_main_actor_gap_ms:.1f} ms"
                )
    return errors


def _budget(value: str) -> float:
    try:
        parsed = float(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("budget must be a number") from error
    if not _nonnegative_number(parsed):
        raise argparse.ArgumentTypeError("budget must be finite and nonnegative")
    return parsed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    for count in FIXTURES:
        load_default = DEFAULT_LOAD_MS[count]
        write_default = DEFAULT_WRITE_MS[count]
        parser.add_argument(
            f"--max-load-ms-{count}", type=_budget,
            default=float(load_default),
            help=(f"replica load ceiling for {count} items "
                  f"(default: {load_default})"),
        )
        parser.add_argument(
            f"--max-write-ms-{count}", type=_budget,
            default=float(write_default),
            help=("first activity write ceiling for "
                  f"{count} items (default: {write_default})"),
        )
    parser.add_argument(
        "--max-main-actor-gap-ms", type=_budget,
        default=DEFAULT_MAIN_ACTOR_GAP_MS,
        help=f"main actor heartbeat gap ceiling (default: {DEFAULT_MAIN_ACTOR_GAP_MS})",
    )
    args = parser.parse_args()
    try:
        report = json.loads(args.report.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        print("catalog benchmark report could not be read as JSON", file=sys.stderr)
        return 2

    loads = {100: args.max_load_ms_100, 500: args.max_load_ms_500}
    writes = {100: args.max_write_ms_100, 500: args.max_write_ms_500}
    errors = check_report(
        report, loads, writes, args.max_main_actor_gap_ms
    )
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1

    print("catalog benchmark report passed (100 and 500 item fixtures)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
