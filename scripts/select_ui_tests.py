#!/usr/bin/env python3
"""Skip the UI lanes a PR cannot affect; anything else runs the whole plan.

Each lane decides on its own. A changed file resolves in this order:

1. The UI harness itself runs the whole plan.
2. Docs, unit tests, tools, other scripts and workflows, and the widget
   extension need no UI goal, nor does a project file change that only
   bumps the version.
3. A Swift file needs no goal when the code this lane compiles from it
   stays the same: only comments or blank lines changed, or only code inside
   an `#if` for another platform, such as a Mac-only file on iPhone.
4. A UI test file runs its own class's goals, as it declares nothing else.
5. Anything else, including new, deleted and renamed files, runs the
   whole plan.

Locally, print `xcodebuild` test arguments for the branch and its
uncommitted changes against `origin/main`. If it prints nothing, no UI goal
is affected; skip the run, since `xcodebuild test` alone would run the
scheme's default plan:

    xcodebuild test -scheme 'meh.md CI' -configuration Debug-iCloud \\
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
PLANS = {"iphone": "CIIPhone", "ipad": "CIIPad", "mac": "CIMac"}
PROJECT = "meh.md.xcodeproj/project.pbxproj"
FULL = None

HARNESS = [
    "scripts/run_ui_foundation.py",
    "scripts/check_ui_foundation_results.py",
    "scripts/select_ui_tests.py",
    "scripts/fixtures/ui_enumeration_xcode27.json",
    ".github/workflows/ui-regressions.yml",
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
VERSION_LINE = re.compile(r"\s*(MARKETING_VERSION|CURRENT_PROJECT_VERSION) = [\w.]+;")
DIRECTIVE = re.compile(r"\s*#(if|elseif|else|endif)\b(.*)")
# Compile conditions whose value each lane knows.
CONDITIONS = {
    "os(iOS)": {"iphone": True, "ipad": True, "mac": False},
    "os(macOS)": {"iphone": False, "ipad": False, "mac": True},
    "canImport(UIKit)": {"iphone": True, "ipad": True, "mac": False},
    "canImport(AppKit)": {"iphone": False, "ipad": False, "mac": True},
}
# Fixed prefixes and quoting, whatever the user's git config says.
DIFF = ["-c", "core.quotePath=false", "diff", "--no-ext-diff", "--no-color",
        "--src-prefix=a/", "--dst-prefix=b/"]


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


def evaluate(condition, platform):
    """True or False when the lane decides a condition, else None."""
    expression = condition.strip()
    for atom in re.findall(r"\w+\([^()]*\)", expression):
        if atom not in CONDITIONS:
            return None
        expression = expression.replace(atom, str(CONDITIONS[atom][platform]))
    expression = expression.replace("&&", " and ").replace("||", " or ")
    expression = re.sub(r"!(?!=)", " not ", expression)
    if not re.fullmatch(r"[\s()]*((True|False|and|or|not)[\s()]*)+", expression):
        return None
    return bool(eval(expression, {"__builtins__": {}}))


def compiled(text, platform):
    """The lines of Swift source that a lane compiles, without comments.

    Branches of an `#if` the lane decides are resolved. A block with a
    condition it cannot decide stays as written, so any change to it counts.
    Lines inside multi-line string literals are always kept, since blank
    lines and `//` are text there.
    """

    def skipped(frames):
        # A branch is out when it is false or an earlier one is surely in.
        return any(frame[-1] is False or True in frame[:-1] for frame in frames)

    lines, stack, in_comment, in_string = [], [], False, False
    for line in (text or "").splitlines():
        stripped = line.strip()
        directive = None if in_string else DIRECTIVE.match(line)
        if in_string:
            in_string = line.count('"""') % 2 == 0
        elif in_comment:
            in_comment = "*/" not in stripped
            continue
        elif stripped.startswith("/*"):
            in_comment = "*/" not in stripped[2:]
            continue
        elif not stripped or stripped.startswith("//"):
            continue
        elif directive:
            kind, condition = directive[1], directive[2]
            if kind == "if":
                stack.append([evaluate(condition, platform)])
            elif not stack:
                lines.append(line)
                continue
            elif kind == "elseif":
                stack[-1].append(evaluate(condition, platform))
            elif kind == "else":
                earlier = stack[-1]
                stack[-1].append(
                    False if True in earlier
                    else True if all(value is False for value in earlier)
                    else None
                )
            block = stack.pop() if kind == "endif" else stack[-1]
            outer = stack if kind == "endif" else stack[:-1]
            if None in block and not skipped(outer):
                lines.append(line)
            continue
        else:
            in_string = line.count('"""') % 2 == 1
        if not skipped(stack):
            lines.append(line)
    return lines


def classify(path, platform, project_diff="", old=None, new=None):
    """Return (FULL or a set of plan selectors, reason) for one changed path."""
    if matches(path, HARNESS):
        return FULL, "changes the UI test harness"
    if path == PROJECT and version_only(project_diff):
        return set(), "only bumps the version"
    if matches(path, NO_UI_IMPACT):
        return set(), "has no UI impact"
    if path.endswith(".swift") and path != "Package.swift":
        if compiled(old, platform) == compiled(new, platform):
            return set(), f"changes nothing {platform} compiles"
        if match := UI_TESTS.fullmatch(path):
            return {match[1]}, "is a UI test file"
    return FULL, "can affect any UI goal"


def select(changes, platform, project_diff="", texts=None):
    """Return (plan entries to run or FULL, reasons) for one platform.

    `texts` maps each changed Swift path to its (old, new) source; a side
    is None when the file does not exist there.
    """
    texts = texts or {}
    cases = plan_cases(platform)
    chosen, reasons, full = set(), [], False
    for path in sorted(changes):
        old, new = texts.get(path, (None, None))
        selectors, reason = classify(path, platform, project_diff, old, new)
        reasons.append(f"{path}: {reason}")
        if selectors is FULL:
            full = True
        else:
            chosen |= expand(selectors, cases)
    return (FULL if full else chosen), reasons


def git(*arguments):
    return subprocess.run(
        ["git", *arguments], cwd=ROOT, check=True, capture_output=True, text=True,
    ).stdout


def changes_since(base, working_tree):
    """Changed paths since the merge base, their Swift sources and the project diff.

    A rename counts as a deletion and an addition, so both paths are checked.
    """
    merge_base = git("merge-base", base, "HEAD").strip()
    # CI checks out a clean merge commit; locally, include uncommitted work.
    target = [merge_base] if working_tree else [merge_base, "HEAD"]
    paths = set(git(*DIFF, "--no-renames", "--name-only", "-z", *target).split("\0"))
    if working_tree:
        paths.update(git("ls-files", "-z", "--others", "--exclude-standard").split("\0"))
    paths.discard("")

    def show(revision, path):
        result = subprocess.run(
            ["git", "show", f"{revision}:{path}"], cwd=ROOT, capture_output=True, text=True,
        )
        return result.stdout if result.returncode == 0 else None

    texts = {}
    for path in paths:
        if not path.endswith(".swift"):
            continue
        if working_tree:
            file = ROOT / path
            new = file.read_text(errors="replace") if file.exists() else None
        else:
            new = show("HEAD", path)
        texts[path] = (show(merge_base, path), new)
    return paths, texts, git(*DIFF, *target, "--", PROJECT)


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
        changes, texts, project_diff = changes_since(args.base, not args.github_output)
    platforms = sorted(PLANS) if args.github_output else [args.platform]
    matrix, outcomes, details = [], [], []
    for platform in platforms:
        if args.all:
            cases, reasons = FULL, ["--all: selects every goal"]
        else:
            cases, reasons = select(changes, platform, project_diff, texts)
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
                    output.write(
                        "".join(f"- `{r.replace(': ', '`: ', 1)}\n" for r in reasons)
                    )
                    output.write("\n</details>\n\n")


if __name__ == "__main__":
    main()
