"""Source inventory supplementing compiler test enumeration and result evidence.

This intentionally supports the repository's XCTest declaration subset. It is
not a Swift parser: CI must compare this inventory with compiler-discovered IDs
and successful result IDs, rather than accepting source declarations as runs.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re

PLATFORMS = {"macos", "iphone", "ipad"}


def _condition(expression: str, platform: str) -> bool:
    expression = expression.strip()
    values = {
        "os(macOS)": platform == "macos",
        "os(iOS)": platform != "macos",
        "canImport(AppKit)": platform == "macos",
        "canImport(UIKit)": platform != "macos",
        "canImport(FoundationNetworking)": False,
        "DEBUG": True,
        "ICLOUD_ENABLED": True,
    }
    if expression in values:
        return values[expression]
    if "||" in expression:
        return any([_condition(item, platform)
                    for item in expression.split("||")])
    if "&&" in expression:
        return all([_condition(item, platform)
                    for item in expression.split("&&")])
    if expression.startswith("!"):
        return not _condition(expression[1:], platform)
    raise ValueError(f"Unsupported Swift conditional: {expression}")


def _active_source(source: str, platform: str) -> str:
    stack = []
    active = True
    output = []
    for line in source.splitlines(keepends=True):
        directive = re.match(r"\s*#(if|elseif|else|endif)\b(.*)", line)
        if not directive:
            output.append(line if active else "\n")
            continue
        kind, expression = directive.groups()
        if kind == "if":
            value = _condition(expression, platform)
            stack.append([active, value])
            active = active and value
        elif not stack:
            raise ValueError("Unbalanced Swift conditional")
        elif kind == "elseif":
            parent, taken = stack[-1]
            value = _condition(expression, platform)
            active = parent and not taken and value
            stack[-1][1] = taken or value
        elif kind == "else":
            parent, taken = stack[-1]
            active = parent and not taken
            stack[-1][1] = True
        else:
            active = stack.pop()[0]
        output.append("\n")
    if stack:
        raise ValueError("Unclosed Swift conditional")
    return "".join(output)


def _mask_literals(source: str) -> str:
    # Preserve offsets while removing comments and string-literal braces.
    pattern = r'//[^\n]*|/\*[\s\S]*?\*/|#+"""[\s\S]*?"""#+|"""[\s\S]*?"""|#+"(?:\\.|[^"\\])*"#+|"(?:\\.|[^"\\])*"'
    return re.sub(pattern, lambda match: re.sub(r"[^\n]", " ", match[0]),
                  source)


def _body(source: str, masked: str, start: int) -> str:
    opening = masked.find("{", start)
    if opening < 0:
        raise ValueError("Test declaration has no body")
    depth = 0
    for index in range(opening, len(masked)):
        if masked[index] == "{":
            depth += 1
        elif masked[index] == "}":
            depth -= 1
            if depth == 0:
                return source[opening:index + 1]
    raise ValueError("Unclosed test body")


def _classification(class_name: str, method: str, body: str,
                    platform: str) -> tuple[str, bool, str]:
    category, skipped, reason = "standard", False, ""
    if class_name == "ICloudDevelopmentUITests":
        return "live-icloud", True, "Requires a signed-in live iCloud account"
    if class_name == "LocalSyncUITests":
        return "ordered-loopback", False, "Run phone, pad, original phone in order"
    if class_name == "NotebookImportUITests":
        return "import-fixture", False, "Requires seeded Files picker fixtures"
    if (class_name == "NativeEditorIntegrationTests"
            and method == "testFiveReturnsKeepNativeInsertionIndicatorVisible"
            and platform == "macos"):
        return "app-host", True, "Covered by the native caret app probe"
    # Device guards may live in a shared helper, so classify that whole suite.
    if class_name in {"EditorScrollTypingUITests", "EditorLongNoteTapUITests",
                      "NotebookBrowserScrollUITests"}:
        skipped = platform == "ipad"
        reason = "Requires iPhone software keyboard or compact navigation"
    phone_guard = re.search(
        r"userInterfaceIdiom\s*(?:==|!=)\s*\.phone", body)
    pad_guard = re.search(r"userInterfaceIdiom\s*(?:==|!=)\s*\.pad", body)
    if "XCTSkip" in body and phone_guard:
        skipped = platform == "ipad"
        reason = "Requires iPhone"
    if "XCTSkip" in body and pad_guard:
        skipped = platform == "iphone"
        reason = "Requires iPad"
    if (class_name == "RecentNotesUITests"
            and method == "testLeavingNoteRestoresBrowserUntilNoteIsOpenedAgain"):
        skipped = platform == "ipad"
        reason = "Requires compact navigation"
    if platform == "macos" and "throw XCTSkip(" in body:
        if class_name in {"LargeNoteHistoryUITests", "NoteHistoryUITests"}:
            skipped, reason = True, "Interaction regression covered on iOS"
    return category, skipped, reason


def inventory(root: str | Path, platform: str) -> list[dict]:
    """Return source-declared XCTest IDs for a platform and explicit routing.

    ``expected_skip`` only permits a platform/host or live-cloud exemption;
    missing benchmark flags and missing fixtures must still fail CI.
    """
    if platform not in PLATFORMS:
        raise ValueError(f"Unsupported platform: {platform}")
    root = Path(root)
    paths = sorted((root / "Tests").rglob("*.swift"))
    paths += sorted((root / "meh.mdUITests").rglob("*.swift"))
    records = []
    for path in paths:
        source = _active_source(path.read_text(), platform)
        masked = _mask_literals(source)
        classes = list(re.finditer(
            r"\bclass\s+(\w+)\s*:\s*XCTestCase\b", masked))
        declarations = list(re.finditer(r"\bfunc\s+(test\w*)\s*\(\s*\)", masked))
        suspicious = list(re.finditer(r"\bfunc\s+test\w*\s*\(", masked))
        if "@Test" in masked or len(suspicious) != len(declarations):
            raise ValueError(f"Unsupported test declaration in {path}")
        if not declarations:
            continue
        target = ("meh.mdUITests" if path.parent.name == "meh.mdUITests"
                  else path.relative_to(root / "Tests").parts[0])
        for declaration in declarations:
            containers = []
            for candidate in classes:
                opening = masked.find("{", candidate.end())
                closing = opening + len(_body(source, masked, candidate.end()))
                if opening < declaration.start() < closing:
                    containers.append(candidate[1])
            if len(containers) != 1:
                raise ValueError(f"Test outside one XCTestCase class in {path}")
            class_name = containers[0]
            method = declaration[1]
            body = _body(source, masked, declaration.end())
            category, skip, reason = _classification(
                class_name, method, body, platform)
            records.append({
                "id": f"{target}/{class_name}/{method}",
                "target": target, "class_name": class_name, "method": method,
                "path": str(path.relative_to(root)), "category": category,
                "expected_skip": skip, "skip_reason": reason,
            })
    ids = [record["id"] for record in records]
    if len(ids) != len(set(ids)):
        raise ValueError("Duplicate XCTest IDs in source inventory")
    return sorted(records, key=lambda record: record["id"])


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("platform", choices=sorted(PLATFORMS))
    parser.add_argument("--root", default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    print(json.dumps(inventory(args.root, args.platform), indent=2))


if __name__ == "__main__":
    main()
