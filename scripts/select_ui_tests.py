#!/usr/bin/env python3
"""Pick the UI goals a PR can affect, on each lane on its own.

Each night `run_ui_foundation.py --coverage` runs every goal of a lane's CI
plan alone and records which source lines it ran (ui-coverage.yml). A PR
then needs only the goals that ran a line it changes. The index comes from
`main`, so the diff starts at the index's commit: changes merged since then
count too, which can only add goals. Without an index for a lane, the diff
starts at the merge base and only the first rules below apply.

A changed file resolves in this order:

1. The UI harness itself runs the whole plan.
2. Docs, unit tests, tools, other scripts and workflows, and the widget
   extension need no UI goal, nor does a project file change that only
   bumps the version.
3. Other files that are not Swift source run the whole plan: assets,
   strings, plists, the project and the package manifest.
4. A Swift file needs no goal when the code this lane compiles from it
   stays the same: only comments or blank lines changed, or only code inside
   an `#if` for another platform, such as a Mac-only file on iPhone.
5. With an index, each changed line selects the goals that ran it, and new
   code the goals that ran the lines around it. New code that may run
   without a changed caller runs the whole plan: initializers, attributes
   such as `@objc`, conformances, enum cases, a new func or type that no
   changed line uses, or code that no line data covers, such as a
   `static let` table. A new file only runs through the changed lines that
   use it.
6. Otherwise a UI test file runs its own class's goals, as it declares
   nothing else, and anything else runs the whole plan.

Goals the index has no data for, such as new ones, always run.

Locally, print `xcodebuild` test arguments for the working tree, using the
latest index from `main` (needs `gh`). If it prints nothing, no UI goal is
affected; skip the run, since `xcodebuild test` alone would run the
scheme's default plan:

    xcodebuild test -scheme 'meh.md CI' -configuration Debug-iCloud \\
      -destination ... $(scripts/select_ui_tests.py iphone)

CI uses `--github-output` to write one matrix entry per platform that has
something to run.
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
    DIFF,
    FULL,
    ROOT,
    Index,
    changes_since,
    compiled,
    covered,
    declaration,
    download_indexes,
    evaluate,
    git,
    matches,
    parse_diff,
    read_index,
    version_only,
)

PLANS = {"iphone": "CIIPhone", "ipad": "CIIPad", "mac": "CIMac"}
PROJECT = "meh.md.xcodeproj/project.pbxproj"
# ui-coverage.yml uploads each lane's index under this name.
INDEX_ARTIFACT = "ui-coverage-{platform}"

HARNESS = [
    "scripts/run_ui_foundation.py",
    "scripts/check_ui_foundation_results.py",
    "scripts/select_ui_tests.py",
    "scripts/coverage_selection.py",
    "scripts/fixtures/ui_enumeration_xcode27.json",
    ".github/workflows/ui-regressions.yml",
    ".github/workflows/ui-coverage.yml",
    "TestPlans/CI*.xctestplan",
]
NO_UI_IMPACT = [
    "*.md",
    "LICENSE",
    ".coderabbit.yaml",
    ".gitattributes",
    ".gitignore",
    "docs/**",
    "Tests/**",
    "Tools/**",
    "scripts/**",
    ".github/**",
    "TestPlans/Nightly.xctestplan",
    # Only the widget extension builds these, and no UI goal starts it.
    "meh.mdWidgets/**",
]
UI_TESTS = re.compile(r"meh\.mdUITests/(\w+UITests)\.swift")


def plan_cases(platform):
    plan = json.loads((ROOT / "TestPlans" / (PLANS[platform] + ".xctestplan")).read_text())
    return set(plan["testTargets"][0]["selectedTests"])


def in_entry(case, entry):
    return case == entry or case.startswith(entry + "/")


def expand(selectors, entries):
    """The plan entries a set of classes or cases selects.

    A class selects its cases in the plan, and a case stays as it is when
    the plan lists its whole class, as CIMac does for MacFormattingUITests.
    """
    return {
        entry for entry in entries for selector in selectors if in_entry(entry, selector)
    } | {
        selector for selector in selectors
        if any(in_entry(selector, entry) for entry in entries)
    }


def classify(path, change, platform, index=None, used=Counter()):
    """Return (FULL or a set of plan selectors, reason) for one changed path."""
    if matches(path, HARNESS):
        return FULL, "changes the UI test harness"
    if path == PROJECT and version_only(change.get("diff", "")):
        return set(), "only bumps the version"
    if matches(path, NO_UI_IMPACT):
        return set(), "has no UI impact"
    if not path.endswith(".swift") or path == "Package.swift":
        return FULL, "can affect any UI goal"
    old, new = change.get("old"), change.get("new")
    if compiled(old, platform) == compiled(new, platform):
        return set(), f"changes nothing {platform} compiles"
    if index is not None:
        goals, reason = covered(path, change, index, platform, used)
        if goals is not FULL:
            return goals, reason
    else:
        reason = "can affect any UI goal"
    if match := UI_TESTS.fullmatch(path):
        return {match[1]}, f"is a UI test file ({reason})"
    return FULL, reason


def select(changes, platform, index=None):
    """Return (plan entries to run or FULL, reasons) for one platform.

    `changes` maps each changed path to {"old", "new"} sources (None where
    the file is missing), "hunks" from a -U0 diff and, for the project, the
    full "diff".
    """
    entries = plan_cases(platform)
    # A new file's lines count too: its diff adds them all.
    used = Counter(
        word
        for path, change in changes.items() if path.endswith(".swift")
        for *_, added in change.get("hunks", []) for line in added
        for word in re.findall(r"\w+", line)
    )
    chosen, reasons, full = set(), [], False
    for path in sorted(changes):
        selectors, reason = classify(path, changes[path], platform, index, used)
        reasons.append(f"{path}: {reason}")
        if selectors is FULL:
            full = True
        else:
            chosen |= expand(selectors, entries)
    if full:
        return FULL, reasons
    if index is not None:
        unknown = {
            entry for entry in entries
            if not any(in_entry(test, entry) for test in index.tests)
        }
        for entry in sorted(unknown):
            reasons.append(f"{entry}: has no coverage data yet")
        chosen |= unknown
    return chosen, reasons


def load_index(directory, platform):
    """(Index or None, reason) for one lane."""
    path = Path(directory) / f"coverage-{platform}.json" if directory else None
    index, problem = read_index(path, platform)
    if index is None:
        if problem == "no coverage index":
            problem += f" for {platform}"
        return None, f"{problem}; using the merge base"
    return index, f"coverage from {index.commit[:12]}"


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("platform", nargs="?", choices=sorted(PLANS))
    parser.add_argument(
        "--base", default="origin/main",
        help="Without an index, compare against the merge base with this ref",
    )
    parser.add_argument(
        "--index", type=Path,
        help="Directory with coverage-<platform>.json (default: download from main)",
    )
    parser.add_argument(
        "--github-output", action="store_true",
        help="Write the CI matrix for every platform to $GITHUB_OUTPUT",
    )
    parser.add_argument(
        "--all", action="store_true",
        help="Select the whole plan, as for a manual run without a diff",
    )
    args = parser.parse_args()
    if not args.github_output and not args.platform:
        parser.error("platform is required without --github-output")

    platforms = sorted(PLANS) if args.github_output else [args.platform]
    working_tree = not args.github_output
    matrix, outcomes, details, cache = [], [], [], {}
    with tempfile.TemporaryDirectory(prefix="meh-ui-coverage-") as temporary:
        directory = args.index
        if not args.all and directory is None:
            try:
                download_indexes(
                    temporary, [INDEX_ARTIFACT.format(platform=p) for p in PLANS],
                )
                directory = Path(temporary)
            except (
                OSError, subprocess.CalledProcessError, zipfile.BadZipFile,
                ValueError, KeyError,
            ) as error:
                print(f"Could not download coverage indexes: {error}", file=sys.stderr)
        for platform in platforms:
            if args.all:
                cases, reasons = FULL, ["--all: selects every goal"]
            else:
                index, source = load_index(directory, platform)
                commit = index.commit if index else git(
                    "merge-base", args.base, "HEAD",
                ).stdout.strip()
                if commit not in cache:
                    cache[commit] = changes_since(commit, working_tree, [PROJECT])
                cases, reasons = select(cache[commit], platform, index)
                reasons.insert(0, source)
            print(f"{platform}:", file=sys.stderr)
            for reason in reasons:
                print(f"  {reason}", file=sys.stderr)
            if cases is FULL:
                outcome = f"whole {PLANS[platform]} plan"
                matrix.append({"platform": platform, "selection": "full"})
            elif cases:
                outcome = f"{len(cases)} UI goals: " + ", ".join(sorted(cases))
                matrix.append({"platform": platform, "selection": " ".join(sorted(cases))})
            else:
                outcome = "no UI goals"
            print(f"  -> {outcome}", file=sys.stderr)
            outcomes.append(f"- **{platform}**: {outcome}")
            details.append((platform, reasons))
            if not args.github_output and cases != set():
                print(f"-testPlan {PLANS[platform]}")
                for case in sorted(cases or []):
                    print(f"-only-testing:meh.mdUITests/{case}")
    if args.github_output:
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            output.write(f"matrix={json.dumps(matrix)}\n")
        if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
            with open(summary, "a") as output:
                output.write("## UI goals\n\n" + "\n".join(outcomes) + "\n\n")
                for platform, reasons in details:
                    output.write(f"<details><summary>{platform}</summary>\n\n")
                    output.write("".join(f"- {reason}\n" for reason in reasons))
                    output.write("\n</details>\n\n")


if __name__ == "__main__":
    main()
