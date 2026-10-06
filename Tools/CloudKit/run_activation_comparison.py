#!/usr/bin/env python3
"""Prepare and run pinned, fictional iCloud activation comparisons."""
import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import io
import inspect
import json
import os
from pathlib import Path
import statistics
import shutil
import subprocess
import sys
import tarfile
import time
import uuid

from run_notebook_lab import BUNDLE, command, verify, read_lab_log
from run_notebook_lab_simulator import (
    check_existing_app, lab_report_path, read_lab_report, terminate_lab,
)

BEFORE = "22fa32572d9f5ff7282637f3f365e8159b48ad85"
NAME = "meh.md AI CloudKit"
RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
DEVICE_TYPE = "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro"
REPO = Path(__file__).resolve().parents[2]
PHASES = ("activation-prepare", "activation-update", "activation-startup",
          "activation-foreground")


def require_external_artifacts(path):
    if path == REPO or REPO in path.parents:
        raise ValueError("Prepared products and evidence must be outside the repository")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def select_simulator(listing, expected_device=None):
    matches = [(runtime, device)
               for runtime, devices in listing["devices"].items()
               for device in devices if device.get("name") == NAME]
    if len(matches) != 1:
        raise ValueError("Exactly one meh.md AI CloudKit simulator is required")
    runtime, device = matches[0]
    try:
        selected_id = str(uuid.UUID(device.get("udid", ""))).upper()
    except ValueError as error:
        raise ValueError("Dedicated simulator has an invalid UUID") from error
    if (runtime != RUNTIME
            or (expected_device and selected_id != str(uuid.UUID(expected_device)).upper())
            or device.get("deviceTypeIdentifier") != DEVICE_TYPE
            or not device.get("isAvailable")):
        raise ValueError("Dedicated simulator identity, device type or iOS 27 differs")
    if device.get("state") not in ("Booted", "Shutdown"):
        raise ValueError("Dedicated simulator is changing state")
    return device


@contextmanager
def simulator_lease():
    # Preserve one canonical lock inode across runs and worktrees.
    directory = Path.home() / "Library/Caches/meh.md-ai-testing"
    if not directory.exists():
        try:
            directory.mkdir(parents=True, mode=0o700)
        except PermissionError as error:
            raise RuntimeError("Cannot create canonical simulator lock directory; "
                               "grant access to ~/Library/Caches/meh.md-ai-testing") from error
    stat = directory.lstat()
    if directory.is_symlink() or stat.st_uid != os.getuid() or stat.st_mode & 0o077:
        raise ValueError("Simulator lock directory must be private and user-owned")
    descriptor = os.open(directory / "cloudkit-simulator.lock",
                         os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w") as lock:
        if os.fstat(lock.fileno()).st_uid != os.getuid():
            raise ValueError("Simulator lock must be user-owned")
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise RuntimeError("AI CloudKit simulator is busy in another task") from error
        try:
            yield
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def check_device(expected_device=None, boot=False):
    listing = json.loads(command("xcrun", "simctl", "list", "devices", "-j").stdout)
    device = select_simulator(listing, expected_device)
    if boot and device["state"] == "Shutdown":
        command("xcrun", "simctl", "boot", device["udid"])
        command("xcrun", "simctl", "bootstatus", device["udid"], "-b")
    return device


def overlay_factory(source):
    start = source.index("    public static func makeIsolatedNotebookLab(")
    end = source.index("    #endif", start)
    block = source[start:end]
    if "automaticallySync: Bool" not in block:
        block = block.replace("runID: UUID\n", "runID: UUID,\n        automaticallySync: Bool = false\n")
        block = block.replace("automaticallySync: false,", "automaticallySync: automaticallySync,")
    if "automaticallySync: Bool" not in block or "automaticallySync: automaticallySync" not in block:
        raise ValueError("Unexpected isolated lab factory; inspect before preparing")
    return source[:start] + block + source[end:]


def require_safe_tar_extraction():
    """Accept runtimes and backports that implement extraction filters."""
    parameters = inspect.signature(tarfile.TarFile.extractall).parameters
    if not callable(getattr(tarfile, "data_filter", None)) or "filter" not in parameters:
        raise RuntimeError("This Python lacks safe tar extraction filters. "
                           "Use a Python with tarfile.data_filter and "
                           "extractall(filter=...) support, then prepare again.")


def archive_revision(revision, destination):
    archive = command("git", "-C", str(REPO), "archive", revision).stdout
    destination.mkdir()
    with tarfile.open(fileobj=io.BytesIO(archive)) as entries:
        entries.extractall(destination, filter="data")


def prepare(args):
    require_safe_tar_extraction()
    with simulator_lease():
        device = check_device()
    after = command("git", "-C", str(REPO), "rev-parse", "HEAD").stdout.decode().strip()
    harness = (REPO / "meh.md/NotebookSyncLabApp.swift").read_bytes()
    root = args.prepared.resolve()
    require_external_artifacts(root)
    root.mkdir(parents=True, exist_ok=False)
    manifest = {"schema": 1, "before": BEFORE, "after": after,
                "harness_sha256": hashlib.sha256(harness).hexdigest(),
                "harness_repository_revision": after,
                "harness_source": "working_tree_at_preparation",
                "harness_path": "meh.md/NotebookSyncLabApp.swift",
                "xcode_version": command("xcodebuild", "-version").stdout.decode().strip(),
                "simulator": str(uuid.UUID(device["udid"])).upper(), "runtime": RUNTIME, "variants": {},
                "scope": "Fictional isolated Development CloudKit zones only"}
    import shutil
    for component in ("checkouts", "repositories", "artifacts"):
        package_cache = REPO / ".build" / component
        if package_cache.exists():
            shutil.copytree(package_cache, root / "SourcePackages" / component)
    for variant, revision in (("before", BEFORE), ("after", after)):
        source = root / (variant + "-source")
        archive_revision(revision, source)
        (source / "meh.md/NotebookSyncLabApp.swift").write_bytes(harness)
        factory = source / "Sources/NoteCore/CloudKitSyncTransport.swift"
        factory.write_text(overlay_factory(factory.read_text()))
        derived = root / (variant + "-build")
        build = ["xcodebuild", "-project", str(source / "meh.md.xcodeproj"),
                 "-scheme", "meh.md iCloud Dev", "-configuration", "Debug-iCloud",
                 "-sdk", "iphonesimulator", "-destination", "generic/platform=iOS Simulator",
                 "-derivedDataPath", str(derived),
                 "-clonedSourcePackagesDirPath", str(root / "SourcePackages"),
                 "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES",
                 "SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) SYNC_LAB",
                 "ENABLE_DEBUG_DYLIB=NO", "build"]
        with (root / (variant + "-build.log")).open("wb") as log:
            subprocess.run(build, check=True, stdout=log, stderr=subprocess.STDOUT,
                           cwd=source, timeout=1800)
        apps = list((derived / "Build/Products/Debug-iCloud-iphonesimulator").glob("*.app"))
        verified = []
        for app in apps:
            try:
                executable, symbols = verify(app, platform="iPhoneSimulator")
                verified.append((app, executable, symbols))
            except (ValueError, subprocess.CalledProcessError):
                continue
        if len(verified) != 1:
            raise ValueError("Expected one signed Development lab app")
        app, executable, symbols = verified[0]
        manifest["variants"][variant] = {
            "revision": revision, "app": str(app), "executable_sha256": digest(executable),
            "binary_sha256": digest(symbols), "build_command": build,
            "harness_sha256": digest(source / "meh.md/NotebookSyncLabApp.swift"),
            "factory_sha256": digest(factory),
        }
    if args.mac_publisher:
        source = root / "after-source"
        derived = root / "mac-publisher-build"
        build = ["xcodebuild", "-project", str(source / "meh.md.xcodeproj"),
                 "-scheme", "meh.md iCloud Dev", "-configuration", "Debug-iCloud",
                 "-sdk", "macosx", "-destination", "platform=macOS",
                 "-derivedDataPath", str(derived),
                 "-clonedSourcePackagesDirPath", str(root / "SourcePackages"),
                 "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES",
                 "SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) SYNC_LAB",
                 "ENABLE_DEBUG_DYLIB=NO", "build"]
        with (root / "mac-publisher-build.log").open("wb") as log:
            subprocess.run(build, check=True, stdout=log, stderr=subprocess.STDOUT,
                           cwd=source, timeout=1800)
        apps = list((derived / "Build/Products/Debug-iCloud").glob("*.app"))
        publishers = []
        for app in apps:
            try:
                publishers.append(publisher_identity(app))
            except (ValueError, subprocess.CalledProcessError):
                continue
        if len(publishers) != 1:
            raise ValueError("Expected one signed Development Mac publisher lab")
        manifest["publisher"] = {
            **publishers[0], "harness_sha256": manifest["harness_sha256"],
            "revision": after, "build_command": build,
        }
    write_json(root / "manifest.json", manifest)
    if args.account_preflight:
        with simulator_lease():
            check_device(manifest["simulator"], boot=True)
            preflight(manifest, root / "account-preflight")
    print(root / "manifest.json")


def verify_prepared(manifest):
    if (manifest.get("schema") != 1 or manifest.get("before") != BEFORE
            or not manifest.get("simulator") or manifest.get("runtime") != RUNTIME
            or set(manifest.get("variants", {})) != {"before", "after"}):
        raise ValueError("Unexpected preparation manifest")
    for variant, item in manifest["variants"].items():
        if item["revision"] != manifest[variant]:
            raise ValueError("Prepared revision does not match manifest")
        executable, symbols = verify(Path(item["app"]), platform="iPhoneSimulator")
        if digest(executable) != item["executable_sha256"] or digest(symbols) != item["binary_sha256"]:
            raise ValueError("Prepared binary changed; prepare again")
        if item["harness_sha256"] != manifest["harness_sha256"]:
            raise ValueError("Variants do not share identical instrumentation")


def launch_phase(app, evidence, run, phase, timeout, device, notes=100,
                 external_publisher=False, awaiting_publisher=None):
    verify(Path(app), platform="iPhoneSimulator")
    try:
        check_existing_app(device)
    except (ValueError, subprocess.CalledProcessError) as error:
        raise RuntimeError("Refusing to overwrite the installed app on the dedicated "
                           "simulator: it is not a verified signed Development lab. "
                           "Keep it untouched and select an empty task-owned simulator.") from error
    evidence.mkdir(parents=True, exist_ok=False)
    command("xcrun", "simctl", "install", device, app)
    report_path = lab_report_path(device, run, phase)
    if report_path.exists():
        raise ValueError("Fresh per-trial lab run ID required")
    environment = os.environ.copy()
    environment.update(SIMCTL_CHILD_MEH_SYNC_LAB_ALLOW_DEVELOPMENT="1",
                       SIMCTL_CHILD_MEH_SYNC_LAB_RUN=run,
                       SIMCTL_CHILD_MEH_SYNC_LAB_PHASE=phase,
                       SIMCTL_CHILD_MEH_SYNC_LAB_NOTE_COUNT=str(notes))
    if external_publisher:
        environment["SIMCTL_CHILD_MEH_SYNC_LAB_EXTERNAL_PUBLISHER"] = "1"
    result = None
    publisher_called = False
    try:
        launch = subprocess.run(["xcrun", "simctl", "launch", "--terminate-running-process",
                                 device, BUNDLE], env=environment, capture_output=True,
                                check=True, timeout=30)
        (evidence / "launch.log").write_bytes(launch.stdout + launch.stderr)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            result = read_lab_report(report_path, run, phase)
            if (result and result.get("stage") == "awaiting_external_foreground_publisher"
                    and awaiting_publisher and not publisher_called):
                publisher_called = True
                awaiting_publisher()
                deadline = time.monotonic() + timeout
            if result and result.get("status") != "running":
                break
            time.sleep(0.5)
        if not result or result.get("status") == "running":
            raise TimeoutError("Bounded activation phase did not finish")
        write_json(evidence / "report.json", result)
        if result.get("status") != "passed":
            raise RuntimeError("Activation phase failed; see report.json")
        return result
    finally:
        if result:
            write_json(evidence / "report.json", result)
        terminate_lab(device)


def publisher_identity(app):
    executable, symbols = verify(app.resolve(), platform="MacOSX")
    return {"app": str(app.resolve()), "executable": str(executable),
            "executable_sha256": digest(executable), "binary_sha256": digest(symbols),
            "platform": "MacOSX", "cloud_environment": "Development"}


def verify_publisher(manifest, app):
    prepared = manifest.get("publisher")
    if (not isinstance(prepared, dict)
            or prepared.get("harness_sha256") != manifest.get("harness_sha256")
            or prepared.get("revision") != manifest.get("after")):
        raise ValueError("Prepare the Mac publisher with the same pinned harness and revision")
    if Path(prepared.get("app", "")).resolve() != app.resolve():
        raise ValueError("Mac publisher app differs from the prepared manifest")
    actual = publisher_identity(app)
    if any(actual[key] != prepared.get(key)
           for key in ("executable_sha256", "binary_sha256")):
        raise ValueError("Mac publisher binary differs from the prepared manifest")
    return actual


def launch_host_phase(identity, evidence, run, phase, timeout):
    if publisher_identity(Path(identity["app"])) != identity:
        raise ValueError("Prepared Mac publisher changed")
    evidence.mkdir(parents=True, exist_ok=False)
    environment = os.environ.copy()
    environment.update(MEH_SYNC_LAB_ALLOW_DEVELOPMENT="1", MEH_SYNC_LAB_RUN=run,
                       MEH_SYNC_LAB_PHASE=phase, MEH_SYNC_LAB_EXTERNAL_PUBLISHER="1")
    result = None
    log_path = evidence / "process.log"
    with log_path.open("wb") as log:
        process = subprocess.Popen([identity["executable"]], env=environment,
                                   stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                result = read_lab_log(log_path, run, phase) or result
                if result and result.get("status") != "running":
                    break
                if process.poll() is not None:
                    result = read_lab_log(log_path, run, phase) or result
                    if result and result.get("status") != "running":
                        break
                    raise RuntimeError("Mac publisher exited before its final report")
                time.sleep(0.5)
            if not result or result.get("status") == "running":
                raise TimeoutError("Bounded Mac publisher phase did not finish")
            if result.get("status") != "passed":
                if phase == "account" and result.get("accountStatus") not in (None, 1):
                    raise RuntimeError("Mac publisher iCloud account unavailable; check "
                                       "macOS iCloud Settings. No login is automated.")
                raise RuntimeError("Mac publisher phase failed; see report.json")
            return result
        finally:
            if result:
                write_json(evidence / "report.json", result)
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=10)


def activation_directory(device, run):
    # Installing another build can migrate the data container. Resolve this
    # only after installation, never retain a previous phase's container path.
    return lab_report_path(device, run, "activation-prepare").parent.parent / "activation"


def publisher_foreground_callback(publisher, evidence, device, run, timeout):
    def publish_and_signal():
        report = launch_host_phase(publisher, evidence, run,
                                   "activation-publish-foreground", timeout)
        signal_foreground_ready(activation_directory(device, run), run, report)
    return publish_and_signal


def copy_publisher_fixture(activation, run, host_documents=None):
    normalized = str(uuid.UUID(run)).lower()
    manifest = json.loads((activation / "manifest.json").read_text())
    if str(uuid.UUID(manifest.get("runID", ""))).lower() != normalized:
        raise ValueError("Fixture run ID differs from trial")
    source = activation / "source/notebook"
    if not source.is_dir() or source.is_symlink() or any(
            entry.is_symlink() for entry in source.rglob("*")):
        raise ValueError("Only a real task-owned source notebook may be copied")
    destination = (host_documents or Path.home() / "Library/Containers" / BUNDLE
                   / "Data/Documents") / "SyncLab" / normalized / "activation"
    destination.mkdir(parents=True, exist_ok=False)
    shutil.copytree(source, destination / "source/notebook")
    shutil.copyfile(activation / "manifest.json", destination / "manifest.json")
    return destination


def signal_foreground_ready(activation, run, report):
    if (report.get("status") != "passed"
            or report.get("phase") != "activation-publish-foreground"
            or str(uuid.UUID(report.get("runID", ""))).lower() != run.lower()
            or not isinstance(report.get("expectedText"), str)):
        raise ValueError("Mac foreground publisher did not confirm the expected fixture")
    target = activation / "external-foreground-ready.json"
    if target.exists():
        raise ValueError("Foreground ready signal already exists")
    temporary = target.with_suffix(".json.tmp")
    write_json(temporary, {"runID": run, "phase": "activation-publish-foreground",
                           "expectedText": report["expectedText"]})
    os.replace(temporary, target)


def preflight(manifest, evidence):
    verify_prepared(manifest)
    try:
        return launch_phase(manifest["variants"]["after"]["app"], evidence,
                            str(uuid.uuid4()), "account", 60, manifest["simulator"])
    except RuntimeError as error:
        report_path = evidence / "report.json"
        report = json.loads(report_path.read_text()) if report_path.exists() else {}
        if report.get("accountStatus") not in (None, 1):
            raise RuntimeError("Account-only preflight stopped: iCloud is unavailable. "
                               "Check the dedicated simulator's iCloud Settings, then rerun "
                               "with fresh evidence; no account login is automated.") from error
        raise


def trial_sequence(trials):
    return [(index + 1, variant, phase)
            for index in range(trials)
            for variant in (("before", "after") if index % 2 == 0 else ("after", "before"))
            for phase in PHASES]


def validate_trial_report(report, phase, notes):
    if report.get("status") != "passed" or report.get("phase") != phase:
        raise ValueError("Incomplete or mismatched activation report")
    if phase not in ("activation-startup", "activation-foreground"):
        return
    if (report.get("noteCount") != notes
            or not isinstance(report.get("expectedText"), str)
            or report["expectedText"] != report.get("observedText")
            or not isinstance(report.get("expectedLocalText"), str)
            or report["expectedLocalText"] != report.get("observedLocalText")):
        raise ValueError("Activation report does not confirm expected fictional content")
    metrics = report.get("measurementsMS", {})
    if any(not metrics.get(key) for key in ("activation_visible", "activation_complete")):
        raise ValueError("Activation report lacks required timing samples")


def summarize(records):
    grouped = {}
    for record in records:
        for metric, values in record["report"].get("measurementsMS", {}).items():
            if not isinstance(values, list) or any(
                    not isinstance(value, (int, float)) or isinstance(value, bool)
                    or not 0 <= value < float("inf") for value in values):
                raise ValueError("Invalid timing values")
            grouped.setdefault(record["variant"], {}).setdefault(
                record["phase"] + ":" + metric, []).extend(values)
    return {variant: {metric: {"raw_ms": values, "median_ms": statistics.median(values)}
                      for metric, values in metrics.items() if values}
            for variant, metrics in grouped.items()}


def run(args):
    manifest = json.loads((args.prepared.resolve() / "manifest.json").read_text())
    verify_prepared(manifest)
    publisher = verify_publisher(manifest, args.publisher_app) if args.publisher_app else None
    require_external_artifacts(args.evidence.resolve())
    args.evidence.mkdir(parents=True, exist_ok=False)
    write_json(args.evidence / "manifest.json", {
        **manifest, "trial_count": args.trials, "note_count": args.notes,
        "phase_timeout_seconds": args.timeout,
        "publisher": {**manifest["publisher"], **publisher} if publisher else None,
    })
    records = []
    with simulator_lease():
        check_device(manifest["simulator"], boot=True)
        preflight(manifest, args.evidence / "account")
        if publisher:
            launch_host_phase(publisher, args.evidence / "publisher-account",
                              str(uuid.uuid4()), "account", 60)
        trial_ids = {}
        try:
            for trial, variant, phase in trial_sequence(args.trials):
                run_id = trial_ids.setdefault((trial, variant), str(uuid.uuid4()))
                evidence = args.evidence / f"trial-{trial:02d}" / variant / phase
                publisher_evidence = evidence.parent / "publisher"
                callback = None
                if publisher and phase == "activation-foreground":
                    callback = publisher_foreground_callback(
                        publisher, publisher_evidence / "activation-publish-foreground",
                        manifest["simulator"], run_id, args.timeout)
                report = launch_phase(
                    manifest["variants"][variant]["app"], evidence, run_id, phase,
                    args.timeout, manifest["simulator"], args.notes,
                    external_publisher=bool(publisher), awaiting_publisher=callback)
                if publisher and phase == "activation-prepare":
                    copy_publisher_fixture(
                        activation_directory(manifest["simulator"], run_id), run_id)
                    launch_host_phase(
                        publisher, publisher_evidence / "activation-publish-startup",
                        run_id, "activation-publish-startup", args.timeout)
                validate_trial_report(report, phase, args.notes)
                records.append({"trial": trial, "variant": variant, "phase": phase,
                                "run_id": run_id, "report": report})
        finally:
            write_json(args.evidence / "results.json", {
                "records": records, "summary": summarize(records),
                "complete": len(records) == args.trials * 2 * len(PHASES),
                "limits": "Cold process Workspace start and controlled Workspace foreground; "
                          "coordinator/replica timings only, no OS icon-launch, screen paint "
                          "or APNs-delivery claim",
            })


def preflight_command(args):
    manifest = json.loads((args.prepared.resolve() / "manifest.json").read_text())
    verify_prepared(manifest)
    require_external_artifacts(args.evidence.resolve())
    with simulator_lease():
        check_device(manifest["simulator"], boot=True)
        preflight(manifest, args.evidence)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    preparation = commands.add_parser("prepare")
    preparation.add_argument("prepared", type=Path)
    preparation.add_argument("--account-preflight", action="store_true")
    preparation.add_argument("--mac-publisher", action="store_true",
                             help="Build and pin a Mac fixture publisher with the same harness")
    account = commands.add_parser("preflight")
    account.add_argument("prepared", type=Path)
    account.add_argument("evidence", type=Path)
    execution = commands.add_parser("run")
    execution.add_argument("prepared", type=Path)
    execution.add_argument("evidence", type=Path)
    execution.add_argument("--trials", type=int, default=3)
    execution.add_argument("--timeout", type=int, default=180)
    execution.add_argument("--notes", type=int, default=100)
    execution.add_argument("--publisher-app", type=Path,
                           help="Optional independently signed Mac Development lab publisher")
    args = parser.parse_args()
    if args.action == "run" and (not 1 <= args.trials <= 20 or not 10 <= args.timeout <= 300
                                  or not 2 <= args.notes <= 1000):
        parser.error("Use 1–20 trials, 2–1000 notes and 10–300 seconds per phase")
    {"prepare": prepare, "preflight": preflight_command, "run": run}[args.action](args)


if __name__ == "__main__":
    main()
