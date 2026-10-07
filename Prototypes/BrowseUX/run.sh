#!/bin/bash
# PROTOTYPE — throwaway. Build the browse UX prototype and launch it in the iPhone Simulator.
# Usage: Prototypes/BrowseUX/run.sh [A|B|C]
set -euo pipefail

cd "$(dirname "$0")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
DEVICE="${DEVICE:-iPhone 18 Pro}"
BUNDLE_ID=no.kracobsen.logos.prototype.browseux

xcodebuild -project BrowseUXPrototype.xcodeproj -scheme BrowseUXPrototype -configuration Debug \
  -destination "platform=iOS Simulator,name=$DEVICE" -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO -quiet build

xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b >/dev/null
open -a Simulator 2>/dev/null || open "$DEVELOPER_DIR/../Applications/DeviceHub.app" 2>/dev/null || true
xcrun simctl install "$DEVICE" build/Build/Products/Debug-iphonesimulator/BrowseUXPrototype.app
xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" 2>/dev/null || true
if [ -n "${1:-}" ]; then
  xcrun simctl launch "$DEVICE" "$BUNDLE_ID" -variant "$1"
else
  xcrun simctl launch "$DEVICE" "$BUNDLE_ID"
fi
