"""Exercise the real shell launcher against fake tools, without building or UI."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


RUNNER = Path(__file__).with_name("run_editor_performance_check.sh")


def executable(path, code):
    path.write_text(f"#!{sys.executable}\n" + code)
    path.chmod(0o755)


class PerformanceLaunchEnvironmentTests(unittest.TestCase):
    def test_cached_launch_exports_requested_probe_environment_and_pid(self):
        for mode in ("source", "livePreview"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                repo = root / "repo"
                scripts = repo / "scripts"
                scripts.mkdir(parents=True)
                shutil.copyfile(RUNNER, scripts / RUNNER.name)
                sources = repo / "meh.md"
                sources.mkdir()
                (sources / "Dummy.swift").write_text("// No compilation allowed\n")
                tools = repo / "Tools" / "EditorQuoteCheck"
                tools.mkdir(parents=True)
                (tools / "Info.plist").write_text("<plist></plist>\n")
                executable(scripts / "editor_performance_app_cache.py", '''
import sys
if sys.argv[1] == "key":
    print("a" * 64)
elif sys.argv[1] != "lookup":
    raise SystemExit("Cache miss or compilation attempted")
''')
                binaries = root / "bin"
                binaries.mkdir()
                executable(binaries / "swift", '''
import sys
assert sys.argv[1:] == ["--version"], "Compilation must not run"
print("Fake Swift")
''')
                executable(binaries / "git", '''
import sys
if "rev-parse" in sys.argv:
    print("f" * 40)
elif "status" not in sys.argv:
    raise SystemExit("Unexpected git operation")
''')
                executable(binaries / "xcrun", '''
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
if args == ["--sdk", "iphonesimulator", "--show-sdk-path"]:
    print("/fake/sdk")
elif args == ["swiftc", "--version"]:
    print("Fake Swift")
elif args[:2] == ["simctl", "list"]:
    runtime = "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
    print(json.dumps({"runtimes": [{"identifier": runtime, "version": "27.0",
                                   "isAvailable": True}],
                      "devices": {runtime: [{"udid": "FAKE-UDID", "isAvailable": True}]}}))
elif args[:2] == ["simctl", "get_app_container"]:
    print(os.environ["FAKE_CONTAINER"])
elif args[:2] == ["simctl", "launch"]:
    child = {key: value for key, value in os.environ.items()
             if key.startswith("SIMCTL_CHILD_")}
    Path(os.environ["FAKE_LAUNCH_ENV"]).write_text(json.dumps(child))
    documents = Path(os.environ["FAKE_CONTAINER"]) / "Documents"
    documents.mkdir(parents=True, exist_ok=True)
    fixture = b"fictional fixture"
    (documents / "large-note-fixture.md").write_bytes(fixture)
    def requested(name, default):
        return child.get("SIMCTL_CHILD_EDITOR_PERFORMANCE_" + name, default)
    report = {"scenario": "large-note", "source_and_selection_preserved": True,
              "utf8_bytes": len(fixture), "host": requested("HOST", "editor"),
              "mode": requested("MODE", "livePreview"),
              "requested_kb": int(requested("BLOCKS", "500")),
              "context": requested("CONTEXT", "standard"),
              "shape": requested("SHAPE", "standard"),
              "measurements": {"typing_synchronous_ms": [1.0]}}
    (documents / "performance.json").write_text(json.dumps(report))
    print("de.andreas-sk.meh-md.editor-quote-check: 4242")
elif args[:2] not in (["simctl", "bootstatus"], ["simctl", "install"],
                      ["simctl", "terminate"]):
    raise SystemExit("Unexpected real tool request: " + repr(args))
''')
                observed = root / "launch-environment.json"
                pid_path = root / "launch.pid"
                report_path = root / "export.json"
                environment = {key: value for key, value in os.environ.items()
                               if not key.startswith(("EDITOR_PERFORMANCE_", "SIMCTL_CHILD_"))}
                environment.update(
                    PATH=f"{binaries}:{os.environ['PATH']}",
                    FAKE_CONTAINER=str(root / "container"), FAKE_LAUNCH_ENV=str(observed),
                    EDITOR_PERFORMANCE_APP_CACHE=str(root / "cache"),
                    EDITOR_PERFORMANCE_REQUIRE_CACHED_APP="1",
                    EDITOR_PERFORMANCE_HOST="notebook", EDITOR_PERFORMANCE_CONTEXT="mixed",
                    EDITOR_PERFORMANCE_SHAPE="nearby-table",
                    EDITOR_PERFORMANCE_START_DELAY_SECONDS="10",
                    EDITOR_PERFORMANCE_SCROLL_ROUNDS="0",
                    EDITOR_PERFORMANCE_PRESERVE_FAILED_HOST="1",
                    EDITOR_PERFORMANCE_LAUNCH_PID_FILE=str(pid_path))
                result = subprocess.run(
                    ["bash", str(scripts / RUNNER.name), "FAKE-UDID", "working-tree",
                     mode, "50", str(report_path), "large-note"],
                    env=environment, capture_output=True, text=True, timeout=15)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(json.loads(observed.read_text()), {
                    "SIMCTL_CHILD_EDITOR_PERFORMANCE_START_DELAY_SECONDS": "10",
                    "SIMCTL_CHILD_EDITOR_PERFORMANCE_CONTEXT": "mixed",
                    "SIMCTL_CHILD_EDITOR_PERFORMANCE_SHAPE": "nearby-table",
                    "SIMCTL_CHILD_EDITOR_PERFORMANCE_HOST": "notebook",
                    "SIMCTL_CHILD_EDITOR_PERFORMANCE_PRESERVE_FAILED_HOST": "1",
                    "SIMCTL_CHILD_EDITOR_PERFORMANCE_CHECK": "1",
                    "SIMCTL_CHILD_EDITOR_PERFORMANCE_SCROLL_ROUNDS": "0",
                    "SIMCTL_CHILD_EDITOR_PERFORMANCE_BLOCKS": "50",
                    "SIMCTL_CHILD_EDITOR_PERFORMANCE_MODE": mode,
                })
                self.assertEqual(pid_path.read_text().strip(), "4242")
                report = json.loads(report_path.read_text())
                self.assertEqual((report["host"], report["mode"], report["requested_kb"],
                                  report["context"], report["shape"]),
                                 ("notebook", mode, 50, "mixed", "nearby-table"))
                self.assertEqual(report["simulator_udid"], "FAKE-UDID")
                self.assertEqual(report_path.with_name("export-fixture.md").read_bytes(),
                                 b"fictional fixture")


if __name__ == "__main__":
    unittest.main()
