import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class ParserRunnerTests(unittest.TestCase):
    def test_current_only_build_and_collection_after_failure(self):
        script = Path(__file__).with_name("run_parser_performance_ci.sh").resolve()
        for fail in ("", "1"):
            with self.subTest(fail=fail), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                binaries = root / "bin"
                binaries.mkdir()
                log = root / "calls"
                stubs = {
                    "swift": """#!/bin/bash
printf 'swift %s\n' "$*" >> "$CALLS"
if [[ "$*" == *--skip-build* && "$FAIL_RUN" == 1 && "$MEH_FULL_PARSE_LABEL" == ci-current-1 ]]; then exit 1; fi
""",
                    "python3": """#!/bin/bash
printf 'gate %s\n' "$*" >> "$CALLS"
""",
                }
                for name, content in stubs.items():
                    path = binaries / name
                    path.write_text(content)
                    path.chmod(0o755)
                environment = dict(os.environ, PATH=f"{binaries}:{os.environ['PATH']}",
                                   CALLS=str(log), FAIL_RUN=fail, RUNNER_TEMP=str(root))
                result = subprocess.run(["bash", str(script)], env=environment,
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 1 if fail else 0, result.stderr)
                lines = log.read_text().splitlines()
                self.assertEqual(len(lines), 5)
                self.assertNotIn("--skip-build", lines[0])
                self.assertTrue(all("--skip-build" in line for line in lines[1:4]))
                self.assertIn("--recorded-reference", lines[4])
                self.assertEqual(lines[4].count("--current-report"), 3)
                self.assertNotIn("--paired-", lines[4])


if __name__ == "__main__":
    unittest.main()
