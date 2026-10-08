#!/usr/bin/env python3
"""Run every iOS-native package test and verify result coverage."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import tempfile

from ci_process import run_logged, cancellation_handler

REPO = Path(__file__).resolve().parents[1]


def main():
    signal.signal(signal.SIGTERM, cancellation_handler)
    temp = os.environ.get("RUNNER_TEMP", "/tmp")
    evidence = Path(tempfile.mkdtemp(prefix="native-coverage-evidence-", dir=temp))
    work = Path(tempfile.mkdtemp(prefix="native-coverage-work-", dir=temp))
    simulator = None
    bundle = evidence / "native.xcresult"
    print(f"Native test evidence: {evidence}", flush=True)
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            output.write(f"evidence_root={evidence}\n")

    def run(args, log, cwd=None):
        run_logged(args, evidence / log, cwd=cwd)

    try:
        inventory = json.loads(subprocess.check_output(
            ["xcrun", "simctl", "list", "--json"], text=True))
        (evidence / "simulators.json").write_text(json.dumps(inventory, indent=2))
        runtimes = [item for item in inventory["runtimes"]
                    if item.get("isAvailable") and
                    item["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-")
                    and item["version"].split(".")[0] == "27"]
        if not runtimes:
            raise RuntimeError("An available iOS 27 simulator runtime is required")
        runtime = max(runtimes, key=lambda item: tuple(map(int, item["version"].split("."))))
        simulator = subprocess.check_output([
            "xcrun", "simctl", "create", f"NativeCoverage-{work.name}",
            "com.apple.CoreSimulator.SimDeviceType.iPhone-12-Pro-Max",
            runtime["identifier"]], text=True).strip()
        (evidence / "owned-simulator.txt").write_text(simulator + "\n")
        run(["xcrun", "simctl", "boot", simulator], "boot.log")
        run(["xcrun", "simctl", "bootstatus", simulator, "-b"], "bootstatus.log")
        package = work / "package"
        package.mkdir()
        for entry in ["Sources", "Tests", "meh.md"]:
            (package / entry).symlink_to(REPO / entry, target_is_directory=True)
        manifest = (REPO / "Package.swift").read_text() + '''
// Model and core suites run separately; retain the complete native suite.
package.products.removeAll { $0.name == "NotebookAppModel" }
package.targets.removeAll {
    ["NotebookAppModel", "NotebookAppModelTests", "NoteCoreTests"].contains($0.name)
}
'''
        (package / "Package.swift").write_text(manifest)
        (evidence / "native-package.swift").write_text(manifest)
        if (REPO / "Package.resolved").exists():
            shutil.copy2(REPO / "Package.resolved", package)
        run(["xcodebuild", "build-for-testing", "-scheme", "MehCore-Package",
             "-configuration", "Debug", "-destination", "generic/platform=iOS Simulator",
             "-derivedDataPath", str(work / "build"), "CODE_SIGNING_ALLOWED=NO"],
            "build.log", package)
        runs = list((work / "build/Build/Products").glob("*iphonesimulator*.xctestrun"))
        if len(runs) != 1:
            raise RuntimeError(f"Expected one xctestrun; found {len(runs)}")
        config = plistlib.loads(runs[0].read_bytes())

        def enable_benchmark(value):
            if isinstance(value, dict):
                if "TestBundlePath" in value:
                    value.setdefault("EnvironmentVariables", {})["MEH_FULL_PARSE_BENCHMARK"] = "1"
                for child in list(value.values()):
                    enable_benchmark(child)
            elif isinstance(value, list):
                for child in value:
                    enable_benchmark(child)
        enable_benchmark(config)
        runs[0].write_bytes(plistlib.dumps(config))
        shutil.copy2(runs[0], evidence / "native.xctestrun")
        run(["xcodebuild", "test-without-building", "-xctestrun", str(runs[0]),
             "-destination", f"platform=iOS Simulator,id={simulator}",
             "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never",
             "-resultBundlePath", str(bundle)],
            "tests.log")
    finally:
        if bundle.exists():
            for kind in ["summary", "tests"]:
                with (evidence / f"native-{kind}.json").open("w") as output:
                    subprocess.run(["xcrun", "xcresulttool", "get", "test-results", kind,
                                    "--path", str(bundle)], stdout=output, check=False)
            subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path",
                            str(bundle), "--output-path", str(evidence / "attachments")],
                           check=False)
        if simulator:
            subprocess.run(["xcrun", "simctl", "shutdown", simulator], check=False)
            subprocess.run(["xcrun", "simctl", "delete", simulator], check=False)
        shutil.rmtree(work)
    results = evidence / "results.json"
    results.write_text(json.dumps([{
        "summary": str(evidence / "native-summary.json"),
        "tests": str(evidence / "native-tests.json"),
    }], indent=2))
    run(["python3", str(REPO / "scripts/check_ci_test_coverage.py"), "--platform",
         "iphone", "--scope", "native", "--results", str(results), "--output",
         str(evidence / "coverage-report.json")], "coverage.log")


if __name__ == "__main__":
    main()
