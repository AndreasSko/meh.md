#!/usr/bin/env python3
"""Install a verified, permanently isolated interactive iCloud test app."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import uuid

from run_notebook_lab import BUNDLE, command, verify

SIMULATOR_NAME = "meh.md Offline iCloud Test"


def verify_interactive_app(app, expected_run):
    executable, symbols_file = verify(app, platform="iPhoneSimulator", lab=False)
    info = plistlib.loads((app / "Info.plist").read_bytes())
    try:
        run = uuid.UUID(info["MehCloudLabRunID"])
    except (KeyError, TypeError, ValueError, AttributeError) as error:
        raise ValueError("Missing or invalid bundled test identity") from error
    if run != expected_run:
        raise ValueError("The installed test identity differs from this session")
    raw_symbols = command("nm", str(symbols_file)).stdout
    symbols = subprocess.run(
        ["xcrun", "swift-demangle"], input=raw_symbols,
        capture_output=True, check=True, timeout=60,
    ).stdout.decode()
    if ".NotebookCloudUITestScope.directoryComponent.getter" not in symbols:
        raise ValueError("Refusing an ordinary app without the compiled UI-lab guard")
    return executable, symbols_file


def check_dedicated_simulator(device):
    listing = json.loads(command("xcrun", "simctl", "list", "devices", "-j").stdout)
    matches = [entry for devices in listing["devices"].values()
               for entry in devices if entry["name"] == SIMULATOR_NAME]
    if len(matches) != 1 or matches[0]["udid"].upper() != device.upper():
        raise ValueError("Expected exactly the named dedicated test simulator")
    if matches[0]["state"] != "Booted":
        raise ValueError("The dedicated simulator must already be booted")


def check_existing_app(device, run):
    result = subprocess.run(
        ["xcrun", "simctl", "get_app_container", device, BUNDLE, "app"],
        capture_output=True, text=True, timeout=30,
    )
    if result.returncode == 0:
        verify_interactive_app(Path(result.stdout.strip()), run)
    elif not any(reason in result.stderr.lower() for reason in (
        "not installed", "no such app", "no such file", "not found"
    )):
        raise RuntimeError("Could not establish whether another app is installed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("simulator", type=uuid.UUID)
    parser.add_argument("evidence", type=Path)
    parser.add_argument("--run-id", type=uuid.UUID, required=True)
    parser.add_argument("--dedicated-simulator", action="store_true")
    parser.add_argument("--allow-development-cloud", action="store_true")
    args = parser.parse_args()
    if not args.dedicated_simulator or not args.allow_development_cloud:
        parser.error("Explicit dedicated-simulator and Development-cloud flags required")
    app = args.app.resolve()
    _, symbols = verify_interactive_app(app, args.run_id)
    device = str(args.simulator).upper()
    check_dedicated_simulator(device)
    check_existing_app(device, args.run_id)
    args.evidence.mkdir(parents=True, exist_ok=False)
    metadata = {
        "run_id": str(args.run_id), "simulator": device,
        "zone": "meh-md-notebook-lab-v2-" + str(args.run_id),
        "local_root": "CloudKitUITests/" + str(args.run_id),
        "binary_sha256": hashlib.sha256(symbols.read_bytes()).hexdigest(),
        "scope": "Fictional interactive notebook; Development CloudKit only",
    }
    (args.evidence / "environment.json").write_text(json.dumps(metadata, indent=2) + "\n")
    command("xcrun", "simctl", "install", device, str(app))
    # No launch variables: the compiled guard and bundled UUID must survive
    # user icon launches, account notifications, and later process restarts.
    launched = command("xcrun", "simctl", "launch", device, BUNDLE)
    (args.evidence / "launch.log").write_bytes(launched.stdout + launched.stderr)
    print(json.dumps(metadata, indent=2))


if __name__ == "__main__":
    main()
