#!/usr/bin/env python3
"""Run every repository Python test file and retain exact passing IDs."""
import ast
import hashlib
import json
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]


def declared_tests(root):
    declared = set()
    for path in sorted(root.rglob("test_*.py")):
        if any(part.startswith(".") for part in path.relative_to(root).parts):
            continue
        if path.parent not in (root / "scripts", root / "Tools/CloudKit", root / "Tools/LocalSyncServer"):
            raise ValueError(f"New Python test directory needs CI routing: {path}")
        file_tests = set()
        for cls in ast.parse(path.read_text()).body:
            if isinstance(cls, (ast.FunctionDef, ast.AsyncFunctionDef)) and cls.name.startswith("test"):
                raise ValueError(f"Unsupported function test; add runner support: {path}:{cls.name}")
            if isinstance(cls, ast.ClassDef):
                for method in cls.body:
                    if isinstance(method, (ast.FunctionDef, ast.AsyncFunctionDef)) and method.name.startswith("test"):
                        identifier = f"{path.stem}.{cls.name}.{method.name}"
                        if identifier in declared:
                            raise ValueError(f"Duplicate Python source test: {identifier}")
                        declared.add(identifier)
                        file_tests.add(identifier)
        if not file_tests:
            raise ValueError(f"Python test file has no supported tests: {path}")
    return declared


def test_suite(root):
    suite = unittest.TestSuite()
    for directory in (root / "scripts", root / "Tools/CloudKit", root / "Tools/LocalSyncServer"):
        suite.addTests(unittest.TestLoader().discover(str(directory), pattern="test_*.py"))
    return suite


class RecordingResult(unittest.TextTestResult):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.passed_ids = []

    def addSuccess(self, test):
        self.passed_ids.append(test.id())
        super().addSuccess(test)


def main():
    output = Path(sys.argv[1])
    expected = declared_tests(ROOT)
    result = unittest.TextTestRunner(verbosity=2, resultclass=RecordingResult).run(test_suite(ROOT))
    if not result.wasSuccessful() or result.skipped or set(result.passed_ids) != expected:
        raise SystemExit(f"Python coverage failed: missing={sorted(expected - set(result.passed_ids))}, "
                         f"unexpected={sorted(set(result.passed_ids) - expected)}, skipped={result.skipped}")
    if len(result.passed_ids) != len(expected):
        raise SystemExit("Duplicate Python test executions")
    output.write_text(json.dumps({"version": 1, "platform": "host", "scope": "python",
                                  "passed": sorted(result.passed_ids),
                                  "inventory_sha256": hashlib.sha256(json.dumps(sorted(expected)).encode()).hexdigest()},
                                 indent=2) + "\n")


if __name__ == "__main__":
    main()
