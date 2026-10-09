#!/bin/bash
# Prints the median and worst run of every metric in a performance test result, for recording against
# docs/performance-budgets.md. Worst is the highest value (every budget prefers smaller).
#
# Usage: scripts/perf-results.sh <path/to/result.xcresult>
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
result="${1:?usage: scripts/perf-results.sh <path/to/result.xcresult>}"

xcrun xcresulttool get test-results metrics --path "$result" | python3 -I -c '
import json, statistics, sys

def shown(value, unit):
    return "%.0f ms" % (value * 1000) if unit == "s" else "%.4g %s" % (value, unit)

row = "%-60s %-55s %12s %12s  %s"
print(row % ("Test", "Metric", "Median", "Worst", "Runs"))
for test in json.load(sys.stdin):
    for run in test["testRuns"]:
        for metric in run["metrics"]:
            values = metric["measurements"]
            if values:
                unit = metric["unitOfMeasurement"]
                median, worst = shown(statistics.median(values), unit), shown(max(values), unit)
                print(row % (test["testIdentifier"], metric["displayName"], median, worst, len(values)))
'
