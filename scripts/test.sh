#!/bin/bash
# Builds the app and runs every LogosKit unit test on the iOS Simulator, through the shared Logos scheme.
# Packages resolve only from the checked-in LogosKit/Package.resolved.
# No simulator diagnostics: any issue (even a runtime warning) triggers a sysdiagnose-like collection
# that hangs on GitHub's runners until its 600 s timeout.
#
# Usage: scripts/test.sh [extra xcodebuild args, e.g. -only-testing:DomainTests]
# Env:   DEVICE (default "iPhone 18 Pro"), DERIVED_DATA (default .build/DerivedData)
set -euo pipefail

cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
DEVICE="${DEVICE:-iPhone 18 Pro}"
DERIVED_DATA="${DERIVED_DATA:-.build/DerivedData}"

xcodebuild test \
    -project Logos.xcodeproj \
    -scheme Logos \
    -destination "platform=iOS Simulator,name=$DEVICE" \
    -derivedDataPath "$DERIVED_DATA" \
    -disableAutomaticPackageResolution \
    -collect-test-diagnostics never \
    -quiet \
    "$@"
