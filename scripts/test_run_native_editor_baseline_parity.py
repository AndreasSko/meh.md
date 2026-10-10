"""Guard the current-only native parity runner structure."""

from pathlib import Path
import unittest


SCRIPT = Path(__file__).with_name("run_native_editor_baseline_parity.sh")


class NativeParityRunnerTests(unittest.TestCase):
    def test_runs_only_current_and_keeps_raw_evidence(self):
        source = SCRIPT.read_text()
        self.assertIn('"$evidence_root/current.xcresult"', source)
        self.assertIn('"$evidence_root/current-tests.json"', source)
        self.assertIn("check_native_editor_baseline_parity.py", source)
        self.assertNotIn("git worktree", source)
        self.assertNotIn("baseline_revision", source)
        self.assertNotIn('rm -rf "$evidence_root"', source)


if __name__ == "__main__":
    unittest.main()
