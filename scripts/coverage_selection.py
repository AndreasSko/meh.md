#!/usr/bin/env python3
"""Shared parts of picking CI work from a diff and nightly line coverage.

`select_ui_tests.py` picks UI goals and `select_editor_steps.py` picks
editor performance steps. Both read the same kind of index: which unit (a
UI goal or a step) ran which line, on one platform, at one commit. This
module holds what does not depend on the unit: reading the diff, telling
what a platform compiles from Swift source, mapping changed lines to the
units that ran them, and building and loading the index.
"""

from collections import Counter
import io
import json
import os
from pathlib import Path
import re
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parent.parent
FULL = None

VERSION_LINE = re.compile(r"\s*(MARKETING_VERSION|CURRENT_PROJECT_VERSION) = [\w.]+;")
DIRECTIVE = re.compile(r"\s*#(if|elseif|else|endif)\b(.*)")
HUNK = re.compile(r"@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")
# Compile conditions whose value each lane knows.
CONDITIONS = {
    "os(iOS)": {"iphone": True, "ipad": True, "mac": False},
    "os(macOS)": {"iphone": False, "ipad": False, "mac": True},
    "canImport(UIKit)": {"iphone": True, "ipad": True, "mac": False},
    "canImport(AppKit)": {"iphone": False, "ipad": False, "mac": True},
}
# Fixed prefixes and quoting, whatever the user's git config says.
DIFF = ["-c", "core.quotePath=false", "diff", "--no-ext-diff", "--no-color",
        "--no-renames", "--src-prefix=a/", "--dst-prefix=b/"]

MODIFIERS = re.compile(
    r"((private|fileprivate|internal|public|open|package)(\(set\))?|final|nonisolated"
    r"|mutating|nonmutating|convenience|required|lazy|weak|unowned|dynamic"
    r"|indirect|static|class(?=\s+(func|var|let)\b))\s+"
)
ATTRIBUTE = re.compile(r"@(\w+)(\([^()]*(\([^()]*\)[^()]*)*\))?\s*")
# Attributes that do not make the runtime call a declaration by itself.
# Any other, such as @objc or @main, counts as implicit.
PLAIN_ATTRIBUTES = {
    "MainActor", "State", "Binding", "Environment", "EnvironmentObject",
    "ObservedObject", "StateObject", "Published", "Observable", "ObservationIgnored",
    "Bindable", "ViewBuilder", "discardableResult", "inlinable", "usableFromInline",
    "available", "Sendable", "escaping", "autoclosure", "FocusState", "AppStorage",
    "SceneStorage", "Namespace", "preconcurrency", "unchecked", "nonobjc", "frozen",
    "Entry", "GestureState", "ScaledMetric", "FocusedValue",
}
# Declarations that can change behavior without any call site changing.
IMPLICIT = re.compile(
    r"(init|deinit|subscript|protocol|typealias|associatedtype|override|import"
    r"|operator|precedencegroup|macro)\b|#|extension\b[^{]*:"
)
NAMED = re.compile(r"(func|struct|class|enum|actor|var|let)\s+(`?)([A-Za-z_]\w*)\2")
ENUM_CASE = re.compile(r"case\s+(?!\.|let\b|var\b|_)[^:]*$")
EXTENSION = re.compile(r"(\w+\s+)*extension\s+[\w.]+(<[^>]*>)?\s*(:)?")
CLOSING = re.compile(r"[)\]}]+[,;]?")


def matches(path, patterns):
    """Globs where `**` spans directories and `*` stays in one."""
    for pattern in patterns:
        regex = re.escape(pattern).replace(r"\*\*", ".*").replace(r"\*", "[^/]*")
        if re.fullmatch(regex, path):
            return True
    return False


def version_only(diff):
    """True when every change replaces a version setting's value in place.

    That is what raising the version in the project produces: each removed
    setting line is followed by an added line for the same setting.
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


def scan(text, platform):
    """The kind of each line of Swift source, as the lane compiles it.

    `code` and `condition` (an `#if` line the lane cannot decide) are
    compiled as written. `comment` covers blank lines too, `directive` an
    `#if` line the lane decides, and `excluded` code in a branch it skips.
    Lines inside multi-line string literals are always code, since blank
    lines and `//` are text there.
    """

    def skipped(frames):
        # A branch is out when it is false or an earlier one is surely in.
        return any(frame[-1] is False or True in frame[:-1] for frame in frames)

    kinds, stack, in_comment, in_string = [], [], False, False
    for line in (text or "").splitlines():
        stripped = line.strip()
        directive = None if in_string else DIRECTIVE.match(line)
        if in_string:
            in_string = line.count('"""') % 2 == 0
            kind = "code"
        elif in_comment:
            in_comment = "*/" not in stripped
            kind = "comment"
        elif stripped.startswith("/*"):
            in_comment = "*/" not in stripped[2:]
            kind = "comment"
        elif not stripped or stripped.startswith("//"):
            kind = "comment"
        elif directive and not (stack or directive[1] == "if"):
            kind = "condition"
        elif directive:
            kind_name, condition = directive[1], directive[2]
            if kind_name == "if":
                stack.append([evaluate(condition, platform)])
            elif kind_name == "elseif":
                stack[-1].append(evaluate(condition, platform))
            elif kind_name == "else":
                earlier = stack[-1]
                stack[-1].append(
                    False if True in earlier
                    else True if all(value is False for value in earlier)
                    else None
                )
            block = stack.pop() if kind_name == "endif" else stack[-1]
            outer = stack if kind_name == "endif" else stack[:-1]
            kinds.append(
                "excluded" if skipped(outer)
                else "condition" if None in block else "directive"
            )
            continue
        else:
            in_string = line.count('"""') % 2 == 1
            kind = "code"
        if kind == "code" and skipped(stack):
            kind = "excluded"
        kinds.append(kind)
    return kinds


def compiled(text, platform):
    """The lines a lane compiles from Swift source, without comments."""
    return [
        line for line, kind in zip((text or "").splitlines(), scan(text, platform))
        if kind in ("code", "condition")
    ]


def declaration(line):
    """(kind, name) of a declaration, or (None, None) for other code.

    An `implicit` declaration can change behavior by itself. A `type`, or a
    `named` func or computed value, needs a caller. A `stored` value needs a
    use, which may be an existing line.
    """
    stripped = line.strip()
    while match := MODIFIERS.match(stripped) or ATTRIBUTE.match(stripped):
        if match.re is ATTRIBUTE and match[1] not in PLAIN_ATTRIBUTES:
            return "implicit", None
        stripped = stripped[match.end():]
    # Previews only build for Xcode's canvas.
    if not stripped or stripped.startswith("#Preview"):
        return None, None
    extension = EXTENSION.match(stripped)
    if extension:
        return ("implicit", None) if extension[3] else (None, None)
    if IMPLICIT.match(stripped) or ENUM_CASE.match(stripped):
        return "implicit", None
    match = NAMED.match(stripped)
    if not match:
        return None, None
    if match[1] in ("struct", "class", "enum", "actor"):
        return "type", match[3]
    stored = match[1] in ("var", "let") and "{" not in stripped
    return ("stored" if stored else "named"), match[3]


def balanced(lines, platform):
    """True when the `#if` lines among `lines` close and the lane decides each."""
    depth = 0
    for line in lines:
        directive = DIRECTIVE.match(line)
        if not directive:
            continue
        if directive[1] in ("if", "elseif") and evaluate(directive[2], platform) is None:
            return False
        depth += {"if": 1, "endif": -1}.get(directive[1], 0)
        if depth < 0 or (directive[1] in ("elseif", "else") and depth == 0):
            return False
    return depth == 0


def lines_of(ranges):
    return {line for start, end in ranges for line in range(start, end + 1)}


class Index:
    """One lane's coverage: which goal ran which line, at one commit."""

    def __init__(self, data):
        self.platform = data["platform"]
        self.commit = data["commit"]
        self.tests = data["tests"]
        self.compiled = set(data["compiled"])
        self.files = data["files"]
        self._lines = {}

    def lines(self, path):
        """(executable lines, {line: goals that ran it}) of a covered file."""
        if path not in self._lines:
            entry = self.files[path]
            ran = {}
            for test, ranges in entry["ran"].items():
                for line in lines_of(ranges):
                    ran.setdefault(line, set()).add(self.tests[int(test)])
            self._lines[path] = lines_of(entry["executable"]), ran
        return self._lines[path]


def parse_diff(diff):
    """{path: [(old_start, old_count, new_start, removed, added)]} of a -U0 diff."""
    files, hunks = {}, None
    for line in diff.splitlines():
        if line.startswith("diff --git "):
            hunks = files.setdefault(line.split(" b/", 1)[1], [])
        elif hunks is None:
            continue
        elif match := HUNK.match(line):
            hunks.append((int(match[1]), int(match[2] or 1), int(match[3]), [], []))
        # Before a file's first hunk, `---` and `+++` are its header.
        elif hunks and line[:1] == "-":
            hunks[-1][3].append(line[1:])
        elif hunks and line[:1] == "+":
            hunks[-1][4].append(line[1:])
    return files


def new_file(text, used):
    """Why a new file can change behavior by itself, or None.

    Its code only runs when a changed line uses it, unless it declares
    something the runtime finds by itself. That is checked at the top level
    and for members of extensions, which may extend an existing type.
    """
    in_extension = False
    for line in text.splitlines():
        stripped = line.strip()
        indent = len(line) - len(line.lstrip())
        if (
            not stripped or stripped.startswith(("//", "/*", "*", "import "))
            or CLOSING.fullmatch(stripped) or DIRECTIVE.match(line)
        ):
            continue
        if indent == 0:
            in_extension = bool(EXTENSION.match(stripped))
        elif not (in_extension and indent <= 4):
            continue
        kind, name = declaration(line)
        if kind == "implicit":
            return f"declares `{stripped[:60]}`"
        if kind is None:
            if indent == 0 and not stripped.startswith(("@", "#Preview")) and not (
                EXTENSION.match(stripped)
            ):
                return f"has top-level code: `{stripped[:60]}`"
            continue
        if not used[name]:
            return f"adds `{name}`, which no changed line uses"
    return None


def covered(path, change, index, platform, used):
    """(FULL or the goals that ran the changed lines, reason), from the index.

    `used` counts the words on the added lines of the whole diff.
    """
    old_text, new_text, hunks = change["old"], change["new"], change["hunks"]
    if old_text is None:
        # Only uses from other files make its code run.
        others = used - Counter(re.findall(r"\w+", new_text))
        if reason := new_file(new_text, others):
            return FULL, f"is new and {reason}"
        return set(), "is new; the changed lines that use it pick its goals"
    if new_text is None:
        return FULL, "is deleted"
    if path not in index.compiled:
        return set(), f"is not built for {platform}"
    if path not in index.files:
        return FULL, "is built but has no line data, such as only declarations"
    executable, ran = index.lines(path)
    old_kinds, new_kinds = scan(old_text, platform), scan(new_text, platform)
    old_words = set(re.findall(r"\w+", old_text))
    chosen = set()

    def nearest(line, step):
        """The closest executable line within a few lines."""
        for _ in range(4):
            if line in executable:
                return line
            line += step
        return None

    for old_start, old_count, new_start, removed, added in hunks:
        removed_lines = list(range(old_start, old_start + old_count)) if old_count else []
        added_lines = list(range(new_start, new_start + len(added)))
        if any(map(DIRECTIVE.match, removed + added)) and not (
            balanced(removed, platform) and balanced(added, platform)
        ):
            return FULL, f"changes `#if` structure near line {old_start}"
        added_names = {declaration(line)[1] for line in added} - {None}
        removed_names = {declaration(line)[1] for line in removed} - {None}
        for line, text in zip(removed_lines, removed):
            kind = old_kinds[line - 1]
            if kind == "condition":
                return FULL, f"changes `#if` at line {line}"
            if kind != "code":
                continue
            if line in executable:
                chosen |= ran.get(line, set())
                continue
            declared, name = declaration(text)
            redeclared = name in added_names
            if declared == "implicit" or (declared == "type" and redeclared):
                return FULL, f"changes a declaration at line {line}"
            if declared in ("stored", "type") or CLOSING.fullmatch(text.strip()):
                # Removed values and types took their uses with them.
                continue
            around = {nearest(line - 1, -1), nearest(line + 1, 1)} - {None}
            if not around and (declared is None or redeclared):
                return FULL, f"changes line {line}, which has no line data"
            for near in around:
                chosen |= ran.get(near, set())
        new_code = [
            text for line, text in zip(added_lines, added) if new_kinds[line - 1] == "code"
        ]
        if any(new_kinds[line - 1] == "condition" for line in added_lines):
            return FULL, f"adds an `#if` near line {old_start}"
        if not new_code:
            continue
        for text in new_code:
            declared, name = declaration(text)
            if declared == "implicit":
                return FULL, f"adds a declaration near line {old_start}: `{text.strip()[:60]}`"
            # The declaring line itself is one use.
            if declared and name not in removed_names and used[name] < 2:
                if declared in ("named", "type") or name not in old_words:
                    return FULL, f"adds `{name}`, which no changed line uses"
        # Code that replaces run lines runs where they ran; otherwise take
        # the lines around it.
        if any(line in executable for line in removed_lines):
            continue
        before = old_start - 1 if old_count else old_start
        after = old_start + old_count if old_count else old_start + 1
        around = {nearest(before, -1), nearest(after, 1)} - {None}
        if not around:
            return FULL, f"adds code near line {old_start}, which has no line data"
        for near in around:
            chosen |= ran.get(near, set())
    return chosen, f"{len(chosen)} goals ran its changed lines"


def git(*arguments, check=True):
    return subprocess.run(
        ["git", *arguments], cwd=ROOT, check=check, capture_output=True, text=True,
    )


def changes_since(commit, working_tree, full_diffs=()):
    """Each path changed since `commit`, with its sources and -U0 hunks.

    CI checks out a clean merge commit; locally, the working tree counts,
    including untracked files. Paths in `full_diffs` also get their whole
    diff as "diff".
    """
    target = [commit] if working_tree else [commit, "HEAD"]
    hunks = parse_diff(git(*DIFF, "-U0", *target).stdout)
    paths = set(hunks)
    if working_tree:
        paths.update(git("ls-files", "--others", "--exclude-standard").stdout.splitlines())

    def show(revision, path):
        result = git("show", f"{revision}:{path}", check=False)
        return result.stdout if result.returncode == 0 else None

    changes = {}
    for path in paths:
        change = changes[path] = {"hunks": hunks.get(path, [])}
        if path.endswith(".swift"):
            change["old"] = show(commit, path)
            if working_tree:
                file = ROOT / path
                change["new"] = file.read_text(errors="replace") if file.exists() else None
            else:
                change["new"] = show("HEAD", path)
    for path in full_diffs:
        if path in changes:
            changes[path]["diff"] = git(*DIFF, *target, "--", path).stdout
    return changes


def download_indexes(directory, names):
    """Fetch the newest artifact of each name built on main into `directory`."""
    repository = os.environ.get("GITHUB_REPOSITORY") or json.loads(subprocess.run(
        ["gh", "repo", "view", "--json", "nameWithOwner"],
        cwd=ROOT, check=True, capture_output=True, text=True,
    ).stdout)["nameWithOwner"]
    for name in names:
        listing = json.loads(subprocess.run(
            ["gh", "api", f"repos/{repository}/actions/artifacts?name={name}&per_page=30"],
            check=True, capture_output=True, text=True,
        ).stdout)
        artifacts = sorted(
            (
                artifact for artifact in listing["artifacts"]
                if not artifact["expired"]
                and artifact["workflow_run"]["head_branch"] == "main"
            ),
            key=lambda artifact: artifact["created_at"],
            reverse=True,
        )
        if not artifacts:
            continue
        archive = subprocess.run(
            ["gh", "api", f"repos/{repository}/actions/artifacts/{artifacts[0]['id']}/zip"],
            check=True, capture_output=True,
        ).stdout
        with zipfile.ZipFile(io.BytesIO(archive)) as contents:
            contents.extractall(directory)


def read_index(path, platform):
    """(Index, None) for a usable index file, else (None, why not)."""
    if path is None or not path.exists():
        return None, "no coverage index"
    try:
        index = Index(json.loads(path.read_text()))
    except (ValueError, KeyError, TypeError) as error:
        return None, f"{path.name} is unreadable ({error})"
    if index.platform != platform:
        return None, f"{path.name} is for {index.platform}"
    if git("cat-file", "-e", f"{index.commit}^{{commit}}", check=False).returncode:
        return None, f"coverage commit {index.commit[:12]} is not in this checkout"
    return index, None


def archive_lines(archive):
    """({path: executable lines}, {path: lines that ran}) of an xccov archive."""
    executable, ran = {}, {}
    for path, lines in archive.items():
        executable[path] = [line["line"] for line in lines if line.get("isExecutable")]
        ran[path] = [
            line["line"] for line in lines
            if line.get("isExecutable") and line.get("executionCount")
        ]
    return executable, ran


def coverage_index(platform, commit, ran, executable, compiled):
    """Which goal ran which line, keyed by paths relative to the checkout.

    `ran` maps each goal to {path: lines it ran}, `executable` maps each
    instrumented path to its executable lines, and `compiled` lists the Swift
    files the lane built. Lines are [first, last] ranges to keep it small.
    """
    prefix = str(ROOT) + "/"

    def ranges(lines):
        spans = []
        for line in sorted(lines):
            if spans and spans[-1][1] == line - 1:
                spans[-1][1] = line
            else:
                spans.append([line, line])
        return spans

    tests = sorted(ran)
    files = {
        path[len(prefix):]: {"executable": ranges(lines), "ran": {}}
        for path, lines in executable.items() if path.startswith(prefix)
    }
    for number, test in enumerate(tests):
        for path, lines in ran[test].items():
            relative = path[len(prefix):] if path.startswith(prefix) else None
            if relative in files and lines:
                files[relative]["ran"][str(number)] = ranges(lines)
    return {
        "platform": platform,
        "commit": commit,
        "tests": tests,
        "compiled": sorted(
            path[len(prefix):] for path in compiled if path.startswith(prefix)
        ),
        "files": files,
    }
