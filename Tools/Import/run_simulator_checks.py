#!/usr/bin/env python3
"""Check native Markdown import on an explicitly disposable iPhone simulator."""

import argparse
import json
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path
from urllib.parse import urlsplit


BUNDLE_ID = "de.andreas-sk.meh-md.icloud-dev"


def command(*arguments: str) -> str:
    return subprocess.check_output(arguments, text=True).strip()


def test_targets(plan: dict) -> list:
    if "TestConfigurations" in plan:
        return [
            target
            for configuration in plan["TestConfigurations"]
            for target in configuration["TestTargets"]
        ]
    return [
        target for target in plan.values()
        if isinstance(target, dict) and target.get("BlueprintName")
    ]


def wait_for_service(server: subprocess.Popen, log: Path) -> str:
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if server.poll() is not None:
            raise RuntimeError(f"Fixture server exited: {log.read_text()}")
        match = re.search(r"http://127\.0\.0\.1:\d+", log.read_text())
        if match:
            return match.group()
        time.sleep(0.05)
    raise RuntimeError("Fixture server did not start within 15 seconds")


def run() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--products-dir", type=Path, required=True)
    parser.add_argument(
        "--simulator", required=True,
        help="Explicit UDID of a disposable iPhone simulator (never 'booted')",
    )
    parser.add_argument("--output-dir", type=Path)
    args = parser.parse_args()
    products = args.products_dir.resolve()
    sources = list(products.glob("meh.md*.xctestrun"))
    apps = list(products.glob("*iphonesimulator/meh.md iCloud Dev.app"))
    if len(sources) != 1 or len(apps) != 1:
        parser.error("Expected one iCloud Dev app/xctestrun after build-for-testing")
    info = plistlib.loads((apps[0] / "Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != BUNDLE_ID:
        parser.error("Only the iCloud Dev application may run these checks")

    inventory = json.loads(command("xcrun", "simctl", "list", "devices", "--json"))
    devices = [device for values in inventory["devices"].values() for device in values]
    device = next((d for d in devices if d["udid"] == args.simulator), None)
    if device is None or not device.get("isAvailable"):
        parser.error("Supply the UDID of an available disposable iPhone simulator")
    if "iPhone" not in device.get("deviceTypeIdentifier", ""):
        parser.error("The native picker checks require an iPhone simulator")

    token = uuid.uuid4().hex[:12]
    fixture_name = "Import Regression " + token
    workspace = "import-ui-" + token
    output = (args.output_dir or Path(tempfile.mkdtemp(prefix="meh-import-ui-"))).resolve()
    output.mkdir(parents=True, exist_ok=True)
    plan = plistlib.loads(sources[0].read_bytes())
    target = next(
        (t for t in test_targets(plan) if t["BlueprintName"] == "meh.mdUITests"),
        None,
    )
    if target is None:
        parser.error("The build does not contain meh.mdUITests")
    booted_here = device["state"] != "Booted"
    fixture = None
    server = None
    test_run = products / (workspace + ".xctestrun")
    print(f"Simulator: {args.simulator}\nEvidence: {output}", flush=True)
    try:
        if booted_here:
            command("xcrun", "simctl", "boot", args.simulator)
        command("xcrun", "simctl", "bootstatus", args.simulator, "-b")
        command("xcrun", "simctl", "install", args.simulator, str(apps[0]))
        container = Path(command(
            "xcrun", "simctl", "get_app_container", args.simulator, BUNDLE_ID, "data"
        ))
        source_directory = container / "Documents" / fixture_name
        source_directory.mkdir(parents=True, exist_ok=False)
        fixture = source_directory
        (fixture / "First.md").write_text("# First\n\nFictional first note.\n")
        (fixture / "Second.md").write_text("# Second\n\nFictional second note.\n")
        (fixture / "Invalid.md").write_bytes(b"# Invalid\n\n\xff\xfe\x80\n")
        (fixture / "Folder").mkdir()
        (fixture / "Folder" / "Child.md").write_text("# Child\n\nFictional child note.\n")

        server_script = Path(__file__).resolve().parents[1] / "LocalSyncServer" / "local_sync_server.py"
        with tempfile.TemporaryDirectory(prefix="meh-import-server-") as server_data:
            with (output / "server.log").open("w") as server_log:
                server = subprocess.Popen(
                    [sys.executable, str(server_script), "--data-dir", server_data, "--port", "0"],
                    stdout=server_log, stderr=subprocess.STDOUT,
                )
                service = wait_for_service(server, output / "server.log")
                environment = {
                    "MEH_IMPORT_TEST_FIXTURE": fixture_name,
                    "MEH_IMPORT_TEST_WORKSPACE": workspace,
                    "MEH_IMPORT_TEST_PORT": str(urlsplit(service).port),
                }
                for key in ["EnvironmentVariables", "TestingEnvironmentVariables"]:
                    target.setdefault(key, {}).update(environment)
                target["ParallelizationEnabled"] = False
                target["OnlyTestIdentifiers"] = ["NotebookImportUITests"]
                test_run.write_bytes(plistlib.dumps(plan))
                result = output / "import.xcresult"
                with (output / "import.log").open("w") as log:
                    subprocess.run([
                        "xcodebuild", "test-without-building", "-xctestrun", str(test_run),
                        "-destination", f"id={args.simulator}",
                        "-parallel-testing-enabled", "NO",
                        "-collect-test-diagnostics", "never",
                        "-only-testing:meh.mdUITests/NotebookImportUITests",
                        "-resultBundlePath", str(result),
                    ], stdout=log, stderr=subprocess.STDOUT, check=True, timeout=600)
                summary = json.loads(command(
                    "xcrun", "xcresulttool", "get", "test-results", "summary",
                    "--path", str(result),
                ))
                if summary.get("passedTests") != 3 or summary.get("skippedTests") != 0:
                    raise RuntimeError("Expected three passing import tests with no skips")
                command(
                    "xcrun", "xcresulttool", "export", "attachments", "--path", str(result),
                    "--output-path", str(output / "screenshots"),
                )
                (output / "verification.json").write_text(json.dumps({
                    "simulator": args.simulator,
                    "workspace": workspace,
                    "fixture": fixture_name,
                    "checks": ["multiple-files", "cancel-after-import", "invalid-utf8", "folder"],
                }, indent=2) + "\n")
                print("Passed all native import checks; screenshots exported.", flush=True)
            server.terminate()
            server.wait(timeout=10)
            server = None
    finally:
        if server is not None:
            server.terminate()
            try:
                server.wait(timeout=10)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()
        test_run.unlink(missing_ok=True)
        if fixture is not None:
            # XCTest can relocate the app container while reinstalling. Remove
            # only our exact unique source directory in either location.
            locations = {fixture}
            current = subprocess.run([
                "xcrun", "simctl", "get_app_container", args.simulator,
                BUNDLE_ID, "data",
            ], capture_output=True, text=True)
            if current.returncode == 0:
                locations.add(Path(current.stdout.strip()) / "Documents" / fixture_name)
            for location in locations:
                if location.exists():
                    shutil.rmtree(location)
        if booted_here:
            command("xcrun", "simctl", "shutdown", args.simulator)


if __name__ == "__main__":
    run()
