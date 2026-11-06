#!/usr/bin/env python3
"""Record which lines each editor performance step runs, for PR selection.

Runs every step that select_editor_steps.py can skip once, with code
coverage, and writes one `coverage-<step>.json` per step into the evidence
root. Each run keeps the step's real build configuration and workload, but
no time budget: coverage slows code down, so timings would mean nothing.
A step that fails writes no index, and PRs then always run it.

    scripts/run_editor_coverage.py --evidence-root DIR [STEP ...]
"""

import argparse
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys

from coverage_selection import ROOT, coverage_index, git
from select_editor_steps import INDEX_VERSION, STEPS

# The workload of each SwiftPM step, as editor-performance.yml runs it.
# History runs at two sizes there, which take different branches, so its
# coverage merges both runs.
SWIFT = {
    "formatting": {"configuration": "debug", "environment": {}},
    "history": {
        "configuration": "release",
        "environment": {"MEH_HISTORY_BENCHMARK_EDITS": "600"},
        "runs": [
            {"MEH_HISTORY_BENCHMARK_LINES": "1800"},
            {"MEH_HISTORY_BENCHMARK_LINES": "7460", "filter": "NoteHistoryPerformanceTests"},
        ],
    },
    "catalog": {
        "configuration": "release",
        "environment": {"MEH_CATALOG_BENCHMARK": "1"},
        "report": "MEH_CATALOG_BENCHMARK_REPORT",
    },
    "parser": {
        "configuration": "release",
        "environment": {
            "MEH_FULL_PARSE_BENCHMARK": "1",
            "MEH_FULL_PARSE_LABEL": "coverage",
        },
        "report": "MEH_FULL_PARSE_REPORT",
    },
}
# run_editor_performance_check.sh compiles copies of the app's Swift files
# from a temporary `sources` folder.
PROBE_COPY = re.compile(r"/meh-editor-performance\.[^/]+/sources/([^/]+\.swift)$")
# run_native_editor_baseline_parity.sh builds a package that links to the
# checkout from a temporary folder.
NATIVE_PACKAGE = "/current-package/"


def checkout_path(path):
    """The checkout-relative path a built file stands for, or None."""
    if match := PROBE_COPY.search(path):
        return "meh.md/" + match[1]
    if NATIVE_PACKAGE in path:
        return path.split(NATIVE_PACKAGE, 1)[1]
    prefix = str(ROOT) + "/"
    if path.startswith(prefix) and not path.startswith(prefix + ".build/"):
        return path[len(prefix):]
    return None


def lcov_lines(text):
    """({path: executable lines}, {path: lines that ran}) of an lcov export."""
    executable, ran, path = {}, {}, None
    for line in text.splitlines():
        if line.startswith("SF:"):
            path = line[3:]
            executable.setdefault(path, set())
            ran.setdefault(path, set())
        elif line.startswith("DA:") and path:
            number, count = line[3:].split(",")[:2]
            executable[path].add(int(number))
            if int(count):
                ran[path].add(int(number))
    return executable, ran


def profile_lines(profiles, binaries):
    """Line data of the raw profiles in a folder, for instrumented binaries."""
    raw = sorted(profiles.glob("*.profraw"))
    if not raw:
        raise RuntimeError(f"No coverage profile was written to {profiles}")
    merged = profiles / "merged.profdata"
    subprocess.run(
        ["xcrun", "llvm-profdata", "merge", "-sparse", *map(str, raw), "-o", str(merged)],
        check=True,
    )
    first, *others = map(str, binaries)
    return lcov_lines(subprocess.run(
        # Simulator builds are universal; the tests ran on this machine's slice.
        ["xcrun", "llvm-cov", "export", "-format=lcov", "-arch", platform.machine(),
         "-instr-profile", str(merged),
         first, *(argument for path in others for argument in ("-object", path))],
        check=True, capture_output=True, text=True,
    ).stdout)


def index_for(step, commit, executable, ran, compiled):
    """The index of one step, keyed by checkout paths."""

    def mapped(lines_by_path):
        result = {}
        for path, lines in lines_by_path.items():
            if relative := checkout_path(path):
                result.setdefault(str(ROOT / relative), set()).update(lines)
        return result

    files = {checkout_path(path) for path in compiled} - {None}
    index = coverage_index(
        STEPS[step]["platform"], commit, {step: mapped(ran)}, mapped(executable),
        [str(ROOT / path) for path in files],
    )
    index["version"] = INDEX_VERSION
    index["toolchain"] = subprocess.run(
        ["xcrun", "swift", "--version"], capture_output=True, text=True,
    ).stdout.strip()
    return index


def run(command, log, environment=None, **options):
    """Run a command, streaming its output into the job log and `log`."""
    print("+", " ".join(map(str, command)), flush=True)
    with open(log, "a") as output:
        process = subprocess.Popen(
            command, cwd=options.get("cwd", ROOT), stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True,
            env={**os.environ, **(environment or {})},
        )
        for line in process.stdout:
            sys.stdout.write(line)
            output.write(line)
        if process.wait():
            raise subprocess.CalledProcessError(process.returncode, command)


def swift_step(step, evidence):
    settings = SWIFT[step]
    configuration = settings["configuration"]
    environment = dict(settings["environment"])
    if report := settings.get("report"):
        environment[report] = str(evidence / f"{step}-report.json")
    products = Path(subprocess.run(
        ["swift", "build", "-c", configuration, "--show-bin-path"],
        cwd=ROOT, check=True, capture_output=True, text=True,
    ).stdout.strip())
    profiles = evidence / f"{step}-profiles"
    profiles.mkdir()
    for attempt, extra in enumerate(settings.get("runs", [{}])):
        extra = dict(extra)
        filter_ = extra.pop("filter", STEPS[step]["filter"])
        # Only this run's profiles may count, and the next run may clear them.
        shutil.rmtree(products / "codecov", ignore_errors=True)
        run(
            ["swift", "test", "-c", configuration, "--enable-code-coverage",
             "--filter", filter_],
            evidence / f"{step}.log", {**environment, **extra},
        )
        for number, raw in enumerate(sorted((products / "codecov").glob("*.profraw"))):
            raw.rename(profiles / f"{attempt}-{number}.profraw")
    bundles = sorted(products.glob("*.xctest"))
    executable, ran = profile_lines(
        profiles, [bundle / "Contents/MacOS" / bundle.stem for bundle in bundles],
    )
    intermediates = products.parent.parent / "Intermediates.noindex"
    compiled = set()
    for files in intermediates.glob(
        f"MehCore.build/{configuration.capitalize()}/*/Objects-normal/*/*.SwiftFileList"
    ):
        compiled.update(files.read_text().splitlines())
    return executable, ran, compiled


def native_step(evidence):
    work = evidence / "native"
    work.mkdir()
    run(
        [str(ROOT / "scripts/run_native_editor_baseline_parity.sh")],
        evidence / "native.log", {"RUNNER_TEMP": str(work), "EDITOR_COVERAGE": "1"},
    )
    (result,) = work.glob("native-editor-parity-evidence.*")
    executable, ran = profile_lines(result / "profiles", sorted((result / "binaries").iterdir()))
    compiled = (result / "compiled.txt").read_text().splitlines()
    return executable, ran, compiled


def probes_step(evidence):
    work = evidence / "probes"
    work.mkdir()
    run(
        [str(ROOT / "scripts/run_editor_performance_ci.sh")],
        evidence / "probes.log",
        {"RUNNER_TEMP": str(work), "EDITOR_PERFORMANCE_COVERAGE": str(work)},
    )
    executable, ran = profile_lines(work / "profiles", [work / "EditorQuoteCheck"])
    # The script lists what it compiled by checkout path.
    compiled = [str(ROOT / path) for path in (work / "compiled.txt").read_text().split()]
    return executable, ran, compiled


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("steps", nargs="*", help=f"Default: {' '.join(STEPS)}")
    parser.add_argument("--evidence-root", type=Path, required=True)
    args = parser.parse_args()
    if unknown := set(args.steps) - set(STEPS):
        parser.error(f"unknown steps: {', '.join(sorted(unknown))}")
    if git("status", "--porcelain").stdout.strip():
        sys.exit("Coverage needs a clean checkout: the index names one commit")
    commit = git("rev-parse", "HEAD").stdout.strip()
    evidence = args.evidence_root.resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    failed = []
    for step in args.steps or list(STEPS):
        print(f"::group::Coverage of {step}", flush=True)
        try:
            if step in SWIFT:
                lines = swift_step(step, evidence)
            elif step == "native":
                lines = native_step(evidence)
            else:
                lines = probes_step(evidence)
            executable, ran, compiled = lines
            index = index_for(step, commit, executable, ran, compiled)
            anchor = STEPS[step]["anchor"]
            if anchor not in index["compiled"]:
                raise RuntimeError(f"{anchor} is missing from the compiled files")
            if not index["files"].get(anchor, {}).get("ran"):
                raise RuntimeError(f"No line of {anchor} ran; the coverage is incomplete")
            (evidence / f"coverage-{step}.json").write_text(
                json.dumps(index, separators=(",", ":")) + "\n"
            )
            print(f"{step}: {len(index['files'])} files with line data", flush=True)
        except Exception as error:
            print(f"::error::Coverage of {step} failed: {error}", flush=True)
            failed.append(step)
        print("::endgroup::", flush=True)
    if failed:
        sys.exit(f"No index for {', '.join(failed)}; PRs will always run them")


if __name__ == "__main__":
    main()
