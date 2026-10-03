#!/usr/bin/env python3
"""Fail closed when the native editor performance report regresses."""

import argparse
import json
import math
import re
import statistics
import sys
from pathlib import Path
from typing import Any


COUNTS = {
    "typing": 21,
    "deletion": 6,
    "bulk_insert": 1,
    "middle_bold_open": 2,
    "middle_bold_typing": 6,
    "middle_bold_close": 2,
}
FIDELITY = (
    "source_and_selection_preserved",
    "saved_text_preserved",
    "final_presentation_verified",
)
SHAPE_SUFFIX_BYTES = {
    "standard": 0,
    "long-line": 65_538,
    "nearby-table": 52,
}


def percentile95(values: list[float]) -> float:
    """Return the nearest-rank 95th percentile."""
    return sorted(values)[math.ceil(0.95 * len(values)) - 1]


def check_report(
    report: Any, size_kb: int, mode: str = "livePreview",
    context: str | None = None, host: str = "editor",
    shape: str = "standard", baseline: Any = None,
    enforce_budgets: bool = True, reference: Any = None,
) -> list[str]:
    errors: list[str] = []
    if not isinstance(report, dict):
        return ["report root must be a JSON object"]

    for field in FIDELITY:
        if report.get(field) is not True:
            errors.append(f"{field} must be true")
    if report.get("scenario") != "large-note":
        errors.append("scenario must be large-note")
    if report.get("mode") != mode:
        errors.append(f"mode must be {mode}")
    if report.get("host") != host:
        errors.append(f"host must be {host}")
    if shape not in SHAPE_SUFFIX_BYTES:
        errors.append(f"unsupported expected shape: {shape}")
    elif report.get("shape") != shape:
        errors.append(f"shape must be {shape}")
    expected_context = context or ("mixed" if size_kb == 50 else "standard")
    if report.get("context") != expected_context:
        errors.append(f"context must be {expected_context}")
    if report.get("requested_kb") != size_kb:
        errors.append(f"requested_kb must be {size_kb}")
    fixture_bytes = report.get("utf8_bytes")
    shape_suffix = SHAPE_SUFFIX_BYTES.get(shape, 0)
    minimum_bytes = size_kb * 1_000 + shape_suffix
    if (not isinstance(fixture_bytes, int) or isinstance(fixture_bytes, bool)
            or fixture_bytes < minimum_bytes
            or fixture_bytes > minimum_bytes + 500):
        errors.append(f"utf8_bytes must be between {minimum_bytes} and "
                      f"{minimum_bytes + 500} for shape {shape}")
    if shape == "long-line" and size_kb != 50:
        errors.append("long-line shape is currently supported only at 50 KB")
    if (not isinstance(report.get("full_parses_during_edits"), int)
            or isinstance(report.get("full_parses_during_edits"), bool)):
        errors.append("full_parses_during_edits must be an integer")
    elif report["full_parses_during_edits"] < 0:
        errors.append("full_parses_during_edits must be nonnegative")
    elif shape == "standard" and report["full_parses_during_edits"] != 0:
        errors.append("full parses occurred during measured edits")
    source_utf16_length = report.get("utf16_length")
    if (
        not isinstance(source_utf16_length, int)
        or isinstance(source_utf16_length, bool)
        or source_utf16_length <= 0
        or (isinstance(fixture_bytes, int) and source_utf16_length > fixture_bytes)
    ):
        errors.append("utf16_length must be a positive integer no greater than utf8_bytes")

    measurements = report.get("measurements")
    if not isinstance(measurements, dict):
        errors.append("measurements must be an object")
        measurements = {}
    for key, samples in measurements.items():
        if not isinstance(samples, list) or any(
            not isinstance(value, (int, float)) or isinstance(value, bool)
            or not math.isfinite(value) or value < 0 for value in samples
        ):
            errors.append(f"measurements.{key} must contain finite nonnegative numbers")
    steps = report.get("steps")
    if not isinstance(steps, list):
        errors.append("steps must be an array")
        steps = []

    for key in ("open_to_idle_ms", "main_actor_scheduling_delay_ms",
                "autosave_wait_including_debounce_ms"):
        samples = measurements.get(key)
        if not isinstance(samples, list) or not samples:
            errors.append(f"{key} must contain at least one sample")
        elif any(not isinstance(v, (int, float)) or isinstance(v, bool)
                 or not math.isfinite(v) or v < 0 for v in samples):
            errors.append(f"{key} must contain finite nonnegative numbers")

    for kind, expected in COUNTS.items():
        for suffix in ("synchronous_ms", "to_idle_ms"):
            key = f"{kind}_{suffix}"
            samples = measurements.get(key)
            if not isinstance(samples, list) or len(samples) != expected:
                errors.append(f"{key} needs exactly {expected} samples")
                continue
            if any(not isinstance(v, (int, float)) or isinstance(v, bool)
                   or not math.isfinite(v) or v < 0 for v in samples):
                errors.append(f"{key} must contain finite nonnegative numbers")

    required_metrics = [f"{kind}_{suffix}" for kind in COUNTS for suffix in
                        ("synchronous_ms", "to_idle_ms")]
    # Absolute ceilings include virtualized simulator scheduling variance.
    # The 500 KB baseline comparison separately catches lost CRDT fast paths.
    sync_budget = 50 if size_kb <= 50 else 150
    idle_budget = (500 if shape == "nearby-table" else 250) if size_kb <= 50 else 1000
    for key in required_metrics:
        if key.startswith("bulk_insert_"):
            continue
        samples = measurements.get(key)
        if isinstance(samples, list) and samples and all(
            isinstance(v, (int, float)) and not isinstance(v, bool)
            and math.isfinite(v) and v >= 0 for v in samples
        ):
            budget = sync_budget if key.endswith("synchronous_ms") else idle_budget
            p95 = percentile95(samples)
            if enforce_budgets and p95 > budget:
                errors.append(f"{key} p95 {p95:.1f} ms exceeds {budget} ms")

    # p95 of 21 samples omits one outlier. Keep cold first-input latency
    # visible and bound every subsequent character independently.
    typing_idle = measurements.get("typing_to_idle_ms", [])
    if (enforce_budgets and isinstance(typing_idle, list)
            and len(typing_idle) == COUNTS["typing"]
            and all(isinstance(value, (int, float)) and not isinstance(value, bool)
                    and math.isfinite(value) and value >= 0 for value in typing_idle)):
        first_limit = 500 if size_kb <= 50 else 2_000
        subsequent_limit = 500
        if typing_idle[0] > first_limit:
            errors.append(f"first typing sample exceeds {first_limit} ms ceiling")
        if max(typing_idle[1:]) > subsequent_limit:
            errors.append(f"subsequent typing sample exceeds {subsequent_limit} ms ceiling")

    bulk_sync_budget = sync_budget
    bulk_idle_budget = 500 if size_kb <= 50 else 2_000
    for suffix, budget in (("synchronous_ms", bulk_sync_budget),
                           ("to_idle_ms", bulk_idle_budget)):
        key = f"bulk_insert_{suffix}"
        samples = measurements.get(key)
        if (isinstance(samples, list) and len(samples) == 1
                and isinstance(samples[0], (int, float))
                and not isinstance(samples[0], bool)
                and math.isfinite(samples[0]) and samples[0] >= 0
                and enforce_budgets and samples[0] > budget):
            errors.append(f"{key} {samples[0]:.1f} ms exceeds single-sample "
                          f"ceiling {budget} ms")

    counts = {kind: 0 for kind in COUNTS}
    step_timings = {
        kind: {"synchronous_ms": [], "to_idle_ms": []}
        for kind in COUNTS
    }
    if not steps:
        errors.append("steps must contain measured edit records")
    for index, step in enumerate(steps):
        if not isinstance(step, dict):
            errors.append(f"steps[{index}] must be an object")
            continue
        kind = step.get("action")
        if kind not in counts:
            errors.append(f"steps[{index}] has unknown action")
            continue
        counts[kind] += 1
        for metric_suffix in ("synchronous_ms", "to_idle_ms"):
            timing = step.get(metric_suffix)
            if (not isinstance(timing, (int, float)) or isinstance(timing, bool)
                    or not math.isfinite(timing) or timing < 0):
                errors.append(f"steps[{index}] {metric_suffix} must be finite and nonnegative")
            else:
                step_timings[kind][metric_suffix].append(timing)
        step_full_parses = step.get("full_parses")
        if not isinstance(step_full_parses, int) or isinstance(step_full_parses, bool):
            errors.append(f"steps[{index}] full_parses must be an integer")
        elif step_full_parses < 0:
            errors.append(f"steps[{index}] full_parses must be nonnegative")
        elif shape == "standard" and step_full_parses != 0:
            errors.append(f"steps[{index}] full_parses must be zero")
        step_incremental_parses = step.get("incremental_parses")
        if (not isinstance(step_incremental_parses, int)
                or isinstance(step_incremental_parses, bool)):
            errors.append(f"steps[{index}] incremental_parses must be an integer")
        elif step_incremental_parses < 0:
            errors.append(f"steps[{index}] incremental_parses must be nonnegative")
        elif shape == "standard" and step_incremental_parses != 1:
            errors.append(f"steps[{index}] incremental_parses must be one")
        if (
            shape != "standard"
            and isinstance(step_full_parses, int)
            and not isinstance(step_full_parses, bool)
            and step_full_parses >= 0
            and isinstance(step_incremental_parses, int)
            and not isinstance(step_incremental_parses, bool)
            and step_incremental_parses >= 0
            and step_full_parses + step_incremental_parses != 1
        ):
            errors.append(
                f"steps[{index}] must record exactly one full or incremental parse"
            )
        length = step.get("formatted_utf16_length")
        if shape == "long-line":
            limit = 256
        elif shape == "nearby-table":
            limit = source_utf16_length + 128 if isinstance(
                source_utf16_length, int
            ) and not isinstance(source_utf16_length, bool) else 0
        else:
            limit = 512 if kind == "bulk_insert" else 256
        if (not isinstance(length, int) or isinstance(length, bool)
                or length < 0 or length > limit):
            errors.append(f"steps[{index}] formatted_utf16_length must be 0..{limit}")
        if step.get("presentation_current_at_idle") is not True:
            errors.append(f"steps[{index}] presentation must be current at idle")
    for kind, expected in COUNTS.items():
        if counts[kind] != expected:
            errors.append(f"steps need exactly {expected} {kind} records")
        for suffix in ("synchronous_ms", "to_idle_ms"):
            metric_name = f"{kind}_{suffix}"
            metric_samples = measurements.get(metric_name)
            if (isinstance(metric_samples, list)
                    and step_timings[kind][suffix] != metric_samples):
                errors.append(f"{metric_name} does not match step timings in order")
    numeric_steps = [step for step in steps if isinstance(step, dict)]
    full_parse_sum = sum(
        step["full_parses"] for step in numeric_steps
        if isinstance(step.get("full_parses"), int)
        and not isinstance(step.get("full_parses"), bool)
    )
    incremental_parse_sum = sum(
        step["incremental_parses"] for step in numeric_steps
        if isinstance(step.get("incremental_parses"), int)
        and not isinstance(step.get("incremental_parses"), bool)
    )
    if (isinstance(report.get("full_parses_during_edits"), int)
            and not isinstance(report.get("full_parses_during_edits"), bool)
            and full_parse_sum != report["full_parses_during_edits"]):
        errors.append("step full_parses sum does not match report aggregate")
    aggregate_incremental = report.get("incremental_parses_during_edits")
    if (not isinstance(aggregate_incremental, int)
            or isinstance(aggregate_incremental, bool)):
        errors.append("incremental_parses_during_edits must be an integer")
    elif incremental_parse_sum != aggregate_incremental:
        errors.append("step incremental_parses sum does not match report aggregate")
    if errors:
        return errors
    for label, compared, limit in (("baseline", baseline, .8),
                                   ("reference", reference, 1.2)):
        if compared is None:
            continue
        comparison_errors = check_report(
            compared, size_kb, mode, context, host, shape,
            enforce_budgets=False,
        )
        if comparison_errors:
            errors += [label + ": " + error for error in comparison_errors]
            continue
        for source, value in (("current", report), (label, compared)):
            digest = value.get("fixture_sha256")
            if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
                errors.append(f"{source}: fixture_sha256 must be a SHA-256 digest")
        for field in ("utf8_bytes", "utf16_length", "fixture_sha256"):
            if report.get(field) != compared.get(field):
                errors.append(f"{label}: fixture {field} does not match")
        for metric in ("typing_synchronous_ms", "typing_to_idle_ms"):
            current = measurements[metric]
            previous = compared["measurements"][metric]
            for name, summarize in (("median", statistics.median),
                                    ("p95", percentile95)):
                before = summarize(previous)
                after = summarize(current)
                if before <= 0:
                    errors.append(f"{label}: {metric} {name} must be positive")
                elif after > limit * before:
                    requirement = ("must improve by at least 20%" if label == "baseline"
                                   else "must stay within 20% of the fixed reference")
                    errors.append(
                        f"{metric} {name} {requirement}: "
                        f"{after:.1f} ms vs {label} {before:.1f} ms"
                    )
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    parser.add_argument("--size-kb", required=True, type=int)
    parser.add_argument("--baseline-report", type=Path)
    parser.add_argument("--reference-report", type=Path)
    parser.add_argument("--mode", default="livePreview")
    parser.add_argument("--context", choices=("standard", "mixed"))
    parser.add_argument("--host", choices=("editor", "notebook"), default="editor")
    parser.add_argument("--shape", choices=tuple(SHAPE_SUFFIX_BYTES), default="standard")
    args = parser.parse_args()
    try:
        report = json.loads(args.report.read_text(encoding="utf-8"))
        baseline = (json.loads(args.baseline_report.read_text(encoding="utf-8"))
                    if args.baseline_report else None)
        reference = (json.loads(args.reference_report.read_text(encoding="utf-8"))
                     if args.reference_report else None)
    except (OSError, json.JSONDecodeError) as error:
        print(f"Cannot read performance report: {error}", file=sys.stderr)
        return 2
    errors = check_report(
        report, args.size_kb, args.mode, args.context, args.host, args.shape, baseline, reference=reference
    )
    if errors:
        for error in errors:
            print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print(f"PASS: {args.size_kb} KB {args.shape} report satisfies guard")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
