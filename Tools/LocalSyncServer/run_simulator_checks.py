#!/usr/bin/env python3
"""Run the three native sync phases with a fresh, isolated workspace."""

import argparse
import json
import plistlib
import subprocess
import tempfile
import uuid
from pathlib import Path


def verify_copies(devices: list, workspace: str) -> list:
    expected = "From iPhone: café 👋🏽 日本語\nFrom iPad: naïve 世界\n".encode()
    copies = []
    for name, device in devices:
        command = [
            "xcrun", "simctl", "get_app_container", device,
            "de.andreas-sk.meh-md", "data",
        ]
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode and "Shutdown" in result.stderr:
            # XCTest may shut down its previous destination when switching
            # between devices. Boot only the explicitly supplied simulator.
            subprocess.run(["xcrun", "simctl", "boot", device], check=True)
            subprocess.run(
                ["xcrun", "simctl", "bootstatus", device, "-b"],
                check=True, stdout=subprocess.DEVNULL,
            )
            result = subprocess.run(command, capture_output=True, text=True)
        result.check_returncode()
        path = Path(result.stdout.strip()) / "Documents" / "SyncWorkspaces" / workspace / "note.md"
        actual = path.read_bytes()
        if actual != expected:
            raise RuntimeError(f"{name} Markdown copy does not match the expected UTF-8 bytes")
        copies.append({"device": name, "path": str(path), "bytes": len(actual)})
    return copies


def run() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--products-dir", type=Path, required=True)
    parser.add_argument("--phone", required=True, help="iPhone simulator UDID")
    parser.add_argument("--pad", required=True, help="iPad simulator UDID")
    parser.add_argument("--output-dir", type=Path)
    args = parser.parse_args()
    workspace = "ui-" + uuid.uuid4().hex[:12]
    output = args.output_dir or Path(tempfile.mkdtemp(prefix="meh-sync-ui-"))
    output.mkdir(parents=True, exist_ok=True)
    sources = list(args.products_dir.glob("meh.md_*.xctestrun"))
    if len(sources) != 1:
        parser.error("Expected one meh.md xctestrun file after build-for-testing")
    plan = plistlib.loads(sources[0].read_bytes())
    for configuration in plan["TestConfigurations"]:
        for target in configuration["TestTargets"]:
            if target["BlueprintName"] == "meh.mdUITests":
                for key in ["EnvironmentVariables", "TestingEnvironmentVariables"]:
                    target.setdefault(key, {})["MEH_SYNC_TEST_WORKSPACE"] = workspace
                target["ParallelizationEnabled"] = False
    test_run = args.products_dir / (workspace + ".xctestrun")
    test_run.write_bytes(plistlib.dumps(plan))
    print(f"Workspace: {workspace}\nEvidence: {output}", flush=True)
    phases = [
        ("phone-publish", args.phone, "test01PublishFromPhone"),
        ("pad-reply", args.pad, "test02ReceiveAndReplyFromPad"),
        ("phone-reopen", args.phone, "test03ReceiveReplyOnPhoneAndRestart"),
    ]
    try:
        for name, device, method in phases:
            command = [
                "xcodebuild", "test-without-building", "-xctestrun", str(test_run),
                "-destination", f"id={device}", "-parallel-testing-enabled", "NO",
                f"-only-testing:meh.mdUITests/LocalSyncUITests/{method}",
                "-resultBundlePath", str(output / (name + ".xcresult")),
            ]
            with (output / (name + ".log")).open("w") as log:
                subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
            print(f"Passed: {name}", flush=True)
        copies = verify_copies([("phone", args.phone), ("pad", args.pad)], workspace)
        report = {"workspace": workspace, "phases": [p[0] for p in phases], "copies": copies}
        (output / "verification.json").write_text(json.dumps(report, indent=2) + "\n")
        print(f"Both Markdown copies match all {copies[0]['bytes']} UTF-8 bytes.", flush=True)
    finally:
        test_run.unlink(missing_ok=True)


if __name__ == "__main__":
    run()
