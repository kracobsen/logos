#!/bin/bash
# Format checking with swift-format (ships with Xcode), using the repo's .swift-format.
#
# Usage:
#   scripts/format.sh          check only; fails on any formatting difference (what CI runs)
#   scripts/format.sh --fix    rewrite files in place
set -euo pipefail

cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

paths=(Logos LogosUITests LogosKit/Package.swift LogosKit/Sources LogosKit/Tests)

if [ "${1:-}" = "--fix" ]; then
    xcrun swift-format format --in-place --recursive --parallel "${paths[@]}"
else
    xcrun swift-format lint --strict --recursive --parallel "${paths[@]}"
fi
