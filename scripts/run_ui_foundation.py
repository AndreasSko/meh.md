#!/usr/bin/env python3
"""One bounded Debug-iCloud build and compiled-inventory UI run per fresh lane."""

import argparse
import json
import os
from pathlib import Path
import signal
import sys
import threading
import subprocess
import tempfile
import time

from check_ui_foundation_results import (
    check,
    discovered,
    expected_cases,
)

ROOT = Path(__file__).resolve().parent.parent
NATIVE_RETRY_ARGUMENTS = [
    "-retry-tests-on-failure", "-test-iterations", "2",
    "-test-repetition-relaunch-enabled", "YES",
]


def report_retries(manifest, retried):
    manifest["retriedTests"] = sorted(retried)
    for identifier, results in retried.items():
        print(
            f"::warning title=UI test repeated by native retry::"
            f"{identifier}: {' -> '.join(results)}",
            flush=True,
        )

# Harness watchdogs stop stuck tools; scored performance probes judge app speed.
WATCHDOG_SECONDS = {
    "startup": 600,
    "build": 1800,
    "discovery": 300,
    "test": 6600,
    "json_export": 120,
    "attachment_export": 300,
    "cleanup": 60,
}


def bounded(command, timeout, log):
    """Own a process group; kill all descendants on timeout or interruption."""
    with Path(log).open("wb") as stream:
        process = subprocess.Popen(
            command, cwd=ROOT, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, start_new_session=True,
        )

        def tee():
            for chunk in iter(lambda: process.stdout.read1(65536), b""):
                stream.write(chunk)
                stream.flush()
                sys.stdout.buffer.write(chunk)
                sys.stdout.buffer.flush()

        reader = threading.Thread(target=tee, daemon=True)
        reader.start()
        try:
            status = process.wait(timeout=timeout)
            reader.join(timeout=5)
            if reader.is_alive():
                raise RuntimeError("Command descendants kept the log stream open")
        except BaseException:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait(timeout=5)
            reader.join(timeout=5)
            raise
        finally:
            process.stdout.close()

    if status:
        raise RuntimeError(f"Command exited {status}; see {log}")
    return Path(log).read_text()


def select_simulator(inventory, platform):
    """Select the existing CI device policy, reporting unavailable prerequisites."""
    runtimes = [
        r
        for r in inventory["runtimes"]
        if r.get("isAvailable")
        and r["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-")
        and str(r["version"]).startswith("27.")
    ]
    if not runtimes:
        raise ValueError("An available iOS 27 simulator runtime is required")
    runtime = max(runtimes, key=lambda r: tuple(map(int, r["version"].split("."))))
    supported = {d["identifier"] for d in runtime.get("supportedDeviceTypes", [])}
    devices = [
        d
        for d in inventory["devicetypes"]
        if (
            d["name"] == "iPhone 12 Pro Max"
            if platform == "iphone"
            else d["name"].startswith("iPad")
        )
        and (not supported or d["identifier"] in supported)
    ]
    if not devices:
        required = "iPhone 12 Pro Max" if platform == "iphone" else "iPad"
        raise ValueError(
            f"No {required} device type supported by {runtime['identifier']}"
        )
    device = sorted(devices, key=lambda d: d["identifier"])[0]
    return runtime, device


def finalize(manifest, validation_complete, write_manifest):
    """Record cleanup failure without replacing an earlier run exception."""
    manifest["verified"] = validation_complete and not manifest.get("cleanupErrors")
    write_manifest()
    if manifest.get("cleanupErrors") and not manifest.get("error"):
        raise RuntimeError(
            "Owned simulator cleanup failed: " + "; ".join(manifest["cleanupErrors"])
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("platform", choices=["iphone", "ipad", "mac"])
    parser.add_argument("--evidence-root", required=True, type=Path)
    args = parser.parse_args()

    def interrupted(signum, frame):
        raise RuntimeError(f"Interrupted by signal {signum}")

    signal.signal(signal.SIGTERM, interrupted)
    if args.platform == "mac" and (
        os.environ.get("GITHUB_ACTIONS") != "true"
        or os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted"
    ):
        parser.error("Mac UI requires a GitHub-hosted guest")
    evidence = args.evidence_root.resolve()
    evidence.mkdir(parents=True, exist_ok=False)
    metrics = {}
    manifest = {
        "platform": args.platform,
        "scheme": "meh.md CI",
        "configuration": "Debug-iCloud",
        "maxRetriesPerTest": 1,
        "watchdogSeconds": WATCHDOG_SECONDS,
        "verified": False,
    }
    udid = None
    validation_complete = False

    def stage(name, command, timeout):
        started = time.monotonic()
        print(f"START {name} deadline={timeout}s", flush=True)
        try:
            return bounded(command, timeout, evidence / (name + ".log"))
        finally:
            metrics[name] = round(time.monotonic() - started, 3)
            print(f"END {name} elapsed={metrics[name]:.3f}s", flush=True)

    def write_manifest():
        manifest["stageSeconds"] = metrics
        (evidence / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")

    with tempfile.TemporaryDirectory(prefix="meh-ui-foundation-") as temporary:
        work = Path(temporary)
        try:
            manifest["gitSHA"] = stage(
                "git-head", ["git", "rev-parse", "HEAD"], 30
            ).strip()
            manifest["gitTree"] = stage(
                "git-tree", ["git", "rev-parse", "HEAD^{tree}"], 30
            ).strip()
            manifest["gitStatus"] = stage(
                "git-status",
                ["git", "-c", "core.fsmonitor=false", "status", "--porcelain"],
                30,
            )
            if (
                os.environ.get("GITHUB_ACTIONS") == "true"
                and manifest["gitStatus"].strip()
            ):
                raise ValueError("Hosted CI requires a clean checkout")
            version = stage("toolchain", ["xcodebuild", "-version"], 30)
            manifest["toolchain"] = version
            if not version.startswith("Xcode 27"):
                raise ValueError("Xcode 27 required")
            plan_name = {"iphone": "CIIPhone", "ipad": "CIIPad", "mac": "CIMac"}[
                args.platform
            ]
            plan_path = ROOT / "TestPlans" / (plan_name + ".xctestplan")
            manifest["testPlan"] = plan_name
            if args.platform == "mac":
                os_version = stage(
                    "os-version", ["sw_vers", "-productVersion"], 30
                ).strip()
                if not os_version.startswith("27."):
                    raise ValueError("macOS 27 required")
                destination = "platform=macOS"
                signing = [
                    "CODE_SIGNING_ALLOWED=YES",
                    "CODE_SIGN_IDENTITY=-",
                    "CODE_SIGN_STYLE=Manual",
                    "DEVELOPMENT_TEAM=",
                    "CODE_SIGN_ENTITLEMENTS=",
                    "PROVISIONING_PROFILE_SPECIFIER=",
                ]
            else:
                inventory = json.loads(
                    stage(
                        "simulator-inventory", ["xcrun", "simctl", "list", "--json"], 30
                    )
                )
                runtime, device = select_simulator(inventory, args.platform)
                udid = stage(
                    "simulator-create",
                    [
                        "xcrun",
                        "simctl",
                        "create",
                        "MehCIFoundation-" + work.name,
                        device["identifier"],
                        runtime["identifier"],
                    ],
                    30,
                ).strip()
                manifest["simulator"] = {
                    "udid": udid,
                    "runtime": runtime,
                    "deviceType": device,
                }
                stage("simulator-boot", ["xcrun", "simctl", "boot", udid], 60)
                stage(
                    "startup",
                    ["xcrun", "simctl", "bootstatus", udid, "-b"],
                    WATCHDOG_SECONDS["startup"],
                )
                destination = "platform=iOS Simulator,id=" + udid
                signing = ["CODE_SIGNING_ALLOWED=NO"]
            common = [
                "-project",
                str(ROOT / "meh.md.xcodeproj"),
                "-scheme",
                "meh.md CI",
                "-configuration",
                "Debug-iCloud",
                "-destination",
                destination,
                "-derivedDataPath",
                str(work / "build"),
            ]
            stage(
                "build",
                [
                    "xcodebuild",
                    "build-for-testing",
                    *common,
                    "-testPlan",
                    plan_name,
                    *signing,
                ],
                WATCHDOG_SECONDS["build"],
            )
            products = work / "build/Build/Products"
            runs = list(products.glob("*.xctestrun"))
            if len(runs) != 1:
                raise ValueError(f"Expected one platform xctestrun, got {runs}")
            # Enumerate and execute the same native platform-plan run without
            # rewriting selection, capture settings, parallelism or timeouts.
            enumeration = evidence / "compiled-tests.json"
            stage(
                "discovery",
                [
                    "xcodebuild",
                    "test-without-building",
                    "-xctestrun",
                    str(runs[0]),
                    "-destination",
                    destination,
                    "-enumerate-tests",
                    "-test-enumeration-style",
                    "flat",
                    "-test-enumeration-format",
                    "json",
                    "-test-enumeration-output-path",
                    str(enumeration),
                ],
                WATCHDOG_SECONDS["discovery"],
            )
            compiled = discovered(json.loads(enumeration.read_text()), plan_name)
            expected = expected_cases(json.loads(plan_path.read_text()), compiled)
            if compiled != expected:
                raise ValueError("Compiled platform selection differs from its plan")
            manifest["expectedTests"] = sorted(expected)
            (evidence / "expected-tests.json").write_text(
                json.dumps(sorted(expected), indent=2) + "\n"
            )
            (evidence / "platform.xctestrun").write_bytes(runs[0].read_bytes())
            result = evidence / "ui.xcresult"
            test_error = None
            try:
                stage(
                    "test",
                    [
                        "xcodebuild",
                        "test-without-building",
                        "-xctestrun",
                        str(runs[0]),
                        "-destination",
                        destination,
                        *NATIVE_RETRY_ARGUMENTS,
                        "-collect-test-diagnostics",
                        "never",
                        "-resultBundlePath",
                        str(result),
                    ],
                    WATCHDOG_SECONDS["test"],
                )
            except (RuntimeError, subprocess.TimeoutExpired) as error:
                test_error = error
            export_errors = []
            for kind in ["summary", "tests"]:
                try:
                    output = stage(
                        "export-" + kind,
                        [
                            "xcrun",
                            "xcresulttool",
                            "get",
                            "test-results",
                            kind,
                            "--path",
                            str(result),
                        ],
                        WATCHDOG_SECONDS["json_export"],
                    )
                    (evidence / (kind + ".json")).write_text(output)
                except Exception as error:
                    export_errors.append(f"{kind}: {error}")
            try:
                stage(
                    "export-attachments",
                    [
                        "xcrun",
                        "xcresulttool",
                        "export",
                        "attachments",
                        "--path",
                        str(result),
                        "--output-path",
                        str(evidence / "attachments"),
                    ],
                    WATCHDOG_SECONDS["attachment_export"],
                )
            except Exception as error:
                manifest.setdefault("diagnosticWarnings", []).append(
                    f"Attachment export failed: {error}"
                )
                print(f"WARNING: attachment export failed: {error}", flush=True)
            if export_errors:
                manifest["exportErrors"] = export_errors
            if test_error:
                raise test_error
            if export_errors:
                raise RuntimeError("Result export failed: " + "; ".join(export_errors))
            summary = json.loads((evidence / "summary.json").read_text())
            retried = check(
                summary,
                json.loads((evidence / "tests.json").read_text()),
                expected,
                args.platform,
            )
            report_retries(manifest, retried)
            validation_complete = True
        except BaseException as error:
            manifest["error"] = f"{type(error).__name__}: {error}"
            raise
        finally:
            if udid:
                for action in ["shutdown", "delete"]:
                    try:
                        stage(
                            "simulator-" + action,
                            ["xcrun", "simctl", action, udid],
                            WATCHDOG_SECONDS["cleanup"],
                        )
                    except Exception as error:
                        manifest.setdefault("cleanupErrors", []).append(str(error))
            finalize(manifest, validation_complete, write_manifest)
    print("PASS: compiled inventory and exact UI results verified")


if __name__ == "__main__":
    main()
