#!/usr/bin/env python3
"""Run one isolated iOS Dev lab phase, then restore normal Dev without launch."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import uuid

from run_notebook_lab import BUNDLE, verify


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("restore_app", type=Path)
    parser.add_argument("device")
    parser.add_argument("evidence", type=Path)
    parser.add_argument("--phase", choices=["account", "receive", "verify"], required=True)
    parser.add_argument("--run-id", type=uuid.UUID, required=True)
    parser.add_argument("--allow-development-cloud", action="store_true")
    args = parser.parse_args()
    if not args.allow_development_cloud:
        parser.error("Explicit --allow-development-cloud is required")
    _, symbol_file = verify(args.app.resolve(), platform="iPhoneOS")
    _, restore_symbols = verify(args.restore_app.resolve(), platform="iPhoneOS", lab=False)
    args.evidence.mkdir(parents=True, exist_ok=False)
    run = str(args.run_id)
    environment = {
        "MEH_SYNC_LAB_ALLOW_DEVELOPMENT": "1", "MEH_SYNC_LAB_RUN": run,
        "MEH_SYNC_LAB_PHASE": args.phase,
    }
    metadata = {
        "run_id": run, "phase": args.phase,
        "binary_sha256": hashlib.sha256(symbol_file.read_bytes()).hexdigest(),
        "restore_binary_sha256": hashlib.sha256(restore_symbols.read_bytes()).hexdigest(),
        "restored": False,
    }
    meta_file = args.evidence / "environment.json"
    meta_file.write_text(json.dumps(metadata, indent=2) + "\n")
    with (args.evidence / "process.log").open("wb") as log:
        try:
            subprocess.run([
                "xcrun", "devicectl", "device", "install", "app", "--device", args.device,
                "--timeout", "90", str(args.app.resolve()),
            ], stdout=log, stderr=log, check=True, timeout=100)
            subprocess.run([
                "xcrun", "devicectl", "device", "process", "launch", "--device", args.device,
                "--timeout", "120", "--console", "--terminate-existing",
                "--environment-variables", json.dumps(environment), BUNDLE,
            ], stdout=log, stderr=log, check=True, timeout=130)
        finally:
            # Installation preserves the data container. Never uninstall,
            # clear data, or launch the restored normal notebook workspace.
            restored = subprocess.run([
                "xcrun", "devicectl", "device", "install", "app", "--device", args.device,
                "--timeout", "90", str(args.restore_app.resolve()),
            ], stdout=log, stderr=log, timeout=100)
            metadata["restored"] = restored.returncode == 0
            meta_file.write_text(json.dumps(metadata, indent=2) + "\n")
            restored.check_returncode()
    reports = []
    for line in (args.evidence / "process.log").read_text(errors="replace").splitlines():
        if line.startswith("SYNC_LAB_REPORT "):
            value = json.loads(line.removeprefix("SYNC_LAB_REPORT "))
            if value.get("runID", "").lower() != run:
                raise RuntimeError("Unexpected lab report identity")
            reports.append(value)
    if not reports:
        raise RuntimeError("No lab report; normal Dev build was restored")
    result = reports[-1]
    (args.evidence / "report.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({key: value for key, value in result.items() if key != "events"}, indent=2))
    if result["status"] != "passed":
        raise RuntimeError("Lab failed; normal Dev build was restored")


if __name__ == "__main__":
    main()
