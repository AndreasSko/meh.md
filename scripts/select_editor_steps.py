#!/usr/bin/env python3
"""Pick the editor performance steps a PR can affect.

A benchmark can only get slower through code it runs. Each night
`run_editor_coverage.py` runs every expensive step of
editor-performance.yml once with code coverage and records which source
lines it ran (editor-coverage.yml). A PR then runs only the steps that ran
a line it changes. Each step is a whole unit: the native suite is checked
against an inventory of all its tests, so it cannot run in part.

A changed file resolves in this order:

1. The selection itself, the workflows, the package manifest and the
   resolved dependencies run every step.
2. A step's own scripts, checks and fixtures run that step.
3. Docs, other scripts and workflows, test plans, the Xcode project, UI
   tests, the widget extension and other tools need no step: steps build
   with SwiftPM or `swiftc`, never from the Xcode project. Neither do the
   non-Swift files of the app folder, since steps only compile its Swift.
4. Any other file that is not Swift runs every step.
5. A Swift file needs no step that compiles the same code from it as
   before: only comments or blank lines changed, or only code inside an
   `#if` for another platform.
6. With an index, the select_ui_tests.py rules for changed and new lines
   decide, per step (see coverage_selection.py). A test file needs no
   SwiftPM step that never ran it, unless it adds tests to a class the
   step filters for.
7. Without a usable index for a step, a Swift change runs it.

Locally, print the steps for the working tree against the latest index
from `main` (needs `gh`), with the reason for each file on stderr:

    scripts/select_editor_steps.py

CI uses `--github-output` to write which steps to run.
"""

import argparse
from collections import Counter
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import zipfile

from coverage_selection import (
    FULL,
    changes_since,
    compiled,
    covered,
    download_indexes,
    git,
    matches,
    read_index,
)

# editor-coverage.yml uploads every step's index in this one artifact.
INDEX_ARTIFACT = "editor-coverage"
# Raise when the index format or how it is recorded changes; older indexes
# are then ignored and their steps run.
INDEX_VERSION = 1

# Each step of editor-performance.yml that the selection can skip.
#
# `platform` is what the step compiles for, as coverage_selection.CONDITIONS
# names it. `anchor` must have run lines in a step's index, or the index is
# taken as broken and the step runs. `filter` is the `swift test --filter`
# of a SwiftPM step, which run_editor_coverage.py reuses. `paths` are the
# step's own files that are not app code.
STEPS = {
    "formatting": {
        "platform": "mac",
        # NativeEditorIntegrationTests holds tests that only build on the
        # Mac; the native suite runs the rest on an iPhone simulator.
        "filter": "EditorMacFormattingScrollTests|EditorRenderingTests|NativeEditorIntegrationTests",
        "anchor": "Tests/NativeEditorTests/EditorMacFormattingScrollTests.swift",
        "paths": [],
    },
    "native": {
        "platform": "iphone",
        "anchor": "meh.md/MarkdownEditor.swift",
        "paths": [
            "scripts/run_native_editor_baseline_parity.sh",
            "scripts/check_native_editor_baseline_parity.py",
            "scripts/fixtures/native-editor-inventory.json",
        ],
    },
    "history": {
        "platform": "mac",
        "filter": "NoteHistory(Tests|ReaderTests|PerformanceTests)",
        "anchor": "Tests/NoteCoreTests/NoteHistoryPerformanceTests.swift",
        "paths": [],
    },
    "catalog": {
        "platform": "mac",
        "filter": "NotebookCatalogPerformanceTests",
        "anchor": "Tests/NoteCoreTests/NotebookCatalogPerformanceTests.swift",
        "paths": [
            "scripts/check_catalog_performance.py",
            "scripts/fixtures/performance/catalog-*",
        ],
    },
    "parser": {
        "platform": "mac",
        "filter": "MarkdownFullParsePerformanceTests",
        "anchor": "Tests/NativeEditorTests/MarkdownFullParsePerformanceTests.swift",
        "paths": [
            "scripts/run_parser_performance_ci.sh",
            "scripts/check_parser_performance.py",
            "scripts/fixtures/performance/parser-*",
        ],
    },
    "probes": {
        "platform": "iphone",
        "anchor": "Tools/EditorQuoteCheck/LargeNotePerformanceProbe.swift",
        "paths": [
            "scripts/run_editor_performance_ci.sh",
            "scripts/run_editor_performance_check.sh",
            "scripts/check_editor_performance.py",
            "scripts/editor_performance_app_cache.py",
            "scripts/fixtures/performance/native-*",
            "Tools/EditorQuoteCheck/**",
        ],
    },
}
ALL_STEPS = [
    ".github/workflows/editor-performance.yml",
    ".github/workflows/editor-coverage.yml",
    "scripts/select_editor_steps.py",
    "scripts/coverage_selection.py",
    "scripts/run_editor_coverage.py",
    # The gates the performance job runs before any step.
    "scripts/test_*performance*.py",
    "scripts/test_*native_editor_baseline_parity.py",
    "Package.swift",
    "Package.resolved",
]
NO_IMPACT = [
    "*.md",
    "LICENSE",
    ".coderabbit.yaml",
    ".gitattributes",
    ".gitignore",
    "docs/**",
    "scripts/**",
    ".github/**",
    "TestPlans/**",
    "Tools/**",
    "icon.icon/**",
    "meh.md.xcodeproj/**",
    "meh.mdUITests/**",
    "meh.mdWidgets/**",
]
APP = "meh.md/"


def load_index(directory, step):
    """(Index or None, reason) for one step."""
    path = Path(directory) / f"coverage-{step}.json" if directory else None
    index, problem = read_index(path, STEPS[step]["platform"])
    if index is None:
        return None, problem
    data = json.loads(path.read_text())
    if data.get("version") != INDEX_VERSION:
        return None, f"{path.name} has format {data.get('version')}, not {INDEX_VERSION}"
    if index.tests != [step]:
        return None, f"{path.name} records {index.tests}, not {step}"
    anchor = STEPS[step]["anchor"]
    if anchor not in index.compiled or not index.files.get(anchor, {}).get("ran"):
        return None, f"{path.name} has no lines run in {anchor}; taking it as incomplete"
    return index, f"coverage from {index.commit[:12]}"


def new_test(text, step):
    """For a file in Tests/, why it can add tests to a SwiftPM step, or None.

    `swift test --filter` matches part of a test's name, and a file can add
    tests to a class through an extension.
    """
    for name in re.findall(r"\b(?:class|extension)\s+(?:\w+\.)?(\w+)", text):
        if re.search(STEPS[step]["filter"], name):
            return f"adds tests to `{name}`, which the step runs"
    return None


def target(path):
    """The folder of the target a file builds in: SwiftPM includes subfolders."""
    parts = path.split("/")
    return "/".join(parts[:2] if parts[0] in ("Sources", "Tests") else parts[:1]) + "/"


def decide(path, change, step, index, used):
    """(True or False, reason) for one Swift file and one step."""
    platform = STEPS[step]["platform"]
    old, new = change.get("old"), change.get("new")
    if compiled(old, platform) == compiled(new, platform):
        return False, f"changes nothing {platform} compiles"
    if index is None:
        return True, "is Swift; no usable coverage"
    built = path in index.compiled or (
        old is None and any(other.startswith(target(path)) for other in index.compiled)
    )
    if not built:
        return False, "is not built for this step"
    if path.startswith("Tests/") and "filter" in STEPS[step]:
        reason = new_test(new or "", step) or new_test(old or "", step)
        if old is None and reason:
            return True, f"is new and {reason}"
        if not reason and not index.files.get(path, {}).get("ran"):
            return False, "is a test file the step never ran, of classes it does not run"
    steps, reason = covered(path, change, index, platform, used)
    if steps is FULL:
        return True, reason
    if steps:
        return True, "the step ran its changed lines"
    if reason.endswith("goals ran its changed lines"):
        reason = "the step ran none of its changed lines"
    return False, reason


def select(changes, indexes):
    """Return ({step: True or False}, {step: [reasons]}).

    `changes` is as coverage_selection.changes_since returns it and
    `indexes` maps each step to its Index or None.
    """
    used = Counter(
        word
        for path, change in changes.items() if path.endswith(".swift")
        for *_, added in change.get("hunks", []) for line in added
        for word in re.findall(r"\w+", line)
    )
    chosen = {step: False for step in STEPS}
    reasons = {step: [] for step in STEPS}

    def note(step, run, reason):
        chosen[step] |= run
        reasons[step].append(reason)

    for path in sorted(changes):
        change = changes[path]
        if matches(path, ALL_STEPS):
            for step in STEPS:
                note(step, True, f"{path}: changes how every step runs")
            continue
        own = [step for step in STEPS if matches(path, STEPS[step]["paths"])]
        if own:
            for step in own:
                note(step, True, f"{path}: is part of this step")
            continue
        if matches(path, NO_IMPACT) or (
            path.startswith(APP) and not path.endswith(".swift")
        ):
            continue
        if not path.endswith(".swift"):
            for step in STEPS:
                note(step, True, f"{path}: is not Swift and may affect any step")
            continue
        for step in STEPS:
            run, reason = decide(path, change, step, indexes.get(step), used)
            note(step, run, f"{path}: {reason}")
    return chosen, reasons


def pick(indexes, merge_base, changes):
    """Like `select`, but each step diffs from its own index's commit.

    An index was taken at one commit, so its line numbers match that
    commit; changes merged since then count too. A step without an index
    diffs from the merge base. `changes(commit)` returns the changes since
    a commit.
    """
    chosen, reasons = {}, {}
    groups = {}
    for step, index in indexes.items():
        groups.setdefault(index.commit if index else merge_base, {})[step] = index
    for commit, group in groups.items():
        picked, why = select(changes(commit), group)
        for step in group:
            chosen[step] = picked[step]
            reasons[step] = [f"diff from {commit[:12]}"] + why[step]
    return chosen, reasons


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--base", default="origin/main",
        help="Without an index, compare against the merge base with this ref",
    )
    parser.add_argument(
        "--index", type=Path,
        help="Directory with coverage-<step>.json (default: download from main)",
    )
    parser.add_argument(
        "--github-output", action="store_true",
        help="Write the steps to run to $GITHUB_OUTPUT",
    )
    parser.add_argument(
        "--all", action="store_true",
        help="Run every step, as for a manual or nightly run",
    )
    args = parser.parse_args()
    working_tree = not args.github_output
    sources, cache = {}, {}
    if args.all:
        chosen = {step: True for step in STEPS}
        reasons = {step: ["--all: runs every step"] for step in STEPS}
    else:
        with tempfile.TemporaryDirectory(prefix="meh-editor-coverage-") as temporary:
            directory = args.index
            if directory is None:
                try:
                    download_indexes(temporary, [INDEX_ARTIFACT])
                    directory = Path(temporary)
                except (
                    OSError, subprocess.CalledProcessError, zipfile.BadZipFile,
                    ValueError, KeyError,
                ) as error:
                    print(f"Could not download the coverage index: {error}", file=sys.stderr)
            indexes = {}
            for step in STEPS:
                indexes[step], sources[step] = load_index(directory, step)
        merge_base = git("merge-base", args.base, "HEAD").stdout.strip()

        def changes(commit):
            if commit not in cache:
                cache[commit] = changes_since(commit, working_tree)
            return cache[commit]

        chosen, reasons = pick(indexes, merge_base, changes)
        for step in STEPS:
            reasons[step].insert(0, sources[step])
    outcomes = []
    for step in STEPS:
        outcome = "runs" if chosen[step] else "skipped"
        print(f"{step}: {outcome}", file=sys.stderr)
        for reason in reasons[step]:
            print(f"  {reason}", file=sys.stderr)
        outcomes.append((step, outcome, reasons[step]))
    if args.github_output:
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            output.write(f"steps={json.dumps(chosen)}\n")
            output.write(f"any={'true' if any(chosen.values()) else 'false'}\n")
        if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
            with open(summary, "a") as output:
                output.write("## Editor performance steps\n\n")
                for step, outcome, step_reasons in outcomes:
                    output.write(f"<details><summary>{step}: {outcome}</summary>\n\n")
                    output.write("".join(f"- {reason}\n" for reason in step_reasons))
                    output.write("\n</details>\n\n")
    else:
        print(" ".join(step for step in STEPS if chosen[step]))


if __name__ == "__main__":
    main()
