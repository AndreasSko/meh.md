#!/bin/bash
# Build the iCloud Dev app, install it on a connected iPhone or iPad, and
# launch it: scripts/install_device.sh [--production] [device name or UDID]
#
# --production installs the Release build of the production app instead. It
# replaces the TestFlight app and uses the real iCloud notebook, so only use
# it when the user explicitly asks for it.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
scheme="meh.md iCloud Dev" configuration=Debug-iCloud derived=build/device
if [[ "${1:-}" == "--production" ]]; then
  scheme="meh.md" configuration=Release derived=build/device-production
  shift
fi
wanted=${1:-}
devices=$(mktemp)
trap 'rm -f "$devices"' EXIT
xcrun devicectl list devices --quiet --json-output "$devices" >/dev/null

# Prints "<udid>\t<state>\t<name>" for the first matching physical device.
read -r udid state name < <(WANTED="$wanted" python3 - "$devices" <<'EOF'
import json, os, sys
wanted = os.environ["WANTED"]
devices = [
    d for d in json.load(open(sys.argv[1]))["result"]["devices"]
    if d["hardwareProperties"].get("reality") == "physical"
    and d["hardwareProperties"].get("platform") == "iOS"
]
if wanted:
    devices = [
        d for d in devices
        if wanted in (d["deviceProperties"].get("name"),
                      d["hardwareProperties"].get("udid"), d["identifier"])
    ]
else:
    # Prefer a device that is reachable right now.
    devices.sort(key=lambda d: d["connectionProperties"].get("tunnelState") != "connected")
for d in devices[:1]:
    print(d["hardwareProperties"]["udid"],
          d["connectionProperties"].get("tunnelState", "unknown"),
          d["deviceProperties"].get("name", ""), sep="\t")
EOF
) || true

if [[ -z "${udid:-}" ]]; then
  echo "No paired iPhone or iPad found${wanted:+ matching '$wanted'}." >&2
  exit 1
fi
if [[ "$state" != "connected" ]]; then
  echo "$name is $state. Unlock it and keep it nearby or plugged in, then retry." >&2
  exit 1
fi

if [[ "$scheme" == "meh.md" ]]; then
  echo "This replaces the TestFlight app on $name with a build of" \
    "$(git rev-parse --abbrev-ref HEAD), using your real iCloud notes." >&2
  if [[ -t 0 ]]; then
    read -r -p "Continue? [y/N] " answer
    [[ "$answer" == [yY] ]] || exit 1
  fi
fi

xcodebuild build -project meh.md.xcodeproj -scheme "$scheme" \
  -configuration "$configuration" \
  -destination "id=$udid" -derivedDataPath "$derived" \
  -allowProvisioningUpdates -quiet
app=$(find "$derived/Build/Products/$configuration-iphoneos" -maxdepth 1 -name '*.app' | head -1)
bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")

xcrun devicectl device install app --device "$udid" "$app"
xcrun devicectl device process launch --device "$udid" --terminate-existing "$bundle"
