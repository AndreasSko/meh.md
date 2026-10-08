"""Exercise the simulator CI orchestration with isolated command stubs."""

import json
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import sys
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parent.parent
CI_SCRIPT = REPO_ROOT / "scripts" / "run_editor_performance_ci.sh"
BASELINE_REVISION = "1378bf5e1b9fcaf0ff5e97435a320ef7d726ef42"
REFERENCE_REVISION = "369814141840b6f9ee1f898eae628d35ad4d68ca"


def write_executable(path, contents):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(contents, encoding="utf-8")
    path.chmod(0o755)


class EditorPerformanceCIOrchestrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.event_log = self.root / "events.log"
        self.capture_log = self.root / "checker-args.jsonl"
        self.output_path = self.root / "github-output"
        self.runner_temp = self.root / "runner-temp"
        self.runner_temp.mkdir()
        self.baseline = self._make_worktree(
            "baseline", BASELINE_REVISION
        )
        self.reference = self._make_worktree(
            "reference", REFERENCE_REVISION
        )
        self.candidate = self._make_worktree("candidate", "candidate-head")

        original = CI_SCRIPT.read_text(encoding="utf-8")
        write_executable(
            self.candidate / "scripts" / "run_editor_performance_ci.sh",
            original,
        )
        self._write_harness(self.candidate)
        self._write_harness(self.baseline)
        self._write_harness(self.reference)
        shutil.copy2(
            REPO_ROOT / "scripts" / "check_editor_performance.py",
            self.candidate / "scripts" / "check_editor_performance.py",
        )
        self._write_python_wrapper()
        self._write_git_stub()
        self._write_xcrun_stub()

    def tearDown(self):
        self.temporary.cleanup()

    def _make_worktree(self, name, revision):
        root = self.root / name
        (root / "scripts").mkdir(parents=True)
        (root / ".git").write_text("gitdir: fake\n", encoding="utf-8")
        (root / ".revision").write_text(revision, encoding="utf-8")
        return root

    def _write_harness(self, root):
        write_executable(root / "scripts" / "run_editor_performance_check.sh", r'''#!/bin/bash
set -euo pipefail
if [[ "${EDITOR_PERFORMANCE_BUILD_ONLY:-0}" == 1 ]]; then
  printf 'build:%s\n' "$(cd "$(dirname "$0")/.." && pwd)" >> "$ORCH_EVENT_LOG"
  [[ "${ORCH_FAIL_BUILD:-}" != "$(basename "$(cd "$(dirname "$0")/.." && pwd)")" ]] || exit 3
  exit 0
fi
label="$(basename "$5" .json)"
printf 'probe:%s:%s\n' "$label" "$(cd "$(dirname "$0")/.." && pwd)" >> "$ORCH_EVENT_LOG"
[[ "${ORCH_FAIL_PROBE:-}" != "$label" ]] || exit 4
python3 - "$5" "$4" <<'PY'
import json
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
size = int(sys.argv[2])
shape = os.environ["EDITOR_PERFORMANCE_SHAPE"]
suffix = {"standard": 0, "nearby-table": 52}[shape]
counts = {
    "typing": 21,
    "deletion": 6,
    "bulk_insert": 1,
    "middle_bold_open": 2,
    "middle_bold_typing": 6,
    "middle_bold_close": 2,
}
measurements = {
    "open_to_idle_ms": [20.0],
    "main_actor_scheduling_delay_ms": [1.0],
    "autosave_wait_including_debounce_ms": [20.0],
}
steps = []
for action, count in counts.items():
    measurements[f"{action}_synchronous_ms"] = [10.0] * count
    measurements[f"{action}_to_idle_ms"] = [20.0] * count
    steps.extend({
        "action": action,
        "full_parses": 0,
        "incremental_parses": 1,
        "synchronous_ms": 10.0,
        "to_idle_ms": 20.0,
        "formatted_utf16_length": 256,
        "presentation_current_at_idle": True,
    } for _ in range(count))
report = {
    "scenario": "large-note",
    "mode": "livePreview",
    "host": "notebook",
    "context": os.environ["EDITOR_PERFORMANCE_CONTEXT"],
    "shape": shape,
    "requested_kb": size,
    "fixture_sha256": "a" * 64,
    "utf8_bytes": size * 1000 + suffix,
    "utf16_length": size * 1000 + suffix,
    "source_and_selection_preserved": True,
    "saved_text_preserved": True,
    "final_presentation_verified": True,
    "full_parses_during_edits": 0,
    "incremental_parses_during_edits": len(steps),
    "measurements": measurements,
    "steps": steps,
}
path.write_text(json.dumps(report), encoding="utf-8")
PY
''')

    def _write_python_wrapper(self):
        write_executable(self.bin / "python3", r'''#!/bin/bash
set -euo pipefail
if [[ "$#" -gt 0 && "$1" == *"/candidate/scripts/check_editor_performance.py" ]]; then
  shift
  printf '%s\n' "$*" >> "$ORCH_CAPTURE_LOG"
  label="$(basename "${1:-}" .json)"
  printf 'check:%s\n' "$label" >> "$ORCH_EVENT_LOG"
  echo "stub-check:$label"
  [[ "${ORCH_FAIL_LABEL:-}" != "$label" ]] || exit 1
  exit 0
fi
exec "$ORCH_REAL_PYTHON" "$@"
''')

    def _write_git_stub(self):
        write_executable(self.bin / "git", r'''#!/bin/bash
set -euo pipefail
if [[ "$1" == "-C" ]]; then
  root="$2"
  shift 2
  if [[ "$1" == "rev-parse" ]]; then
    cat "$root/.revision"
    exit 0
  fi
  if [[ "$1" == "-c" ]]; then
    exit 0
  fi
fi
printf 'unexpected-git-call:%s\n' "$*" >> "$ORCH_EVENT_LOG"
exit 3
''')

    def _write_xcrun_stub(self):
        write_executable(self.bin / "xcrun", r'''#!/bin/bash
set -euo pipefail
if [[ "$1" == "simctl" && "$2" == "list" ]]; then
  cat <<'JSON'
{"runtimes":[{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-27-0","version":"27.0","isAvailable":true}],"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-0":[{"deviceTypeIdentifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro","isAvailable":true}]}}
JSON
elif [[ "$1" == "simctl" && "$2" == "create" ]]; then
  printf 'sim:create\n' >> "$ORCH_EVENT_LOG"
  printf 'OWNED-SIMULATOR\n'
elif [[ "$1" == "simctl" && "$2" == "shutdown" ]]; then
  [[ "$3" == "OWNED-SIMULATOR" ]]
  printf 'sim:shutdown\n' >> "$ORCH_EVENT_LOG"
elif [[ "$1" == "simctl" && "$2" == "delete" ]]; then
  [[ "$3" == "OWNED-SIMULATOR" ]]
  printf 'sim:delete\n' >> "$ORCH_EVENT_LOG"
else
  printf 'unexpected-xcrun-call:%s\n' "$*" >> "$ORCH_EVENT_LOG"
  exit 3
fi
''')

    def _environment(self, **extra):
        environment = os.environ.copy()
        environment.update({
            "PATH": f"{self.bin}{os.pathsep}{environment['PATH']}",
            "RUNNER_TEMP": str(self.runner_temp),
            "GITHUB_RUN_ID": "orchestration-test",
            "GITHUB_RUN_ATTEMPT": "1",
            "GITHUB_OUTPUT": str(self.output_path),
            "EDITOR_PERFORMANCE_BASELINE_ROOT": str(self.baseline),
            "EDITOR_PERFORMANCE_REFERENCE_ROOT": str(self.reference),
            "ORCH_EVENT_LOG": str(self.event_log),
            "ORCH_CAPTURE_LOG": str(self.capture_log),
            "ORCH_REAL_PYTHON": sys.executable,
        })
        environment.update(extra)
        return environment

    def _run_script(self, **extra):
        return subprocess.run(
            ["/bin/bash", str(self.candidate / "scripts" /
                              "run_editor_performance_ci.sh")],
            cwd=self.root,
            env=self._environment(**extra),
            capture_output=True,
            text=True,
            check=False,
        )

    def _events(self):
        return self.event_log.read_text(encoding="utf-8").splitlines()

    def test_runs_all_controls_and_cases_with_one_owned_simulator(self):
        result = self._run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        events = self._events()
        probes = [event for event in events if event.startswith("probe:")]
        self.assertEqual([event.split(":")[1] for event in probes], [
            "baseline-standard-500kb",
            "reference-standard-500kb",
            "standard-500kb",
            "standard-500kb-2",
            "reference-standard-500kb-2",
            "reference-standard-500kb-3",
            "standard-500kb-3",
            "mixed-50kb",
            "nearby-table-50kb",
        ])
        builds = [event for event in events if event.startswith("build:")]
        self.assertEqual(builds, [f"build:{root}" for root in
                                  (self.baseline, self.reference, self.candidate)])
        self.assertLess(events.index(builds[-1]), events.index(probes[0]))
        self.assertEqual(events.count("sim:shutdown"), 1)
        self.assertEqual(events.count("sim:delete"), 1)
        self.assertLess(events.index(probes[-1]), events.index("sim:shutdown"))
        self.assertLess(events.index("check:nearby-table-50kb"),
                        events.index("sim:shutdown"))
        self.assertLess(events.index("sim:shutdown"), events.index("sim:delete"))

        checker_arguments = [
            shlex.split(line)
            for line in self.capture_log.read_text(encoding="utf-8").splitlines()
        ]
        current_standard = next(
            arguments for arguments in checker_arguments
            if arguments[0].endswith("/standard-500kb.json")
        )
        self.assertIn("--baseline-report", current_standard)
        self.assertNotIn("--reference-report", current_standard)
        self.assertTrue(any(argument.endswith("/baseline-standard-500kb.json")
                            for argument in current_standard))
        aggregate = next(args for args in checker_arguments
                         if "--paired-current-report" in args)
        self.assertEqual(aggregate.count("--paired-current-report"), 3)
        self.assertEqual(aggregate.count("--paired-reference-report"), 3)
        self.assertNotIn("", current_standard)
        mixed = next(
            arguments for arguments in checker_arguments
            if arguments[0].endswith("/mixed-50kb.json")
        )
        nearby = next(
            arguments for arguments in checker_arguments
            if arguments[0].endswith("/nearby-table-50kb.json")
        )
        self.assertNotIn("--baseline-report", mixed)
        self.assertNotIn("--reference-report", mixed)
        self.assertNotIn("--baseline-report", nearby)
        self.assertNotIn("--reference-report", nearby)
        self.assertTrue(self.output_path.read_text(encoding="utf-8").startswith(
            f"evidence_root={self.runner_temp}/editor-performance-evidence-"
        ))

    def test_checker_failure_collects_later_cases_and_cleans_up_once(self):
        result = self._run_script(ORCH_FAIL_LABEL="mixed-50kb")
        self.assertNotEqual(result.returncode, 0)
        events = self._events()
        probes = [event for event in events if event.startswith("probe:")]
        self.assertEqual([event.split(":")[1] for event in probes], [
            "baseline-standard-500kb",
            "reference-standard-500kb",
            "standard-500kb",
            "standard-500kb-2",
            "reference-standard-500kb-2",
            "reference-standard-500kb-3",
            "standard-500kb-3",
            "mixed-50kb",
            "nearby-table-50kb",
        ])
        self.assertIn("Failed performance case: mixed-50kb", result.stderr)
        self.assertEqual(events.count("sim:shutdown"), 1)
        self.assertEqual(events.count("sim:delete"), 1)
        self.assertLess(events.index(probes[-1]), events.index("sim:shutdown"))
        self.assertLess(events.index("check:mixed-50kb"),
                        events.index("sim:shutdown"))
        self.assertLess(events.index("sim:shutdown"), events.index("sim:delete"))

    def test_even_attempt_reverses_each_pair(self):
        result = self._run_script(GITHUB_RUN_ATTEMPT="2")
        self.assertEqual(result.returncode, 0, result.stderr)
        probes = [event.split(":")[1] for event in self._events()
                  if event.startswith("probe:")]
        self.assertEqual(probes[1:7], [
            "standard-500kb", "reference-standard-500kb",
            "reference-standard-500kb-2", "standard-500kb-2",
            "standard-500kb-3", "reference-standard-500kb-3",
        ])

    def test_runner_failure_preserves_later_evidence(self):
        result = self._run_script(ORCH_FAIL_PROBE="standard-500kb")
        self.assertNotEqual(result.returncode, 0)
        events = self._events()
        self.assertIn("check:nearby-table-50kb", events)
        self.assertIn("standard-500kb (status 4)", result.stderr)
        self.assertEqual(events.count("sim:delete"), 1)

    def test_failed_prebuild_never_starts_measurement(self):
        result = self._run_script(ORCH_FAIL_BUILD="reference")
        self.assertNotEqual(result.returncode, 0)
        events = self._events()
        self.assertFalse(any(event.startswith("probe:") for event in events))
        self.assertEqual(events.count("sim:delete"), 1)


if __name__ == "__main__":
    unittest.main()
