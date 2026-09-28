#!/usr/bin/env python3
"""Run a signed lab build only on an explicitly dedicated iOS simulator.

The lab shares the normal iCloud Dev bundle ID. This runner refuses an
installed normal Dev app and leaves the lab installed for follow-up phases.
It never erases, resets, uninstalls, or boots a simulator.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time
import uuid

from run_notebook_lab import BUNDLE, command, verify


def check_simulator(device):
    listing = json.loads(command("xcrun", "simctl", "list", "-j", "devices").stdout)
    for devices in listing["devices"].values():
        for candidate in devices:
            if candidate.get("udid") == device:
                if candidate.get("state") != "Booted":
                    raise ValueError("The dedicated simulator must already be booted")
                return
    raise ValueError("Unknown simulator UDID")


def check_existing_app(device):
    existing = subprocess.run(
        ["xcrun", "simctl", "get_app_container", device, BUNDLE, "app"],
        capture_output=True, text=True, timeout=30,
    )
    if existing.returncode == 0:
        verify(Path(existing.stdout.strip()), platform="iPhoneSimulator")
        return
    reason = existing.stderr.lower()
    if not any(value in reason for value in (
        "not installed", "no such app", "no such file", "not found"
    )):
        raise RuntimeError("Could not establish whether Dev is installed")


def terminate_lab(device):
    subprocess.run(
        ["xcrun", "simctl", "terminate", device, BUNDLE],
        capture_output=True, timeout=15,
    )


def lab_report_path(device, run, phase):
    data = command(
        "xcrun", "simctl", "get_app_container", device, BUNDLE, "data"
    ).stdout.decode().strip()
    if not data:
        raise RuntimeError("Simulator did not return the lab data container")
    # Read only the exact per-run lab report. Never enumerate app data.
    return (Path(data) / "Documents" / "SyncLab" / run.lower()
            / phase / "report.json")


def ensure_fresh_phase(report_path, phase):
    if phase in ("account", "exchange", "publish") and report_path.parent.parent.exists():
        raise RuntimeError("A fresh lab run ID is required for the initial phase")
    if report_path.exists():
        raise RuntimeError("This lab phase already has a report")


def read_lab_report(report_path, run, phase):
    if not report_path.exists():
        return None
    try:
        candidate = json.loads(report_path.read_text())
    except json.JSONDecodeError:
        return None  # The app may still be replacing the file.
    if (candidate.get("runID", "").lower() != run
            or candidate.get("phase") != phase):
        raise RuntimeError("Unexpected lab report identity or phase")
    return candidate


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("simulator", type=uuid.UUID, help="Exact dedicated simulator UDID")
    parser.add_argument("evidence", type=Path)
    parser.add_argument("--phase", choices=[
        "account", "exchange", "publish", "receive", "edit", "verify"
    ], required=True)
    parser.add_argument("--allow-development-cloud", action="store_true")
    parser.add_argument(
        "--dedicated-simulator", action="store_true",
        help="Acknowledge that this installs the lab under the normal Dev bundle ID",
    )
    parser.add_argument("--run-id", type=uuid.UUID)
    parser.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args()
    if not args.allow_development_cloud or not args.dedicated_simulator:
        parser.error("Explicit Development-cloud and dedicated-simulator flags are required")
    if not 10 <= args.timeout <= 300:
        parser.error("Timeout must be between 10 and 300 seconds")
    if args.phase in ("receive", "edit", "verify") and args.run_id is None:
        parser.error("Follow-up phases require the original --run-id")

    app = args.app.resolve()
    _, symbol_file = verify(app, platform="iPhoneSimulator")
    device = str(args.simulator).upper()
    check_simulator(device)
    check_existing_app(device)
    args.evidence.mkdir(parents=True, exist_ok=False)
    run = str(args.run_id or uuid.uuid4())
    metadata = {
        "run_id": run,
        "phase": args.phase,
        "simulator": device,
        "binary_sha256": hashlib.sha256(symbol_file.read_bytes()).hexdigest(),
        "scope": "Dedicated iOS Simulator; fictional Development CloudKit lab only",
    }
    (args.evidence / "environment.json").write_text(json.dumps(metadata, indent=2) + "\n")
    environment = os.environ.copy()
    environment.update({
        "SIMCTL_CHILD_MEH_SYNC_LAB_ALLOW_DEVELOPMENT": "1",
        "SIMCTL_CHILD_MEH_SYNC_LAB_RUN": run,
        "SIMCTL_CHILD_MEH_SYNC_LAB_PHASE": args.phase,
    })
    installed_lab = False
    result = None
    report_path = None
    try:
        command("xcrun", "simctl", "install", device, str(app))
        installed_lab = True
        report_path = lab_report_path(device, run, args.phase)
        ensure_fresh_phase(report_path, args.phase)
        launch = subprocess.run([
            "xcrun", "simctl", "launch", "--terminate-running-process",
            device, BUNDLE,
        ], env=environment, capture_output=True, timeout=30)
        (args.evidence / "launch.log").write_bytes(
            launch.stdout + launch.stderr
        )
        launch.check_returncode()
        deadline = time.monotonic() + args.timeout
        while time.monotonic() < deadline:
            result = read_lab_report(report_path, run, args.phase) or result
            if result is not None and result.get("status") != "running":
                break
            time.sleep(0.5)
        if result is None or result.get("status") == "running":
            raise TimeoutError("Bounded simulator lab run did not finish")
        print(json.dumps({
            key: value for key, value in result.items() if key != "events"
        }, indent=2))
        if result.get("status") != "passed":
            raise RuntimeError("Lab reported failure; see report.json")
    finally:
        try:
            if report_path is not None:
                result = read_lab_report(report_path, run, args.phase) or result
        finally:
            try:
                if result is not None:
                    (args.evidence / "report.json").write_text(
                        json.dumps(result, indent=2) + "\n"
                    )
            finally:
                if installed_lab:
                    terminate_lab(device)


if __name__ == "__main__":
    main()
