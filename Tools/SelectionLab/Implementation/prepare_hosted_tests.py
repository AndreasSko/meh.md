#!/usr/bin/env python3
"""Prepare native-editor package tests for an isolated iCloud Dev app host."""

import argparse
import plistlib
from pathlib import Path
import shutil
import subprocess
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app-host", required=True, type=Path)
    parser.add_argument("--test-run", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    host_source = args.app_host.resolve()
    run_source = args.test_run.resolve()
    metadata = plistlib.loads((host_source / "Info.plist").read_bytes())
    bundle_id = metadata["CFBundleIdentifier"]
    executable = metadata["CFBundleExecutable"]
    if not bundle_id.endswith(".icloud-dev"):
        parser.error("Use the iCloud Dev build.")
    host_code = [host_source / executable,
                 host_source / (executable + ".debug.dylib")]
    if not any(b"MEH_SELECTION_IMPLEMENTATION" in file.read_bytes()
               for file in host_code if file.exists()):
        parser.error("Build the staged isolated selection host first.")

    data = plistlib.loads(run_source.read_bytes())
    configs = data["TestConfigurations"]
    for config in configs:
        config["TestTargets"] = [
            target for target in config["TestTargets"]
            if target["BlueprintName"] == "NativeEditorTests"
        ]
    targets = [target for config in configs for target in config["TestTargets"]]
    if len(targets) != 1:
        parser.error("Expected one NativeEditorTests target.")
    target = targets[0]
    bundle_source = Path(target["TestBundlePath"].replace(
        "__TESTROOT__", str(run_source.parent)
    ))
    if not bundle_source.is_dir():
        parser.error("Build NativeEditorTests before preparing the host.")

    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    host = output / "SelectionHost.app"
    shutil.copytree(host_source, host)
    plugin = host / "PlugIns" / "NativeEditorTests.xctest"
    plugin.parent.mkdir(exist_ok=True)
    shutil.copytree(bundle_source, plugin)

    def resolve_products(value):
        if isinstance(value, str):
            return value.replace("__TESTROOT__", str(run_source.parent))
        if isinstance(value, list):
            return [resolve_products(item) for item in value]
        if isinstance(value, dict):
            return {key: resolve_products(item) for key, item in value.items()}
        return value

    data = resolve_products(data)
    target = next(target for config in data["TestConfigurations"]
                  for target in config["TestTargets"])
    target.update({
        "TestHostPath": str(host),
        "TestHostBundleIdentifier": bundle_id,
        "IsAppHostedTestBundle": True,
        "TestBundlePath": "__TESTHOST__/PlugIns/NativeEditorTests.xctest",
        "DependentProductPaths": [str(host), str(plugin)],
        "OnlyTestIdentifiers": ["MarkdownSelectionScrollingTests"],
        "EnvironmentVariables": {
            "MEH_SELECTION_IMPLEMENTATION": "1",
            "MEH_NOTEBOOK_PREVIEW": "1",
            "MEH_NOTEBOOK_PREVIEW_RUN": "hosted-selection-" + uuid.uuid4().hex,
            "MEH_SYNC_AUTOMATIC": "0",
        },
    })
    target["TestingEnvironmentVariables"].update({
        "DYLD_INSERT_LIBRARIES": "__PLATFORMS__/iPhoneSimulator.platform/"
                                 "Developer/usr/lib/libXCTestBundleInject.dylib",
        "XCTestBundlePath": "__TESTBUNDLE__",
        "XCInjectBundleInto": "__TESTHOST__/" + executable,
    })
    subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(host)],
                   check=True)
    destination = output / "selection-hosted.xctestrun"
    destination.write_bytes(plistlib.dumps(data))
    print(destination)


if __name__ == "__main__":
    main()
