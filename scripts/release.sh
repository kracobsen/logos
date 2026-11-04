#!/bin/bash
# Starts the Xcode Cloud "TestFlight" workflow, which archives the head of main on GitHub and sends it to TestFlight.
# Shows what will be built and asks first. See docs/releasing.md for the API key it needs.
#
# Usage:
#   scripts/release.sh            show the commit and version, confirm, start the build
#   scripts/release.sh --yes      don't ask
#   scripts/release.sh --wait     also wait for the build to finish (fails if it does)
#
# Environment: ASC_KEY_ID, ASC_ISSUER_ID, and ASC_KEY_PATH (defaults to
# ~/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8).
set -euo pipefail

cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

workflow=TestFlight
branch=main

yes=false
wait=()
for argument in "$@"; do
    case "$argument" in
        --yes) yes=true ;;
        --wait) wait=(--wait) ;;
        *) echo "usage: scripts/release.sh [--yes] [--wait]" >&2; exit 2 ;;
    esac
done

: "${ASC_KEY_ID:?set ASC_KEY_ID to your App Store Connect API key ID; see docs/releasing.md}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID to your App Store Connect issuer ID; see docs/releasing.md}"
export ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}"
if [ ! -f "$ASC_KEY_PATH" ]; then
    echo "error: no API key at $ASC_KEY_PATH; set ASC_KEY_PATH" >&2
    exit 1
fi

# Xcode Cloud builds the head of main on GitHub, not this checkout.
git fetch --quiet origin "$branch"
remote="origin/$branch"
if [ "$(git rev-parse --verify --quiet "$branch")" != "$(git rev-parse "$remote")" ]; then
    ahead=$(git rev-list --count "$remote..$branch" 2>/dev/null || echo 0)
    behind=$(git rev-list --count "$branch..$remote" 2>/dev/null || echo 0)
    echo "note: local $branch is $ahead ahead and $behind behind $remote; the build uses $remote."
fi
# What Xcode Cloud sees: the committed Base.xcconfig, never Local.xcconfig.
base_config=$(git show "$remote:Config/Base.xcconfig")
version=$(sed -n 's/^MARKETING_VERSION = //p' <<<"$base_config")
bundle_id="$(sed -n 's/^BUNDLE_ID_PREFIX = //p' <<<"$base_config").logos"

echo "Xcode Cloud will build $remote for TestFlight:"
echo "  $(git log -1 --format='%h %s (%cr)' "$remote")"
echo "  $bundle_id version $version, build number set by Xcode Cloud"

if [ "$yes" = false ]; then
    read -r -p "Start the build? [y/N] " answer
    case "$answer" in
        y | Y | yes) ;;
        *) echo "Not started."; exit 1 ;;
    esac
fi

xcrun swift scripts/release/start-build.swift "$bundle_id" "$workflow" "$branch" ${wait[@]+"${wait[@]}"}
