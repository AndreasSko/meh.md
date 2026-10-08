import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class RemoteDiagnosticContractTests(unittest.TestCase):
    def test_refuses_local_execution_before_any_simulator_action(self):
        environment = dict(os.environ, CI="false")
        for name in ("run_editor_performance_diagnostic.sh",
                     "run_editor_performance_fresh_diagnostic.sh"):
            result = subprocess.run(["bash", str(ROOT / "scripts" / name)],
                                    env=environment, capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertIn("restricted to CI", result.stderr)

    def test_workflow_dispatch_keeps_diagnostics_unscored_and_uploads_failures(self):
        workflow = (ROOT / ".github/workflows/editor-performance.yml").read_text()
        self.assertIn("diagnostic_only:", workflow)
        self.assertIn("type: boolean", workflow)
        self.assertIn("github.event_name != 'workflow_dispatch' || !inputs.diagnostic_only", workflow)
        self.assertIn("github.event_name == 'workflow_dispatch' && inputs.diagnostic_only", workflow)
        job = workflow.split("  editor-performance-diagnostic:", 1)[1]
        self.assertIn("timeout-minutes: 15", job)
        self.assertIn("if: always() && steps.diagnostic.outputs.evidence_root != ''", job)
        self.assertNotIn("check_editor_performance.py", job)
        diagnostic = (ROOT / "scripts/run_editor_performance_diagnostic.sh").read_text()
        self.assertIn("EDITOR_PERFORMANCE_START_DELAY_SECONDS=30", diagnostic)
        self.assertIn("EDITOR_PERFORMANCE_DIAGNOSTIC_KEEP_ALIVE_SECONDS=60", diagnostic)

    def run_fresh_stub(self, failure=""):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repo, binary, runner = root / "repo", root / "bin", root / "runner"
            for path in (repo / "scripts", repo / "Tools/EditorQuoteCheck", binary, runner):
                path.mkdir(parents=True)
            shutil.copy2(ROOT / "scripts/run_editor_performance_fresh_diagnostic.sh",
                         repo / "scripts/run_editor_performance_fresh_diagnostic.sh")
            (repo / "scripts/editor_performance_app_cache.py").write_text("# stub helper")
            scripts = {
                repo / "scripts/run_editor_performance_check.sh": r'''#!/bin/bash
set -eu
[[ "$EDITOR_PERFORMANCE_BUILD_ONLY" == 1 && "$EDITOR_PERFORMANCE_HOST" == notebook ]]
echo prebuild >> "$STUB_EVENTS"
[[ "$STUB_FAILURE" != build ]] || exit 11
mkdir -p "$EDITOR_PERFORMANCE_APP_CACHE"
''',
                repo / "scripts/run_editor_performance_diagnostic.sh": r'''#!/bin/bash
set -eu
[[ -f "$EDITOR_PERFORMANCE_DIAGNOSTIC_INVENTORY" ]]
[[ -d "$EDITOR_PERFORMANCE_DIAGNOSTIC_APP_CACHE" ]]
echo diagnostic >> "$STUB_EVENTS"
root="$RUNNER_TEMP/editor-performance-diagnostic-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
echo '{"unscored":true}' > "$root/reference-unscored.json"
mkdir -p "$root/optimized-reference.trace"
echo 'raw profiler log'
[[ "$STUB_FAILURE" != trace ]] || exit 12
''',
                binary / "git": r'''#!/bin/bash
set -eu
shift 2
if [[ "$1" == worktree && "$2" == add ]]; then
  mkdir -p "$4"
  echo register >> "$STUB_EVENTS"
elif [[ "$1" == worktree && "$2" == remove ]]; then
  echo remove >> "$STUB_EVENTS"
elif [[ "$1" == rev-parse ]]; then
  [[ "$STUB_FAILURE" != revision ]] || { echo wrong-revision; exit 0; }
  echo 369814141840b6f9ee1f898eae628d35ad4d68ca
elif [[ "$1" == -c ]]; then
  [[ "$STUB_FAILURE" != sources ]] || exit 1
else
  exit 3
fi
''',
                binary / "xcrun": r'''#!/bin/bash
set -eu
[[ "$*" == 'simctl list --json' ]]
echo inventory >> "$STUB_EVENTS"
echo '{"runtimes":[],"devices":{}}'
''',
            }
            for path, contents in scripts.items():
                path.write_text(contents)
                path.chmod(0o755)
            environment = dict(os.environ, CI="true", RUNNER_TEMP=str(runner),
                               GITHUB_RUN_ID="stub", GITHUB_RUN_ATTEMPT="1",
                               GITHUB_OUTPUT=str(root / "outputs"), STUB_FAILURE=failure,
                               STUB_EVENTS=str(root / "events"),
                               PATH=f"{binary}:{os.environ['PATH']}")
            result = subprocess.run(["bash", str(repo / "scripts/run_editor_performance_fresh_diagnostic.sh")],
                                    env=environment, capture_output=True, text=True, timeout=10)
            events = (root / "events").read_text().splitlines()
            evidence = runner / "editor-performance-diagnostic-stub-1"
            names = {path.name for path in evidence.iterdir()}
            self.assertEqual(events.count("remove"), 1)
            self.assertFalse(list(runner.glob("editor-fresh-diagnostic-work.*")))
            self.assertIn(f"evidence_root={evidence}", (root / "outputs").read_text())
            return result, events, names

    def test_fresh_runner_prebuilds_before_inventory_and_preserves_raw_evidence(self):
        result, events, evidence = self.run_fresh_stub()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(events, ["register", "prebuild", "inventory", "diagnostic", "remove"])
        for name in ("reference-unscored.json", "optimized-reference.trace", "prebuild.log",
                     "diagnostic.log", "simulators.json", "fresh-status.txt", "compiled-probe-cache"):
            self.assertIn(name, evidence)

    def test_build_or_identity_failure_never_attempts_simulator_or_profiler(self):
        for failure in ("build", "revision", "sources"):
            with self.subTest(failure=failure):
                result, events, evidence = self.run_fresh_stub(failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("inventory", events)
                self.assertNotIn("diagnostic", events)
                self.assertIn("fresh-status.txt", evidence)

    def test_profiler_failure_preserves_raw_report_and_fails_job(self):
        result, events, evidence = self.run_fresh_stub("trace")
        self.assertEqual(result.returncode, 12)
        self.assertIn("reference-unscored.json", evidence)
        self.assertIn("diagnostic.log", evidence)



if __name__ == "__main__":
    unittest.main()
