"""Exercise remote parity orchestration without Xcode or simulator access."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from test_check_native_editor_baseline_parity import REQUIRED_METHODS, current_results, results


class NativeParityOrchestrationTests(unittest.TestCase):
    def run_stubbed(self, fail_build=""):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repo, binary, evidence = root / "repo", root / "bin", root / "fixtures"
            for path in (repo / "scripts", binary, evidence, root / "runner"):
                path.mkdir(parents=True)
            for entry in ("Sources", "Tests", "meh.md"):
                (repo / entry).mkdir()
            (repo / "Package.swift").write_text("// stub package\n")
            for name in ("run_native_editor_baseline_parity.sh",
                         "check_native_editor_baseline_parity.py"):
                shutil.copy2(Path(__file__).with_name(name), repo / "scripts" / name)
            for label in ("baseline", "current"):
                fixture = results if label == "baseline" else current_results
                summary, tree, _ = fixture(failing=REQUIRED_METHODS)
                (evidence / f"{label}-summary.json").write_text(json.dumps(summary))
                (evidence / f"{label}-tests.json").write_text(json.dumps(tree))
            stubs = {
                "git": r'''#!/bin/bash
set -eu
shift 2
if [[ "$1" == worktree && "$2" == add ]]; then
  mkdir -p "$4/Sources" "$4/Tests" "$4/meh.md"
  cp "$STUB_REPO/Package.swift" "$4/Package.swift"
elif [[ "$1" == worktree && "$2" == remove ]]; then
  echo worktree:remove >> "$STUB_EVENTS"
elif [[ "$1" == rev-parse ]]; then
  echo 64a72671e3dd8fc31905f15d9a4e08fe3ca8b678
elif [[ "$1" == -c ]]; then
  exit 0
else
  exit 3
fi
''',
                "xcodebuild": r'''#!/bin/bash
set -eu
if [[ "$1" == -version ]]; then echo 'Xcode 27.0'; exit 0; fi
phase="$1"
shift
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -derivedDataPath) derived="$2"; shift ;;
    -resultBundlePath) bundle="$2"; shift ;;
  esac
  shift
done
if [[ "$phase" == build-for-testing ]]; then
  label="$(basename "$derived" -build)"
  echo "build:$label" >> "$STUB_EVENTS"
  [[ "$label" != "$STUB_FAIL_BUILD" ]] || exit 70
  mkdir -p "$derived/Build/Products"
  touch "$derived/Build/Products/MehCore-Package_arm64-iphonesimulator.xctestrun"
else
  label="$(basename "$bundle" .xcresult)"
  echo "test:$label" >> "$STUB_EVENTS"
  mkdir -p "$bundle"
  exit 65
fi
''',
                "xcrun": r'''#!/bin/bash
set -eu
if [[ "$1" == simctl ]]; then
  case "$2" in
    list) echo '{"runtimes":[{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-27-0","version":"27.0","isAvailable":true}],"devicetypes":[{"identifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro"}]}' ;;
    create) echo OWNED-PARITY-SIM ;;
    boot|bootstatus) [[ "$3" == OWNED-PARITY-SIM ]] ;;
    shutdown|delete) [[ "$3" == OWNED-PARITY-SIM ]]; echo "sim:$2" >> "$STUB_EVENTS" ;;
    *) exit 3 ;;
  esac
else
  kind="$4"
  label="$(basename "$6" .xcresult)"
  cat "$STUB_FIXTURES/$label-$kind.json"
fi
''',
            }
            for name, content in stubs.items():
                path = binary / name
                path.write_text(content)
                path.chmod(0o755)
            environment = dict(os.environ, PATH=f"{binary}:{os.environ['PATH']}",
                               RUNNER_TEMP=str(root / "runner"), STUB_REPO=str(repo),
                               STUB_FIXTURES=str(evidence), STUB_EVENTS=str(root / "events"),
                               STUB_FAIL_BUILD=fail_build)
            result = subprocess.run(["/bin/bash", str(repo / "scripts" /
                                     "run_native_editor_baseline_parity.sh")],
                                    env=environment, capture_output=True, text=True)
            events = (root / "events").read_text().splitlines()
            preserved = list((root / "runner").glob("native-editor-parity-evidence.*"))
            self.assertEqual(len(preserved), 1)
            files = {path.name for path in preserved[0].iterdir()}
            self.assertFalse(list((root / "runner").glob("native-editor-parity-work.*")))
            return result, events, files

    def test_existing_failure_runs_both_variants_and_preserves_both_results(self):
        result, events, files = self.run_stubbed()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(events[:4], ["build:baseline", "test:baseline",
                                     "build:current", "test:current"])
        for label in ("baseline", "current"):
            for suffix in (".xcresult", "-summary.json", "-tests.json", "-test.log"):
                self.assertIn(label + suffix, files)
        self.assertIn("BASELINE failing methods:", result.stdout)
        self.assertEqual(events.count("sim:delete"), 1)
        self.assertEqual(events.count("worktree:remove"), 1)

    def test_baseline_build_failure_still_runs_current_and_fails_closed(self):
        result, events, files = self.run_stubbed(fail_build="baseline")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("test:current", events)
        self.assertIn("baseline-build.log", files)
        self.assertIn("current.xcresult", files)
        self.assertIn("infrastructure/build failure: baseline", result.stderr)
        self.assertEqual(events.count("sim:delete"), 1)


if __name__ == "__main__":
    unittest.main()
