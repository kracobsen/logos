#!/bin/bash
# Runs the IntegrationTests target against a throwaway audiobookshelf 2.37.1 in Docker:
#   1. generates the fixture Library (scripts/integration/make-fixture-library.sh) in a temp dir;
#   2. starts the pinned Server, bound to 127.0.0.1 on a free port, with no persistent volumes;
#   3. seeds it: root user, one book Library over the fixtures, a fixture user with local sign-in, a full scan;
#   4. runs IntegrationTests on the simulator (with --ui: the app's UI smoke test instead, LogosUITests/SmokeTests),
#      failing if any test was skipped;
#   5. removes the container and temp dir, whatever happened.
#
# The Server only ever listens on loopback, and the tests refuse any non-loopback URL, so nothing here can reach a
# real Server. The credentials below belong to this throwaway container only.
#
# Usage:
#   scripts/integration-test.sh [extra xcodebuild args, e.g. -only-testing:IntegrationTests/HarnessTests]
#   scripts/integration-test.sh --serve    start and seed, print the connection details, wait until killed
#   scripts/integration-test.sh --ui       run the UI smoke test (sign in, browse, download, play) against the Server
# Env: DEVICE (default "iPhone 18 Pro"), DERIVED_DATA (default .build/DerivedData), KEEP_RESULTS (a directory)
set -euo pipefail

cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
DEVICE="${DEVICE:-iPhone 18 Pro}"
DERIVED_DATA="${DERIVED_DATA:-.build/DerivedData}"

IMAGE="ghcr.io/advplyr/audiobookshelf:2.37.1@sha256:581d68b2a6fc7ebf58d81c878a9f387cbbc0d88ac9d37b298b9cee10168af85b"
ADMIN_USERNAME="root"
ADMIN_PASSWORD="rootpass"
USERNAME="listener"
PASSWORD="listenerpass"
EXPECTED_BOOKS=6

serve=0
ui=0
if [ "${1:-}" = "--serve" ]; then
    serve=1
    shift
elif [ "${1:-}" = "--ui" ]; then
    ui=1
    shift
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/logos-integration.XXXXXX")
container="logos-integration-$$-$RANDOM"
cleanup() {
    docker rm -f "$container" >/dev/null 2>&1 || true
    # KEEP_RESULTS=<dir> keeps the test results (xcresult) for a closer look, e.g. after a failure.
    if [ -n "${KEEP_RESULTS:-}" ]; then mkdir -p "$KEEP_RESULTS" && cp -R "$work"/*.xcresult "$KEEP_RESULTS"/ 2>/dev/null || true; fi
    rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

json() { python3 -I -c "import json, sys; print(eval(sys.argv[1], {}, {'j': json.load(sys.stdin)}))" "$1"; }

echo "Generating the fixture Library..."
mkdir -p "$work/audiobooks"
scripts/integration/make-fixture-library.sh "$work/audiobooks" "$IMAGE"

echo "Starting audiobookshelf ($container)..."
docker run -d --rm --name "$container" \
    --label logos.integration=1 \
    -p 127.0.0.1::80 \
    -e RATE_LIMIT_AUTH_MAX=0 \
    -v "$work/audiobooks:/audiobooks:ro" \
    "$IMAGE" >/dev/null
port=$(docker port "$container" 80/tcp | grep -m1 -oE '^127\.0\.0\.1:[0-9]+$' | cut -d: -f2)
SERVER_URL="http://127.0.0.1:$port"

for _ in $(seq 60); do
    curl -fsS "$SERVER_URL/healthcheck" >/dev/null 2>&1 && break
    sleep 1
done
curl -fsS "$SERVER_URL/healthcheck" >/dev/null

echo "Seeding $SERVER_URL..."
post() { curl -fsS -X POST -H 'Content-Type: application/json' "$@"; }

post "$SERVER_URL/init" -d "{\"newRoot\":{\"username\":\"$ADMIN_USERNAME\",\"password\":\"$ADMIN_PASSWORD\"}}" >/dev/null
admin_token=$(post "$SERVER_URL/login" -H 'x-return-tokens: true' \
    -d "{\"username\":\"$ADMIN_USERNAME\",\"password\":\"$ADMIN_PASSWORD\"}" | json "j['user']['accessToken']")
auth=(-H "Authorization: Bearer $admin_token")

library_id=$(post "$SERVER_URL/api/libraries" "${auth[@]}" \
    -d '{"name":"Fixtures","mediaType":"book","folders":[{"fullPath":"/audiobooks"}],"settings":{"disableWatcher":true}}' |
    json "j['id']")
post "$SERVER_URL/api/users" "${auth[@]}" \
    -d "{\"username\":\"$USERNAME\",\"password\":\"$PASSWORD\",\"type\":\"user\",\"isActive\":true,\"permissions\":{\"accessAllLibraries\":true}}" \
    >/dev/null

post "$SERVER_URL/api/libraries/$library_id/scan" "${auth[@]}" >/dev/null
for _ in $(seq 120); do
    last_scan=$(curl -fsS "${auth[@]}" "$SERVER_URL/api/libraries/$library_id" | json "j.get('lastScan')")
    [ "$last_scan" != "None" ] && break
    sleep 1
done
books=$(curl -fsS "${auth[@]}" "$SERVER_URL/api/libraries/$library_id/items?limit=0" | json "j['total']")
if [ "$books" != "$EXPECTED_BOOKS" ]; then
    echo "error: the scan found $books Books; expected $EXPECTED_BOOKS" >&2
    exit 1
fi
echo "Seeded: Library $library_id with $books Books."

if [ "$serve" -eq 1 ]; then
    cat <<EOF

audiobookshelf 2.37.1 is running until this script is stopped.
  LOGOS_IT_SERVER_URL=$SERVER_URL
  LOGOS_IT_LIBRARY_ID=$library_id
  LOGOS_IT_USERNAME=$USERNAME LOGOS_IT_PASSWORD=$PASSWORD
  LOGOS_IT_ADMIN_USERNAME=$ADMIN_USERNAME LOGOS_IT_ADMIN_PASSWORD=$ADMIN_PASSWORD
EOF
    while docker inspect "$container" >/dev/null 2>&1; do sleep 5; done
    exit 0
fi

# xcodebuild passes TEST_RUNNER_<NAME> to the test process as <NAME>.
export TEST_RUNNER_LOGOS_IT_SERVER_URL="$SERVER_URL"
export TEST_RUNNER_LOGOS_IT_LIBRARY_ID="$library_id"
export TEST_RUNNER_LOGOS_IT_USERNAME="$USERNAME"
export TEST_RUNNER_LOGOS_IT_PASSWORD="$PASSWORD"
export TEST_RUNNER_LOGOS_IT_ADMIN_USERNAME="$ADMIN_USERNAME"
export TEST_RUNNER_LOGOS_IT_ADMIN_PASSWORD="$ADMIN_PASSWORD"

if [ "$ui" -eq 1 ]; then
    echo "Running the UI smoke test on $DEVICE..."
    result="$work/SmokeTests.xcresult"
    xcodebuild test \
        -project Logos.xcodeproj \
        -scheme LogosUITests \
        -destination "platform=iOS Simulator,name=$DEVICE" \
        -derivedDataPath "$DERIVED_DATA" \
        -disableAutomaticPackageResolution \
        -resultBundlePath "$result" \
        -only-testing:LogosUITests/SmokeTests \
        -quiet \
        "$@"
else
    echo "Running IntegrationTests on $DEVICE..."
    result="$work/IntegrationTests.xcresult"
    (
        cd LogosKit
        xcodebuild test \
            -scheme LogosKit \
            -destination "platform=iOS Simulator,name=$DEVICE" \
            -derivedDataPath "../$DERIVED_DATA" \
            -disableAutomaticPackageResolution \
            -resultBundlePath "$result" \
            -only-testing:IntegrationTests \
            -quiet \
            "$@"
    )
fi

# A misconfigured run would skip the Server tests and still pass, so a skip counts as a failure.
summary=$(xcrun xcresulttool get test-results summary --path "$result")
passed=$(json "j['passedTests']" <<<"$summary")
skipped=$(json "j['skippedTests']" <<<"$summary")
if [ "$skipped" != "0" ] || [ "$passed" = "0" ]; then
    echo "error: $passed tests passed and $skipped were skipped; none may be skipped" >&2
    exit 1
fi
echo "Tests passed ($passed)."
