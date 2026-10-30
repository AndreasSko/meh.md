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
    failed,
    results,
)

ROOT = Path(__file__).resolve().parent.parent
# More failures than this point at a broken change, not a flaky test.
MAX_RETRIED_TESTS = 5


def retry_arguments(cases):
    """Select only the failed cases for one rerun in a fresh test runner."""
    return [f"-only-testing:meh.mdUITests/{case}" for case in sorted(cases)]


def in_background(function):
    """Start `function` on a thread; the returned call waits and re-raises."""
    outcome = {}

    def run():
        try:
            outcome["value"] = function()
        except BaseException as error:
            outcome["error"] = error

    thread = threading.Thread(target=run, daemon=True)
    thread.start()

    def wait():
        thread.join()
        if "error" in outcome:
            raise outcome["error"]
        return outcome.get("value")

    return wait


def report_retries(manifest, retried):
    manifest["retriedTests"] = sorted(retried)
    for identifier, results in retried.items():
        print(
            f"::warning title=UI test passed on retry::"
            f"{identifier}: {' -> '.join(results)}",
            flush=True,
        )


# Harness watchdogs stop stuck tools; scored performance probes judge app speed.
WATCHDOG_SECONDS = {
    "startup": 600,
    "build": 1800,
    "discovery": 300,
    "test": 4200,
    "nightly_test": 13200,
    "retry": 1800,
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
    # Point releases can ship device-specific runtimes (Xcode 27.1's iOS 27.1
    # only supports iPhone Duo), so fall back to the newest runtime that fits.
    runtimes.sort(
        key=lambda r: tuple(map(int, r["version"].split("."))), reverse=True
    )
    for runtime in runtimes:
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
        if devices:
            device = sorted(devices, key=lambda d: d["identifier"])[0]
            return runtime, device
    required = "iPhone 12 Pro Max" if platform == "iphone" else "iPad"
    raise ValueError(
        f"No {required} device type supported by "
        + ", ".join(r["identifier"] for r in runtimes)
    )


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
    parser.add_argument(
        "--nightly", action="store_true",
        help="Run every compiled UI test except tools, via the Nightly plan",
    )
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
    startup = None
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

    def run_pass(name, arguments, timeout):
        """Run selected cases once, export the evidence, and read each result."""
        test_error = None
        try:
            stage(
                name,
                [
                    "xcodebuild",
                    "test-without-building",
                    "-xctestrun",
                    str(xctestrun),
                    "-destination",
                    destination,
                    *arguments,
                    "-collect-test-diagnostics",
                    "never",
                    "-resultBundlePath",
                    str(evidence / (name + ".xcresult")),
                ],
                timeout,
            )
        except (RuntimeError, subprocess.TimeoutExpired) as error:
            test_error = error
        exported = {}
        export_errors = []
        for kind in ["summary", "tests"]:
            try:
                output = stage(
                    f"export-{name}-{kind}",
                    [
                        "xcrun",
                        "xcresulttool",
                        "get",
                        "test-results",
                        kind,
                        "--path",
                        str(evidence / (name + ".xcresult")),
                    ],
                    WATCHDOG_SECONDS["json_export"],
                )
                (evidence / f"{name}-{kind}.json").write_text(output)
                exported[kind] = json.loads(output)
            except Exception as error:
                export_errors.append(f"{name} {kind}: {error}")
        try:
            stage(
                f"export-{name}-attachments",
                [
                    "xcrun",
                    "xcresulttool",
                    "export",
                    "attachments",
                    "--path",
                    str(evidence / (name + ".xcresult")),
                    "--output-path",
                    str(evidence / (name + "-attachments")),
                ],
                WATCHDOG_SECONDS["attachment_export"],
            )
        except Exception as error:
            manifest.setdefault("diagnosticWarnings", []).append(
                f"{name} attachment export failed: {error}"
            )
            print(f"WARNING: {name} attachment export failed: {error}", flush=True)
        if export_errors:
            manifest.setdefault("exportErrors", []).extend(export_errors)
        if isinstance(test_error, subprocess.TimeoutExpired):
            raise test_error
        if export_errors:
            raise test_error or RuntimeError(
                "Result export failed: " + "; ".join(export_errors)
            )
        cases = results(
            exported["summary"], exported["tests"], args.platform,
            allow_skips=args.nightly,
        )
        # A failing exit is expected for failed cases, not for a passing run.
        if test_error and "Failed" not in cases.values():
            raise test_error
        return cases

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
            plan_name = "Nightly" if args.nightly else {
                "iphone": "CIIPhone", "ipad": "CIIPad", "mac": "CIMac"
            }[args.platform]
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
                # The build needs only the device's identity, so let the
                # simulator finish booting while it compiles.
                startup = in_background(lambda: stage(
                    "startup",
                    ["xcrun", "simctl", "bootstatus", udid, "-b"],
                    WATCHDOG_SECONDS["startup"],
                ))
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
            if startup:
                startup()
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
            xctestrun = runs[0]
            first = run_pass(
                "test", [],
                WATCHDOG_SECONDS["nightly_test" if args.nightly else "test"],
            )
            manifest["skippedTests"] = sorted(
                case for case, result in first.items() if result == "Skipped"
            )
            retry_cases = failed(first, expected)
            retry = None
            if retry_cases:
                manifest["failedFirstRun"] = sorted(retry_cases)
                if len(retry_cases) > MAX_RETRIED_TESTS:
                    raise RuntimeError(
                        f"{len(retry_cases)} UI tests failed; not retrying more "
                        f"than {MAX_RETRIED_TESTS}: {sorted(retry_cases)}"
                    )
                retry = run_pass(
                    "retry", retry_arguments(retry_cases), WATCHDOG_SECONDS["retry"]
                )
            report_retries(manifest, check(first, expected, retry))
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
