#!/bin/bash
# PROTOTYPE — throwaway. Generate the talking-clock test Books (first run only), build the multi-file playback
# prototype and launch it in the iPhone Simulator. For a real device, open the .xcodeproj, pick a team, and Run.
# Usage: Prototypes/MultiFilePlayback/run.sh [--regenerate]
set -euo pipefail

cd "$(dirname "$0")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
DEVICE="${DEVICE:-iPhone 18 Pro}"
BUNDLE_ID=no.kracobsen.logos.prototype.multifile
BOOKS=MultiFilePlaybackPrototype/TestBooks

if [ "${1:-}" = "--regenerate" ] || ! ls "$BOOKS"/*.book.json >/dev/null 2>&1; then
  mkdir -p build
  swiftc -O tools/make-test-books.swift -o build/make-test-books
  build/make-test-books "$BOOKS"
fi

xcodebuild -project MultiFilePlaybackPrototype.xcodeproj -scheme MultiFilePlaybackPrototype -configuration Debug \
  -destination "platform=iOS Simulator,name=$DEVICE" -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO -quiet build

xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b >/dev/null
open -a Simulator 2>/dev/null || true
xcrun simctl install "$DEVICE" build/Build/Products/Debug-iphonesimulator/MultiFilePlaybackPrototype.app
xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl launch "$DEVICE" "$BUNDLE_ID"
