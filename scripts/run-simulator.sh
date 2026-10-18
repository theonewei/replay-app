#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# Fails early with Xcode's setup/license message when first-time setup is pending.
xcodebuild -list -project Replay.xcodeproj >/dev/null
mkdir -p build
xcrun simctl list devices available --json > build/simulator-devices.json
selection=$(python3 -c '
import json, os, sys
with open("build/simulator-devices.json") as f:
    data = json.load(f)
devices = [d for runtime, group in data["devices"].items() if "iOS" in runtime for d in group if d.get("isAvailable") and d["name"].startswith("iPhone")]
requested = os.environ.get("SIMULATOR_UDID")
if requested:
    devices = [d for d in devices if d["udid"] == requested]
if not devices:
    sys.exit("No available iPhone simulator. Install an iOS runtime in Xcode Settings > Components, or check SIMULATOR_UDID.")
devices.sort(key=lambda d: d["state"] != "Booted")
print(devices[0]["udid"], devices[0]["state"])
')
read -r simulator_id simulator_state <<< "$selection"
if [[ "$simulator_state" != "Booted" ]]; then
    xcrun simctl boot "$simulator_id"
fi
if [[ -d "$DEVELOPER_DIR/../Applications/DeviceHub.app" ]]; then
    open -a "$DEVELOPER_DIR/../Applications/DeviceHub.app"
else
    open -a "$DEVELOPER_DIR/Applications/Simulator.app" --args -CurrentDeviceUDID "$simulator_id"
fi
xcrun simctl bootstatus "$simulator_id" -b
xcodebuild -project Replay.xcodeproj -scheme Replay -configuration Debug \
    -destination "platform=iOS Simulator,id=$simulator_id" \
    -derivedDataPath build/DerivedData build 2>&1 | tee build/debug-build.log
xcrun simctl install "$simulator_id" build/DerivedData/Build/Products/Debug-iphonesimulator/Replay.app
xcrun simctl launch --terminate-running-process "$simulator_id" com.example.ReplayPractice "$@"
printf 'Replay is running on simulator %s\n' "$simulator_id"
