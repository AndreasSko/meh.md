#!/usr/bin/env python3
"""Append disposable markers and verify live Mac/iPhone sync and outage recovery."""

import argparse
import json
import plistlib
import re
import subprocess
import tempfile
import uuid
from pathlib import Path


def test_plan(products: Path, token: str) -> Path:
    sources = list(products.glob("meh.md iCloud Dev_*.xctestrun"))
    if len(sources) != 1:
        raise ValueError(f"Expected one iCloud Dev xctestrun in {products}")
    plan = plistlib.loads(sources[0].read_bytes())
    if "TestConfigurations" in plan:
        targets = [target for config in plan["TestConfigurations"]
                   for target in config["TestTargets"]
                   if target.get("BlueprintName") == "meh.mdUITests"]
    else:
        targets = [plan["meh.mdUITests"]]
    if not targets:
        raise ValueError("No meh.mdUITests target in test plan")
    for target in targets:
        for key in ("EnvironmentVariables", "TestingEnvironmentVariables"):
            target.setdefault(key, {})["MEH_ICLOUD_UI_RUN"] = token
        target["ParallelizationEnabled"] = False
    destination = products / (token + ".xctestrun")
    destination.write_bytes(plistlib.dumps(plan))
    return destination


def run() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mac-products", type=Path, required=True)
    parser.add_argument("--phone-products", type=Path, required=True)
    parser.add_argument("--phone", required=True, help="Physical iPhone UDID")
    parser.add_argument("--output-dir", type=Path)
    args = parser.parse_args()
    token = "device-" + uuid.uuid4().hex[:12]
    output = args.output_dir or Path(tempfile.mkdtemp(prefix="meh-cloud-ui-"))
    output.mkdir(parents=True, exist_ok=True)
    plans = {}
    report = {"token": token, "passed": []}
    phases = [
        ("mac", "test01MacPublishesFromNormalEditor"),
        ("phone", "test02PhoneJoinsAndRepliesAfterRelaunch"),
        ("mac", "test03MacReceivesPhoneReply"),
        ("mac", "test04MacEditsDuringOutageAndRelaunches"),
        ("phone", "test05PhoneEditsDuringOutageAndRelaunches"),
        ("mac", "test06MacReconnects"),
        ("phone", "test07PhoneReconnectsAndMerges"),
        ("mac", "test08MacReceivesMergedOfflineEdits"),
    ]
    try:
        plans["mac"] = test_plan(args.mac_products.resolve(), token)
        plans["phone"] = test_plan(args.phone_products.resolve(), token)
        print(f"Run: {token}\nEvidence: {output}", flush=True)
        for device, method in phases:
            destination = ("platform=macOS,arch=arm64" if device == "mac"
                           else f"id={args.phone},arch=arm64")
            print(f"Starting {device}: {method}", flush=True)
            with (output / (method + ".log")).open("w") as log:
                subprocess.run([
                    "xcodebuild", "test-without-building", "-xctestrun",
                    str(plans[device]), "-destination", destination,
                    "-parallel-testing-enabled", "NO",
                    "-collect-test-diagnostics", "never",
                    f"-only-testing:meh.mdUITests/ICloudDevelopmentUITests/{method}",
                    "-resultBundlePath", str(output / (method + ".xcresult")),
                ], check=True, stdout=log, stderr=subprocess.STDOUT)
            report["passed"].append(method)
            (output / "verification.json").write_text(json.dumps(report, indent=2) + "\n")
            print(f"Passed: {method}", flush=True)
        digests = []
        for _, method in phases[-2:]:
            attachments = output / (method + "-attachments")
            subprocess.run([
                "xcrun", "xcresulttool", "export", "attachments", "--path",
                str(output / (method + ".xcresult")), "--output-path",
                str(attachments),
            ], check=True, stdout=subprocess.DEVNULL)
            matches = set()
            for path in attachments.glob("*.txt"):
                value = path.read_text().strip()
                if re.fullmatch(r"converged-note-sha256:[0-9a-f]{64}", value):
                    matches.add(value.split(":")[1])
            if len(matches) != 1:
                raise RuntimeError(f"Missing unique note digest for {method}")
            digests.append(matches.pop())
        if digests[0] != digests[1]:
            raise RuntimeError("Mac and iPhone note text did not converge exactly")
        report["convergedTextSHA256"] = digests[0]
        (output / "verification.json").write_text(json.dumps(report, indent=2) + "\n")
        print("Verified identical final note text on Mac and iPhone", flush=True)
    finally:
        for plan in plans.values():
            plan.unlink(missing_ok=True)


if __name__ == "__main__":
    run()
