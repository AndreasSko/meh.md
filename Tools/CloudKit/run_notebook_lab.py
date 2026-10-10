#!/usr/bin/env python3
"""Run only a verified, signed Mac Development lab build on fictional data."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import time
import uuid

BUNDLE = "de.andreas-sk.meh-md.icloud-dev"
CONTAINER = "iCloud.de.andreas-sk.meh-md"
TEAM = "9YFM7J3EH3"


def command(*args):
    return subprocess.run(args, check=True, capture_output=True, timeout=60)


def simulator_entitlements(executable):
    """Read the one simulator entitlement section from a thin Mach-O file."""
    binary = executable.read_bytes()
    if binary[:4] != b"\xcf\xfa\xed\xfe":
        raise ValueError("Expected one little-endian 64-bit Mach-O slice")
    output = command("otool", "-l", str(executable)).stdout.decode()
    matches = []
    platforms = []
    current_command = None
    segment = {}
    section = None

    def finish_section():
        if section is None or section.get("sectname") != "__entitlements":
            return
        if current_command != "LC_SEGMENT_64" or segment.get("segname") != "__TEXT":
            raise ValueError("Entitlements section is outside __TEXT")
        if section.get("segname") != "__TEXT":
            raise ValueError("Entitlements section has an unexpected segment")
        try:
            offset = int(section["offset"], 0)
            size = int(section["size"], 0)
            fileoff = int(segment["fileoff"], 0)
            filesize = int(segment["filesize"], 0)
        except (KeyError, ValueError) as error:
            raise ValueError("Incomplete entitlements section") from error
        if (offset <= 0 or not 0 < size <= 65_536
                or offset < fileoff or offset + size > fileoff + filesize
                or offset + size > len(binary)):
            raise ValueError("Entitlements section is outside the binary")
        matches.append(binary[offset:offset + size])

    for raw in output.splitlines():
        line = raw.strip()
        if line.startswith("Load command "):
            finish_section()
            current_command, segment, section = None, {}, None
        elif line == "Section":
            finish_section()
            section = {}
        else:
            parts = line.split(None, 1)
            if len(parts) != 2:
                continue
            key, value = parts
            if key == "cmd":
                current_command = value
            elif current_command == "LC_BUILD_VERSION" and key == "platform":
                platforms.append(value)
            elif section is not None and key in ("sectname", "segname", "offset", "size"):
                section[key] = value
            elif section is None and key in ("segname", "fileoff", "filesize"):
                segment[key] = value
    finish_section()
    if platforms != ["7"]:
        raise ValueError("Expected one iOS Simulator build platform")
    if len(matches) != 1:
        raise ValueError("Expected exactly one __TEXT,__entitlements section")
    try:
        entitlements = plistlib.loads(matches[0])
    except (plistlib.InvalidFileException, ValueError) as error:
        raise ValueError("Malformed embedded simulator entitlements") from error
    if not isinstance(entitlements, dict):
        raise ValueError("Embedded simulator entitlements must be a dictionary")
    return entitlements


def verify(app, platform="MacOSX", lab=True):
    contents = app / "Contents" if platform == "MacOSX" else app
    info = plistlib.loads((contents / "Info.plist").read_bytes())
    if platform not in info.get("CFBundleSupportedPlatforms", []):
        raise ValueError("Unexpected app platform")
    if info.get("CFBundleIdentifier") != BUNDLE:
        raise ValueError("Expected the iCloud Dev bundle identifier")
    command("codesign", "--verify", "--deep", "--strict", str(app))
    signed = command("codesign", "-d", "--entitlements", ":-", str(app))
    entitlements = plistlib.loads(signed.stdout)
    if platform == "iPhoneSimulator":
        if entitlements:
            raise ValueError("Unexpected host signature entitlements on simulator")
        executable = contents / info["CFBundleExecutable"]
        entitlements = simulator_entitlements(executable)
    if entitlements.get("com.apple.developer.icloud-container-environment") != "Development":
        raise ValueError("Refusing a non-Development CloudKit environment")
    if entitlements.get("com.apple.developer.icloud-container-identifiers") != [CONTAINER]:
        raise ValueError("Unexpected CloudKit container")
    if platform == "iPhoneSimulator":
        if entitlements.get("application-identifier") != f"{TEAM}.{BUNDLE}":
            raise ValueError("Unexpected simulator application identifier")
        if entitlements.get("com.apple.developer.icloud-services") != ["CloudKit"]:
            raise ValueError("Unexpected simulator CloudKit services")
    executable = (contents / "MacOS" if platform == "MacOSX" else contents) / info["CFBundleExecutable"]
    debug_library = executable.with_name(executable.name + ".debug.dylib")
    symbol_file = debug_library if debug_library.exists() else executable
    symbols = command("nm", str(symbol_file)).stdout.decode()
    if lab:
        if "NotebookSyncLabAppV5$main" not in symbols:
            raise ValueError("Refusing a normal app: isolated lab entry point missing")
        if "MyAppV5$main" in symbols:
            raise ValueError("Refusing a binary containing the normal app entry")
    elif "MyAppV5$main" not in symbols or "NotebookSyncLabAppV5$main" in symbols:
        raise ValueError("Restoration requires the normal Development app entry")
    return executable, symbol_file


def read_lab_log(log_path, run, phase):
    result = None
    for line in log_path.read_text(errors="replace").splitlines():
        if line.startswith("SYNC_LAB_REPORT "):
            try:
                candidate = json.loads(line.removeprefix("SYNC_LAB_REPORT "))
            except json.JSONDecodeError:
                continue  # The writer may still be finishing this line.
            if candidate.get("runID", "").lower() != run:
                raise RuntimeError("Unexpected report identity")
            if candidate.get("phase") != phase:
                raise RuntimeError("Unexpected report phase")
            result = candidate
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("evidence", type=Path)
    parser.add_argument("--phase", choices=[
        "account", "exchange", "publish", "receive", "edit", "verify", "cleanup"
    ], required=True)
    parser.add_argument("--allow-development-cloud", action="store_true")
    parser.add_argument("--run-id", type=uuid.UUID)
    parser.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args()
    if not args.allow_development_cloud:
        parser.error("Explicit --allow-development-cloud is required")
    if not 10 <= args.timeout <= 300:
        parser.error("Timeout must be between 10 and 300 seconds")
    if args.phase in ("receive", "edit", "verify") and args.run_id is None:
        parser.error("Follow-up phases require the original --run-id")
    executable, symbol_file = verify(args.app.resolve())
    # A fresh run prevents touching earlier lab data, let alone app notebooks.
    run = str(args.run_id or uuid.uuid4())
    args.evidence.mkdir(parents=True, exist_ok=False)
    metadata = {
        "run_id": run, "phase": args.phase,
        "zone": "meh-md-notebook-lab-v2-" + run if args.phase != "account" else None,
        "source_revision": command("git", "rev-parse", "HEAD").stdout.decode().strip(),
        "working_tree": command("git", "-c", "core.fsmonitor=false", "status", "--short").stdout.decode(),
        "binary_sha256": hashlib.sha256(symbol_file.read_bytes()).hexdigest(),
        "scope": "Manual Development CloudKit lab phases. The exchange phase uses two clients on one Mac; staged phases can run across devices. No push delivery or native editor rendering measurement.",
    }
    (args.evidence / "environment.json").write_text(json.dumps(metadata, indent=2) + "\n")
    environment = os.environ.copy()
    environment.update(MEH_SYNC_LAB_ALLOW_DEVELOPMENT="1", MEH_SYNC_LAB_RUN=run,
                       MEH_SYNC_LAB_PHASE=args.phase)
    # Launch this exact verified executable, never a bundle-ID lookup that
    # could open the installed normal Development app instead.
    with (args.evidence / "process.log").open("wb") as log:
        process = subprocess.Popen([str(executable)], env=environment, stdout=log, stderr=log)
        deadline = time.monotonic() + args.timeout
        last_stage = None
        result = None
        try:
            while time.monotonic() < deadline:
                result = read_lab_log(args.evidence / "process.log", run, args.phase)
                if result is not None:
                    stage = result["stage"]
                    if stage != last_stage:
                        print(stage, flush=True)
                        last_stage = stage
                    if result["status"] != "running":
                        break
                if process.poll() is not None:
                    # The process can finish writing its final report after
                    # the read above and before poll observes its exit.
                    result = read_lab_log(
                        args.evidence / "process.log", run, args.phase
                    ) or result
                    if result is not None and result["status"] != "running":
                        break
                    raise RuntimeError(f"Lab exited before completion: {process.returncode}")
                time.sleep(0.5)
            if result is None or result["status"] == "running":
                raise TimeoutError("Bounded lab run did not finish")
            (args.evidence / "report.json").write_text(json.dumps(result, indent=2) + "\n")
            print(json.dumps({k: v for k, v in result.items() if k != "events"}, indent=2))
            if result["status"] != "passed":
                raise RuntimeError("Lab reported failure; see report.json")
        finally:
            try:
                if result is not None:
                    (args.evidence / "report.json").write_text(json.dumps(result, indent=2) + "\n")
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()


if __name__ == "__main__":
    main()
