#!/bin/zsh
# Captures the raw App Store screenshots on iPhone, iPad and Mac into raw/.
# Usage: capture.sh [iphone] [ipad] [mac]   (default: all three)
# SCREENSHOT_TEST=testSnippetScreens capture.sh  retakes only one test's shots.
# The Mac run takes over the mouse for about a minute.
set -euo pipefail
here="${0:A:h}"
cd "$here/../.."

devices=(${@:-iphone ipad mac})
build=build/app-store-shots
scheme="meh.md Local"
# The newest general iOS runtime, not one made for a single device
runtime=$(xcrun simctl list runtimes available \
  | grep -oE 'com\.apple\.CoreSimulator\.SimRuntime\.iOS-[0-9]+(-[0-9]+)*$' \
  | sort -V | tail -1)
typeset -A models=(iphone "iPhone 18 Pro Max" ipad "iPad Air 13-inch (M4)")

# A dedicated simulator per device, so other sessions' simulators stay untouched
simulator() {
  local name="meh shots $1"
  local id=$(xcrun simctl list devices available | grep "$name (" \
    | grep -o '[0-9A-F-]\{36\}' | head -1)
  if [[ -z $id ]]; then
    id=$(xcrun simctl create "$name" "${models[$1]}" "$runtime")
    xcrun simctl boot "$id"
    xcrun simctl bootstatus "$id" -b > /dev/null
    xcrun simctl spawn "$id" defaults write -g AppleLanguages -array en
    xcrun simctl spawn "$id" defaults write -g AppleLocale en_US
    xcrun simctl shutdown "$id"
  fi
  xcrun simctl boot "$id" 2> /dev/null || true
  xcrun simctl bootstatus "$id" -b > /dev/null
  xcrun simctl status_bar "$id" override --time 9:41 \
    --batteryState discharging --batteryLevel 100 --cellularBars 4 --wifiBars 3
  echo "$id"
}

# Runs the screenshot test and copies its attachments into raw/<folder>.
run() {
  local destination=$1 result=$build/$2.xcresult folder=$3
  rm -rf "$result" "$build/$2"
  TEST_RUNNER_MEH_README_SCREENS=1 xcodebuild test-without-building \
    -project meh.md.xcodeproj -scheme "$scheme" -destination "$destination" \
    -derivedDataPath "$build/dd" -resultBundlePath "$result" \
    -only-testing:"meh.mdUITests/ReadmeScreenshotUITests${SCREENSHOT_TEST:+/$SCREENSHOT_TEST}" \
    > "$build/$2.log" 2>&1 \
    || { echo "$2 failed, see $build/$2.log"; return 1; }
  xcrun xcresulttool export attachments --path "$result" \
    --output-path "$build/$2" > /dev/null
  mkdir -p "$here/raw/$folder"
  python3 - "$build/$2" "$here/raw/$folder" <<'EOF'
import json, shutil, sys
source, target = sys.argv[1:]
for test in json.load(open(f"{source}/manifest.json")):
    for a in test["attachments"]:
        name = a["suggestedHumanReadableName"].split("_")[0]
        if a["exportedFileName"].endswith(".png") and \
                name.startswith(("iphone", "ipad", "mac")):
            shutil.copy(f"{source}/{a['exportedFileName']}",
                        f"{target}/{name}.png")
            print(f"{target}/{name}.png")
EOF
}

mkdir -p "$build"
if (( ${devices[(Ie)iphone]} || ${devices[(Ie)ipad]} )); then
  xcodebuild build-for-testing -project meh.md.xcodeproj -scheme "$scheme" \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$build/dd" \
    -quiet > "$build/ios-build.log" 2>&1
fi
if (( ${devices[(Ie)iphone]} )); then
  id=$(simulator iphone)
  xcrun simctl ui "$id" appearance light
  run "id=$id" iphone iphone
  # The iPhone set uses one dark-mode screenshot.
  xcrun simctl ui "$id" appearance dark
  run "id=$id" iphone-dark dark
  xcrun simctl ui "$id" appearance light
fi
if (( ${devices[(Ie)ipad]} )); then
  id=$(simulator ipad)
  xcrun simctl ui "$id" appearance light
  run "id=$id" ipad ipad
fi
if (( ${devices[(Ie)mac]} )); then
  xcodebuild build-for-testing -project meh.md.xcodeproj -scheme "$scheme" \
    -destination 'platform=macOS' -derivedDataPath "$build/dd" \
    -quiet > "$build/mac-build.log" 2>&1
  run "platform=macOS" mac mac
fi
