from pathlib import Path
import signal
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

from ci_process import cleanup_simulators, run_logged, terminate_process_group


class ProcessCleanupTests(unittest.TestCase):
    def test_cleanup_attempts_all_owned_devices_after_errors(self):
        with patch("ci_process.subprocess.run") as run:
            run.side_effect = [
                subprocess.TimeoutExpired("shutdown", 60),
                subprocess.CalledProcessError(1, "delete"), None, None,
            ]
            errors = cleanup_simulators(["owned-phone", "owned-pad"])
        self.assertEqual(len(errors), 2)
        self.assertTrue(all("owned-phone" in error for error in errors))
        self.assertEqual([call.args[0][2:] for call in run.call_args_list], [
            ["shutdown", "owned-phone"], ["delete", "owned-phone"],
            ["shutdown", "owned-pad"], ["delete", "owned-pad"],
        ])
        self.assertTrue(all(call.kwargs == {"check": True, "timeout": 60}
                            for call in run.call_args_list))

    def test_cleanup_never_targets_an_unowned_device(self):
        with patch("ci_process.subprocess.run") as run:
            self.assertEqual(cleanup_simulators([]), [])
            run.assert_not_called()
            self.assertEqual(cleanup_simulators(["owned-only"], timeout=30), [])
        self.assertEqual([call.args[0][-1] for call in run.call_args_list],
                         ["owned-only", "owned-only"])
        self.assertTrue(all(call.kwargs["timeout"] == 30
                            for call in run.call_args_list))

    def test_cancellation_terminates_and_reaps_owned_process_group(self):
        process = Mock(pid=123, **{"poll.return_value": None})
        process.wait.side_effect = [KeyboardInterrupt(), 0]
        with tempfile.TemporaryDirectory() as temp:
            with patch("ci_process.subprocess.Popen", return_value=process), patch("ci_process.os.killpg") as kill:
                with self.assertRaises(KeyboardInterrupt):
                    run_logged(["fixture-command"], Path(temp) / "log")
                kill.assert_called_once_with(123, signal.SIGTERM)
                self.assertEqual(process.wait.call_count, 2)

    def test_unresponsive_child_is_killed_and_completed_child_is_untouched(self):
        process = Mock(pid=124, **{"poll.return_value": None})
        process.wait.side_effect = [subprocess.TimeoutExpired("test", 10), 0]
        with patch("ci_process.os.killpg") as kill:
            terminate_process_group(process)
            self.assertEqual(kill.call_args_list[0].args, (124, signal.SIGTERM))
            self.assertEqual(kill.call_args_list[1].args, (124, signal.SIGKILL))
            process.poll.return_value = 0
            kill.reset_mock()
            terminate_process_group(process)
            kill.assert_not_called()

    def test_nonzero_exit_never_counts_as_success(self):
        process = Mock(**{"wait.return_value": 65})
        with tempfile.TemporaryDirectory() as temp:
            with patch("ci_process.subprocess.Popen", return_value=process):
                with self.assertRaises(subprocess.CalledProcessError):
                    run_logged(["fixture-command"], Path(temp) / "log")


if __name__ == "__main__":
    unittest.main()
