#!/usr/bin/env python3
"""Pick the PR UI goals a change can affect; nightly still runs everything.

Each changed file resolves in this order, using TestPlans/ui-test-impact.json:

1. `fullRun` paths (the UI harness itself) run the whole CI plan.
2. `noUIImpact` paths (docs, unit tests, other scripts) need no UI test.
   A project file change that only bumps the version counts as one.
3. A UI test file runs its own class's CI goals.
4. `areas` paths run their tests plus the `smoke` tests, on the area's
   `platforms` (default: all).
5. Anything else, including any new, renamed or copied file outside the
   first two groups, runs the whole CI plan.

Locally, print `xcodebuild` test arguments for the current branch and its
uncommitted changes. If it prints nothing, no UI goal is affected; skip the
run, since `xcodebuild test` alone would run the scheme's default plan:

    xcodebuild test -scheme 'meh.md CI' -configuration Debug-iCloud \
      -destination ... $(scripts/select_ui_tests.py iphone)

CI uses `--github-output` to write one matrix entry per platform that has
something to run.
"""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
IMPACT = ROOT / "TestPlans" / "ui-test-impact.json"
PLANS = {"iphone": "CIIPhone", "ipad": "CIIPad", "mac": "CIMac"}
PROJECT = "meh.md.xcodeproj/project.pbxproj"
UI_TESTS = re.compile(r"meh\.mdUITests/(\w+UITests)\.swift")
VERSION_LINE = re.compile(r"\s*(MARKETING_VERSION|CURRENT_PROJECT_VERSION) = [\w.]+;")
FULL = None


def matches(path, patterns):
    """Globs where `**` spans directories and `*` stays in one."""
    for pattern in patterns:
        regex = re.escape(pattern).replace(r"\*\*", ".*").replace(r"\*", "[^/]*")
        if re.fullmatch(regex, path):
            return True
    return False


def plan_cases(platform):
    plan = json.loads((ROOT / "TestPlans" / (PLANS[platform] + ".xctestplan")).read_text())
    return set(plan["testTargets"][0]["selectedTests"])


def expand(selectors, cases):
    return {
        case for case in cases for selector in selectors
        if case == selector or case.startswith(selector + "/")
    }


def version_only(diff):
    """True when every change replaces a version setting's value in place.

    That is what scripts/bump_version.sh produces: each removed setting
    line is followed by an added line for the same setting.
    """
    removed, added, pairs = [], [], 0
    for line in diff.splitlines() + ["@@"]:
        if line.startswith(("+++", "---")):
            continue
        if line[:1] in "-+":
            match = VERSION_LINE.fullmatch(line[1:])
            if not match or (line[0] == "-" and added):
                return False
            (removed if line[0] == "-" else added).append(match[1])
            continue
        if removed != added:
            return False
        pairs += len(removed)
        removed, added = [], []
    return pairs > 0


def classify(path, impact, project_diff="", new=frozenset()):
    """Return (FULL or [(selectors, platforms or None)], reason) for a path."""
    if matches(path, impact["fullRun"]):
        return FULL, "changes the UI test harness"
    if path == PROJECT and version_only(project_diff):
        return [], "only bumps the version"
    if matches(path, impact["noUIImpact"]):
        return [], "has no UI impact"
    if path in new:
        # A new file can carry code for any feature, whatever its name says.
        return FULL, "is new or renamed"
    if match := UI_TESTS.fullmatch(path):
        return [([match[1]], None)], "is a UI test file"
    areas = [area for area in impact["areas"] if matches(path, area["paths"])]
    if areas:
        return [
            (area["tests"] + impact["smoke"], area.get("platforms")) for area in areas
        ], "area " + ", ".join(area["name"] for area in areas)
    return FULL, "is not mapped to an area"


def select(changes, platform, impact=None, project_diff="", new=frozenset()):
    """Return (plan entries to run or FULL, reasons) for one platform."""
    impact = impact or json.loads(IMPACT.read_text())
    cases = plan_cases(platform)
    chosen, reasons, full = set(), [], False
    for path in sorted(changes):
        groups, reason = classify(path, impact, project_diff, new)
        reasons.append(f"{path}: {reason}")
        if groups is FULL:
            full = True
            continue
        for selectors, platforms in groups:
            if platforms is None or platform in platforms:
                chosen |= expand(selectors, cases)
    return (FULL if full else chosen), reasons


def git(*arguments):
    return subprocess.run(
        ["git", *arguments], cwd=ROOT, check=True, capture_output=True, text=True,
    ).stdout


def changes_since(base, working_tree):
    """Changed paths since the merge base, and those that are new there.

    Both sides of a rename or copy count as new.
    """
    merge_base = git("merge-base", base, "HEAD").strip()
    # CI checks out a clean merge commit; locally, include uncommitted work.
    target = [merge_base] if working_tree else [merge_base, "HEAD"]
    # -z keeps unusual paths unquoted: status, then one or two paths.
    fields = git("diff", "--name-status", "-z", "-M", *target).split("\0")
    paths, new, index = set(), set(), 0
    while index < len(fields) and fields[index]:
        status = fields[index][0]
        count = 2 if status in "RC" else 1
        names = fields[index + 1:index + 1 + count]
        paths.update(names)
        if status in "ARC":
            new.update(names)
        index += 1 + count
    if working_tree:
        untracked = git("ls-files", "--others", "--exclude-standard").splitlines()
        paths.update(untracked)
        new.update(untracked)
    return paths, new, git("diff", *target, "--", PROJECT)


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("platform", nargs="?", choices=sorted(PLANS))
    parser.add_argument(
        "--base", default="origin/main",
        help="Compare against the merge base with this ref (default origin/main)",
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

    if not args.all:
        changes, new, project_diff = changes_since(args.base, not args.github_output)
    platforms = sorted(PLANS) if args.github_output else [args.platform]
    matrix, outcomes = [], []
    for platform in platforms:
        if args.all:
            cases, reasons = FULL, ["--all: selects every goal"]
        else:
            cases, reasons = select(
                changes, platform, project_diff=project_diff, new=new,
            )
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
                output.write("".join(f"- `{r.replace(': ', '`: ', 1)}\n" for r in reasons))


if __name__ == "__main__":
    main()
