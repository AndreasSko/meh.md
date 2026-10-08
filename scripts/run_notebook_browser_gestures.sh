#!/bin/bash
set -euo pipefail

# The Mac lane drives the desktop. Never run this on a personal machine.
if [[ "${GITHUB_ACTIONS:-}" != true ||
      "${RUNNER_ENVIRONMENT:-}" != github-hosted ]]; then
  printf 'Gesture validation requires a GitHub-hosted Actions guest.\n' >&2
  exit 2
fi
platform="${1:-}"
case "$platform" in
  macOS|iPhone|iPad) ;;
  *) printf 'usage: %s macOS|iPhone|iPad\n' "$0" >&2; exit 2 ;;
esac
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
evidence_root="$(mktemp -d "$RUNNER_TEMP/notebook-gesture-evidence.XXXXXX")"
work_root="$(mktemp -d "$RUNNER_TEMP/notebook-gesture-work.XXXXXX")"
sim_udid=""
collected_results=false
validation_complete=false
printf 'evidence_root=%s\n' "$evidence_root" >> "$GITHUB_OUTPUT"
printf 'Gesture evidence: %s\n' "$evidence_root"

collect_result() {
  [[ -d "$evidence_root/gestures.xcresult" ]] || return 0
  [[ "$collected_results" == false ]] || return 0
  collected_results=true
  xcrun xcresulttool get test-results summary \
    --path "$evidence_root/gestures.xcresult" \
    > "$evidence_root/summary.json" 2> "$evidence_root/summary-export.log" || true
  xcrun xcresulttool get test-results tests \
    --path "$evidence_root/gestures.xcresult" \
    > "$evidence_root/tests.json" 2> "$evidence_root/tests-export.log" || true
  xcrun xcresulttool export attachments \
    --path "$evidence_root/gestures.xcresult" \
    --output-path "$evidence_root/attachments" \
    > "$evidence_root/attachment-export.log" 2>&1 || true
}

cleanup() {
  local status=$?
  [[ "$BASH_SUBSHELL" == 0 ]] || return "$status"
  trap - EXIT INT TERM
  set +e
  if [[ "$status" == 0 && "$validation_complete" != true ]]; then
    printf 'Gesture validation exited before evidence verification.\n' >&2
    status=1
  fi
  collect_result
  if [[ -n "$sim_udid" ]]; then
    xcrun simctl shutdown "$sim_udid" >/dev/null 2>&1
    xcrun simctl delete "$sim_udid" >/dev/null 2>&1
  fi
  rm -rf "$work_root"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

{
  printf 'platform=%s\nrunner_environment=%s\n' \
    "$platform" "$RUNNER_ENVIRONMENT"
  printf 'run_id=%s\nrun_attempt=%s\nevent_sha=%s\n' \
    "$GITHUB_RUN_ID" "$GITHUB_RUN_ATTEMPT" "${GITHUB_SHA:-}"
  printf 'fixture=fictional notebook previews with per-launch UUID\n'
  printf 'MEH_SYNC_AUTOMATIC=0\nMEH_SYNC_CLOUDKIT=0\n'
  printf 'scheme=meh.md iCloud Dev\nconfiguration=Debug-iCloud\n'
  printf 'retries=disabled\nrecordings=XCTest, retained on success\n'
  sw_vers
  uname -m
} > "$evidence_root/provenance.txt"
xcodebuild -version | tee "$evidence_root/toolchain.txt"
grep -Eq '^Xcode 27([. ]|$)' "$evidence_root/toolchain.txt"
git -C "$repo_root" rev-parse HEAD > "$evidence_root/checkout.txt"
git -C "$repo_root" -c core.fsmonitor=false status --short \
  >> "$evidence_root/checkout.txt"
shasum -a 256 "$repo_root/meh.mdUITests/NotebookDragUITests.swift" \
  "$repo_root/scripts/run_notebook_browser_gestures.sh" \
  > "$evidence_root/source-sha256.txt"
cp "$repo_root/meh.mdUITests/NotebookDragUITests.swift" \
  "$evidence_root/NotebookDragUITests.swift"

if [[ "$platform" == macOS ]]; then
  # The UI test target deploys to macOS 27; an older guest cannot run it.
  [[ "$(sw_vers -productVersion)" == 27.* ]] || {
    printf 'The Mac gesture lane requires a macOS 27 hosted guest.\n' >&2
    exit 2
  }
  destination='platform=macOS'
  # Ad-hoc signing avoids a developer keychain/provisioning dependency. The
  # isolated fixture disables CloudKit, so CI has no need for its entitlement.
  signing=(CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
    CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= CODE_SIGN_ENTITLEMENTS=
    PROVISIONING_PROFILE_SPECIFIER=)
  printf 'signing=ad-hoc; build-only entitlement override\n' \
    >> "$evidence_root/provenance.txt"
else
  xcrun simctl list --json > "$evidence_root/simulators.json"
  python3 - "$evidence_root/simulators.json" "$platform" \
    > "$evidence_root/simulator-selection.txt" <<'PY'
import json
import sys

inventory = json.load(open(sys.argv[1], encoding="utf-8"))

def packed_version(version):
    parts = [int(part) for part in str(version).split(".")]
    parts += [0] * (3 - len(parts))
    return (parts[0] << 16) | (parts[1] << 8) | parts[2]

runtimes = [r for r in inventory.get("runtimes", [])
            if r.get("isAvailable")
            and r.get("identifier", "").startswith(
                "com.apple.CoreSimulator.SimRuntime.iOS-")
            and str(r.get("version", "")).split(".")[0] == "27"]
family = sys.argv[2]
if not runtimes:
    sys.exit("An available iOS 27 runtime is required")
runtime = max(runtimes, key=lambda r: packed_version(r["version"]))
version = packed_version(runtime["version"])
supported = {d["identifier"] for d in runtime.get("supportedDeviceTypes", [])}

def compatible(device):
    minimum = device.get("minRuntimeVersion")
    maximum = device.get("maxRuntimeVersion")
    if minimum is None:
        minimum = packed_version(device.get("minRuntimeVersionString", "0"))
    if maximum is None:
        maximum = packed_version(device.get("maxRuntimeVersionString",
                                            "65535.255.255"))
    return (minimum <= version <= maximum
            and (not supported or device["identifier"] in supported))

devices = [d for d in inventory.get("devicetypes", [])
           if (d.get("productFamily") == family
               or d.get("name", "").startswith(family + " "))
           and compatible(d)]
preferred = {"iPhone": ["iPhone 18 Pro", "iPhone 17 Pro", "iPhone 16 Pro"],
             "iPad": ["iPad Pro 11-inch (M5)", "iPad Pro 13-inch (M4)"]}[family]
devices.sort(key=lambda d: (preferred.index(d["name"])
                            if d["name"] in preferred else len(preferred),
                            -d.get("minRuntimeVersion", 0),
                            d.get("identifier", "")))
if not devices:
    sys.exit(f"No {family} type compatible with {runtime['identifier']}")
print(runtime["identifier"], devices[0]["identifier"])
PY
  read -r runtime_id device_type < "$evidence_root/simulator-selection.txt"
  sim_udid="$(xcrun simctl create \
    "NotebookGestures-$platform-$(basename "$work_root")" \
    "$device_type" "$runtime_id")"
  printf 'udid=%s\nruntime=%s\ndevice_type=%s\n' \
    "$sim_udid" "$runtime_id" "$device_type" \
    > "$evidence_root/owned-simulator.txt"
  xcrun simctl boot "$sim_udid"
  xcrun simctl bootstatus "$sim_udid" -b
  destination="platform=iOS Simulator,id=$sim_udid"
  signing=(CODE_SIGNING_ALLOWED=NO)
fi
printf 'destination=%s\n' "$destination" >> "$evidence_root/provenance.txt"

xcodebuild build-for-testing -project "$repo_root/meh.md.xcodeproj" \
  -scheme 'meh.md iCloud Dev' -configuration Debug-iCloud \
  -destination "$destination" -derivedDataPath "$work_root/build" \
  "${signing[@]}" 2>&1 | tee "$evidence_root/build.log"

if [[ "$platform" == macOS ]]; then
  codesign --display --verbose=4 \
    "$work_root/build/Build/Products/Debug-iCloud/meh.md iCloud Dev.app" \
    > "$evidence_root/mac-signing.txt" 2>&1
  codesign --display --entitlements :- \
    "$work_root/build/Build/Products/Debug-iCloud/meh.md iCloud Dev.app" \
    > "$evidence_root/mac-entitlements.plist" \
    2> "$evidence_root/mac-entitlements.log"
fi

python3 - "$work_root/build/Build/Products" "$evidence_root" \
  > "$evidence_root/test-run-path.txt" <<'PY'
from pathlib import Path
import plistlib
import shutil
import sys

products = Path(sys.argv[1])
paths = list(products.glob("*.xctestrun"))
if len(paths) != 1:
    sys.exit(f"Expected one test run, found {len(paths)}")
with paths[0].open("rb") as source:
    run = plistlib.load(source)
targets = [v for k, v in run.items()
           if isinstance(v, dict) and v.get("BlueprintName") == "meh.mdUITests"]
if len(targets) != 1:
    sys.exit("Expected one flat meh.mdUITests target")
target = targets[0]
# The scheme normally selects only iCloud tests. Select all nine drag cases.
target["OnlyTestIdentifiers"] = ["NotebookDragUITests"]
target.pop("SkipTestIdentifiers", None)
target["PreferredScreenCaptureFormat"] = "screenRecording"
target["SystemAttachmentLifetime"] = "keepAlways"
target["UserAttachmentLifetime"] = "keepAlways"
target["ParallelizationEnabled"] = False
target["TestTimeoutsEnabled"] = True
# Existing successful folder-creation cases take more than five minutes.
# Allow slower hosted guests while keeping each case and the job bounded.
target["DefaultTestExecutionTimeAllowance"] = 600
target["MaximumTestExecutionTimeAllowance"] = 900
# Keep __TESTROOT__ next to the generated products during execution.
output = products / "NotebookGestures.xctestrun"
with output.open("wb") as stream:
    plistlib.dump(run, stream)
shutil.copy2(output, Path(sys.argv[2]) / output.name)
print(output)
PY
read -r test_run < "$evidence_root/test-run-path.txt"
set +e
xcodebuild test-without-building -xctestrun "$test_run" \
  -destination "$destination" \
  -only-testing:meh.mdUITests/NotebookDragUITests \
  -parallel-testing-enabled NO \
  -resultBundlePath "$evidence_root/gestures.xcresult" \
  2>&1 | tee "$evidence_root/test.log"
test_status=${PIPESTATUS[0]}
set -e
collect_result
[[ "$test_status" == 0 ]] || exit "$test_status"

python3 - "$evidence_root" "$platform" <<'PY' | tee "$evidence_root/verification.txt"
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
summary = json.loads((root / "summary.json").read_text())
expected = {
    "testSortDragResortAndRelaunchPreserveOrderAndSource",
    "testClosedAndNestedFolderHoverThenReturnToFiles",
    "testFolderSubtreeRejectsDescendantAndCancelledDragKeepsSelection",
    "testContinuousNestedHoverMovesNoteIntoDeepFolder",
    "testNestedFixtureSequentialAndContinuousHoverPreservesSource",
    "testExpandedFolderEdgesReorderRootWithoutMovingIntoSubtree",
    "testFixtureReordersThreeVisibleNotes",
    "testLongListDragAutoscrollsAndPersists",
    "testSelectedNotesDragTogetherAndKeepTheirSource",
}
for field, count in {"passedTests": 9, "failedTests": 0, "skippedTests": 0,
                     "expectedFailures": 0, "totalTestCount": 9}.items():
    if summary.get(field) != count:
        sys.exit(f"{field}: expected {count}, got {summary.get(field)}")
if summary.get("result") != "Passed":
    sys.exit("Gesture result must be Passed")
cases = []

def visit(node):
    if node.get("nodeType") == "Test Case":
        identifier = node.get("nodeIdentifier", "")
        if node.get("result") != "Passed":
            sys.exit(f"Test did not pass: {identifier}")
        cases.append(identifier)
    for child in node.get("children", []):
        visit(child)

for node in json.loads((root / "tests.json").read_text()).get("testNodes", []):
    visit(node)
identifiers = {f"NotebookDragUITests/{name}()" for name in expected}
if len(cases) != 9 or set(cases) != identifiers:
    sys.exit(f"Expected nine distinct drag cases, got {cases}")
configurations = summary.get("devicesAndConfigurations", [])
if len(configurations) != 1:
    sys.exit("Expected exactly one device configuration")
device = configurations[0].get("device", {})
platform = sys.argv[2]
if platform != "macOS" and (
        device.get("platform") != "iOS Simulator"
        or not str(device.get("osVersion", "")).startswith("27.")
        or not str(device.get("modelName", "")).startswith(platform)):
    sys.exit(f"Unexpected simulator: {device}")
if platform == "macOS" and device.get("platform") != "macOS":
    sys.exit(f"Unexpected Mac configuration: {device}")
manifest = json.loads((root / "attachments" / "manifest.json").read_text())
coverage = {identifier: [] for identifier in sorted(identifiers)}
used_files = set()
for entry in manifest:
    identifier = entry.get("testIdentifier")
    if identifier not in coverage:
        continue
    for attachment in entry.get("attachments", []):
        name = attachment.get("exportedFileName", "")
        path = root / "attachments" / name
        if Path(name).suffix.lower() not in {".mp4", ".mov"}:
            continue
        if (Path(name).name != name or not path.is_file()
                or path.stat().st_size == 0):
            sys.exit(f"Missing or invalid recording for {identifier}: {name}")
        if attachment.get("deviceId") != device.get("deviceId"):
            sys.exit(f"Recording is from an unexpected device: {identifier}")
        if name in used_files:
            sys.exit(f"Recording mapped more than once: {name}")
        used_files.add(name)
        coverage[identifier].append(name)
(root / "recording-coverage.json").write_text(json.dumps(coverage, indent=2) + "\n")
missing = [identifier for identifier, files in coverage.items() if not files]
if missing:
    sys.exit(f"Missing per-test recordings: {missing}")
print(f"PASS: all nine {platform} gesture tests; zero failures/skips; "
      f"{len(used_files)} retained recordings mapped to all nine cases")
PY
validation_complete=true
verified_head="$(git -C "$repo_root" rev-parse HEAD)"
printf 'verified_head=%s\n' "$verified_head" >> "$GITHUB_OUTPUT"
