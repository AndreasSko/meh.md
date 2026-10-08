import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class ParserRunnerTests(unittest.TestCase):
    def test_prebuild_rotation_and_collection_after_failure(self):
        script = Path(__file__).with_name("run_parser_performance_ci.sh").resolve()
        for fail in ("", "reference", "modified"):
            with self.subTest(fail=fail), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                binaries = root / "bin"
                binaries.mkdir()
                for name in ("baseline", "reference"):
                    (root / name).mkdir()
                log = root / "calls"
                stubs = {
                    "git": """#!/bin/bash
if [[ "$3" == diff ]]; then
  [[ "$FAIL_VARIANT" != modified ]]
  exit $?
fi
case "$2" in
  */baseline) echo 1378bf5e1b9fcaf0ff5e97435a320ef7d726ef42 ;;
  */reference) echo 369814141840b6f9ee1f898eae628d35ad4d68ca ;;
esac
""",
                    "swift": """#!/bin/bash
label=${PWD##*/}
[[ "$label" == baseline || "$label" == reference ]] || label=current
printf '%s %s\n' "$label" "$*" >> "$CALLS"
if [[ "$*" == *--skip-build* && "$label" == "$FAIL_VARIANT" ]]; then exit 1; fi
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
                                   CALLS=str(log), FAIL_VARIANT=fail,
                                   RUNNER_TEMP=str(root),
                                   EDITOR_PERFORMANCE_BASELINE_ROOT=str(root / "baseline"),
                                   EDITOR_PERFORMANCE_REFERENCE_ROOT=str(root / "reference"))
                result = subprocess.run(["bash", str(script)], env=environment,
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 1 if fail else 0, result.stderr)
                if fail == "modified":
                    self.assertIn("Modified baseline control production sources", result.stderr)
                    self.assertFalse(log.exists())
                    continue
                lines = log.read_text().splitlines()
                self.assertEqual([line.split()[0] for line in lines[:3]],
                                 ["baseline", "reference", "current"])
                self.assertTrue(all("test -c release --filter MarkdownFullParsePerformanceTests" in line
                                    for line in lines[:3]))
                self.assertEqual([line.split()[0] for line in lines[3:12]],
                                 ["baseline", "reference", "current",
                                  "reference", "current", "baseline",
                                  "current", "baseline", "reference"])
                self.assertTrue(all("--skip-build" in line for line in lines[3:12]))
                self.assertEqual(lines[12].count("--paired-"), 9)


if __name__ == "__main__":
    unittest.main()
