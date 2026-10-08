#!/usr/bin/env python3
"""Run every applicable app UI test using disposable fictional fixtures."""
import argparse
import copy
from contextlib import contextmanager, ExitStack
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import signal
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
from urllib.request import urlopen
import uuid

from ci_test_inventory import inventory
from ci_process import run_logged

ROOT = Path(__file__).resolve().parents[1]


@contextmanager
def loopback_fixture(data, log):
    """Serve the real HTTP fixture without a second Python interpreter launch."""
    spec = importlib.util.spec_from_file_location(
        "ci_local_sync_server", ROOT / "Tools/LocalSyncServer/local_sync_server.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    store = module.WorkspaceStore(data)
    with log.open("w") as output, module.DataDirectoryLock(store.root):
        log_lock = threading.Lock()

        class LoggedHandler(module.SyncRequestHandler):
            def log_message(self, format, *args):
                with log_lock:
                    output.write(f"{self.address_string()} - {format % args}\n")
                    output.flush()

        class LoopbackServer(module.LocalSyncHTTPServer):
            def server_bind(self):
                # HTTPServer performs reverse DNS even for numeric loopback.
                # That lookup can request LAN discovery permission on macOS.
                socketserver.TCPServer.server_bind(self)
                self.server_name, self.server_port = self.server_address[:2]

        server = LoopbackServer(("127.0.0.1", 0), store)
        server.RequestHandlerClass = LoggedHandler
        endpoint = f"http://127.0.0.1:{server.server_port}"
        output.write(f"Local sync service listening on {endpoint}\n")
        output.flush()
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            # Prove readiness through the actual HTTP handler before any UI run.
            with urlopen(endpoint + "/v1/records?scope=ci-readiness", timeout=5) as response:
                if json.load(response)["records"] != []:
                    raise RuntimeError("Loopback fixture must start with an empty workspace")
            yield endpoint
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)
            if thread.is_alive():
                raise RuntimeError("Loopback fixture failed to stop")


def targets(plan):
    if "TestConfigurations" in plan:
        return [target for config in plan["TestConfigurations"]
                for target in config["TestTargets"]]
    return [target for target in plan.values()
            if isinstance(target, dict) and target.get("BlueprintName")]


def standard_identifiers(records):
    return [r["id"] for r in records
            if r["category"] == "standard" and not r["expected_skip"]]


def selected_plan(original, identifiers, environment):
    """Replace scheme defaults with the explicit applicable method inventory."""
    if not identifiers or any(not i.startswith("meh.mdUITests/") for i in identifiers):
        raise ValueError("UI test selection must contain explicit target identifiers")
    plan = copy.deepcopy(original)
    found = False
    for target in targets(plan):
        if target["BlueprintName"] != "meh.mdUITests":
            continue
        found = True
        target["OnlyTestIdentifiers"] = [i.split("/", 1)[1] for i in identifiers]
        target.pop("SkipTestIdentifiers", None)
        target["ParallelizationEnabled"] = False
        for key in ("EnvironmentVariables", "TestingEnvironmentVariables"):
            target.setdefault(key, {}).update(environment)
    if not found:
        raise ValueError("Built test plan does not contain meh.mdUITests")
    return plan


def capture(*args):
    return subprocess.check_output(args, text=True).strip()


def macos_runner_path(products, plan):
    ui = [t for t in targets(plan) if t["BlueprintName"] == "meh.mdUITests"]
    if len(ui) != 1:
        raise ValueError("Expected one Mac UI runner")
    runner = Path(ui[0]["TestHostPath"].replace("__TESTROOT__", str(products))).resolve()
    if (not runner.is_relative_to(products.resolve())
            or runner.name != "meh.mdUITests-Runner.app" or not runner.is_dir()):
        raise ValueError("Mac UI runner must belong to these disposable build products")
    return runner


def sign_macos_runner(products, plan, evidence, identity):
    # Unsigned XCTest's copied Apple runner lacks get-task-allow. Xcode cannot
    # resume its suspended launch without that debugging entitlement.
    runner = macos_runner_path(products, plan)
    entitlement = evidence / "runner-debug.entitlements"
    entitlement.write_bytes(plistlib.dumps({"com.apple.security.get-task-allow": True}))
    logged(["codesign", "--force", "--sign", identity, "--entitlements", entitlement,
            "--timestamp=none", runner], evidence / "runner-signing.log", timeout=120)


def stop_owned_macos_apps(products):
    # macOS launches UI runners via launchd, outside xcodebuild's process group.
    # Only executables inside this invocation's unique products are ours.
    prefixes = {str(products.absolute()) + "/", str(products.resolve()) + "/"}
    owned = []
    for line in capture("ps", "-axo", "pid=,command=").splitlines():
        pid, _, command = line.strip().partition(" ")
        if any(command.lstrip().startswith(prefix) for prefix in prefixes):
            owned.append(int(pid))
    for pid in owned:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    if owned:
        time.sleep(0.2)
    remaining = {}
    if owned:
        for line in capture("ps", "-axo", "pid=,command=").splitlines():
            pid, _, command = line.strip().partition(" ")
            remaining[int(pid)] = command.lstrip()
    for pid in owned:
        if not any(remaining.get(pid, "").startswith(prefix) for prefix in prefixes):
            continue
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def logged(args, path, timeout=7200):
    run_logged(args, path, timeout=timeout)


def select_runtime_device(listing, platform):
    runtimes = [r for r in listing["runtimes"] if r.get("isAvailable")
                and r["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-")
                and r["version"].split(".")[0] == "27"]
    if not runtimes:
        raise RuntimeError("Missing available iOS 27 runtime")
    runtime = max(runtimes, key=lambda r: tuple(map(int, r["version"].split("."))))
    components = list(map(int, runtime["version"].split(".")))
    components += [0] * (3 - len(components))
    version = (components[0] << 16) | (components[1] << 8) | components[2]
    kind = "iPhone" if platform == "iphone" else "iPad"
    types = [d for d in listing["devicetypes"] if d["name"].startswith(kind)
             and d["minRuntimeVersion"] <= version <= d["maxRuntimeVersion"]]
    if not types:
        raise RuntimeError(f"Missing {kind} device type compatible with {runtime['version']}")
    preferred = ("com.apple.CoreSimulator.SimDeviceType.iPhone-12-Pro-Max"
                 if platform == "iphone" else
                 "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB")
    device = next((d for d in types if d["identifier"] == preferred),
                  max(types, key=lambda d: (d["minRuntimeVersion"], d["name"])))
    return runtime, device


def create_simulator(platform, owned):
    listing = json.loads(capture("xcrun", "simctl", "list", "--json"))
    runtime, device = select_runtime_device(listing, platform)
    udid = capture("xcrun", "simctl", "create", "CI-Coverage-" + uuid.uuid4().hex,
                   device["identifier"], runtime["identifier"])
    owned.append(udid)
    subprocess.run(["xcrun", "simctl", "boot", udid], check=True)
    subprocess.run(["xcrun", "simctl", "bootstatus", udid, "-b"], check=True)
    return udid


def collect(bundle, evidence, name):
    if not bundle.exists():
        return
    for kind in ("summary", "tests"):
        with (evidence / f"{name}-{kind}.json").open("w") as output:
            subprocess.run(["xcrun", "xcresulttool", "get", "test-results", kind,
                            "--path", str(bundle)], stdout=output, check=True)
    subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path",
                    str(bundle), "--output-path", str(evidence / f"{name}-attachments")],
                   check=True)


def main():
    # GitHub cancellation must unwind owned simulator and service cleanup.
    def interrupted(signum, frame):
        raise KeyboardInterrupt(f"Interrupted by signal {signum}")

    signal.signal(signal.SIGTERM, interrupted)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=("iphone", "ipad", "macos"), required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--macos-signing-identity", default=os.environ.get("MEH_MAC_UI_SIGNING_IDENTITY", "-"),
                        help="Optional local developer identity matching an authorized runner; CI uses ad-hoc signing")
    args = parser.parse_args()
    evidence = args.output_dir.resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    records = inventory(ROOT, args.platform)
    if isinstance(records, dict):
        records = records["tests"]
    ui = [r for r in records if r["target"] == "meh.mdUITests"]
    (evidence / "inventory.json").write_text(json.dumps(ui, indent=2) + "\n")
    owned = []
    phases = []
    fixtures = ExitStack()
    with tempfile.TemporaryDirectory(prefix="meh-ci-ui-") as temp:
        work = Path(temp)
        products = work / "build/Build/Products"
        try:
            device = None if args.platform == "macos" else create_simulator(args.platform, owned)
            destination = "platform=macOS" if device is None else f"platform=iOS Simulator,id={device}"
            server_log = evidence / "loopback.log"
            endpoint = fixtures.enter_context(loopback_fixture(work / "server", server_log))
            build = work / "build"
            logged(["xcodebuild", "build-for-testing", "-project", ROOT / "meh.md.xcodeproj",
                    "-scheme", "meh.md iCloud Dev", "-destination", destination,
                    "-derivedDataPath", build, "CODE_SIGNING_ALLOWED=NO"], evidence / "build.log")
            products = build / "Build/Products"
            runs = list(products.glob("*.xctestrun"))
            if len(runs) != 1:
                raise RuntimeError(f"Expected one built test plan, found {runs}")
            original = plistlib.loads(runs[0].read_bytes())
            if args.platform == "macos":
                sign_macos_runner(products, original, evidence, args.macos_signing_identity)
            environment = {"MEH_CI_SYNC_PORT": endpoint.rsplit(":", 1)[1]}
            environment["MEH_SYNC_TEST_WORKSPACE"] = "ci-" + uuid.uuid4().hex

            def run_phase(name, identifiers, dest):
                plan = selected_plan(original, identifiers, environment)
                # Keep relative __TESTROOT__ paths beside the original plan.
                run = products / f"ci-{name}.xctestrun"
                run.write_bytes(plistlib.dumps(plan))
                bundle = evidence / f"{name}.xcresult"
                phases.append((name, bundle))
                logged(["xcodebuild", "test-without-building", "-xctestrun", run,
                        "-destination", dest, "-parallel-testing-enabled", "NO",
                        "-collect-test-diagnostics", "never",
                        "-resultBundlePath", bundle], evidence / f"{name}.log")
                run.unlink()

            standard = standard_identifiers(ui)
            if standard:
                run_phase("standard", standard, destination)
            if args.platform == "iphone":
                # Native import picker requires actual files inside this owned app sandbox.
                phases.append(("import", evidence / "import/import.xcresult"))
                logged([sys.executable, ROOT / "Tools/Import/run_simulator_checks.py",
                        "--products-dir", products, "--simulator", device,
                        "--output-dir", evidence / "import"], evidence / "import-runner.log")
                pad = create_simulator("ipad", owned)
                for name, udid, method in (
                    ("phone-publish", device, "test01PublishFromPhone"),
                    ("pad-reply", pad, "test02ReceiveAndReplyFromPad"),
                    ("phone-reopen", device, "test03ReceiveReplyOnPhoneAndRestart"),
                ):
                    run_phase(name, [f"meh.mdUITests/LocalSyncUITests/{method}"],
                              f"platform=iOS Simulator,id={udid}")
        finally:
            errors = []
            if args.platform == "macos":
                try:
                    stop_owned_macos_apps(products)
                except Exception as error:
                    errors.append(f"Mac app cleanup failed: {error}")
            (evidence / "owned-simulators.json").write_text(
                json.dumps(owned, indent=2) + "\n")
            for name, bundle in phases:
                try:
                    collect(bundle, evidence, name)
                except Exception as error:
                    errors.append(str(error))
            (evidence / "results.json").write_text(json.dumps([
                {"summary": str(evidence / f"{name}-summary.json"),
                 "tests": str(evidence / f"{name}-tests.json")}
                for name, bundle in phases if bundle.exists()], indent=2) + "\n")
            try:
                fixtures.close()
            except Exception as error:
                errors.append(f"Loopback fixture cleanup failed: {error}")
            for udid in owned:
                subprocess.run(["xcrun", "simctl", "shutdown", udid], check=False)
                subprocess.run(["xcrun", "simctl", "delete", udid], check=True)
            if errors:
                raise RuntimeError("Result export failed: " + "; ".join(errors))
    subprocess.run([sys.executable, str(ROOT / "scripts/check_ci_test_coverage.py"),
                    "--platform", args.platform, "--scope", "ui",
                    "--results", str(evidence / "results.json"),
                    "--output", str(evidence / "coverage-report.json")], check=True)


if __name__ == "__main__":
    main()
