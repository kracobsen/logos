#!/bin/bash
# Fails if LogosKit's module graph drifts from the allowed edges, or a third-party dependency
# other than GRDB appears.
#
# Two checks, because Xcode builds every module into one products directory, so an `import`
# of an undeclared module can still compile:
#   1. the manifest's target dependencies equal the allowed edges exactly;
#   2. every `import` of a LogosKit module or GRDB in Sources/<Module> is an allowed edge.
#
# Usage: scripts/check-module-graph.sh
set -euo pipefail

cd "$(dirname "$0")/../LogosKit"

# Allowed edges. Keep in sync with Package.swift and CLAUDE.md.
allowed() {
    case "$1" in
    Domain) echo "" ;;
    ServerAPI) echo "Domain" ;;
    Store) echo "Domain GRDB" ;;
    Sync) echo "Domain ServerAPI Store" ;;
    Downloads) echo "Domain ServerAPI Store" ;;
    Playback) echo "Domain Store" ;;
    UI) echo "Domain Store Sync Downloads Playback" ;;
    *) return 1 ;;
    esac
}
modules="Domain ServerAPI Store Sync Downloads Playback UI"
internal="$modules GRDB"
failed=0

sorted() { tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' '; }

# 1. The manifest.
manifest=$(swift package dump-package)
deps=$(python3 -I -c '
import json, sys
pkg = json.load(sys.stdin)
for dep in pkg["dependencies"]:
    for kind in dep.values():
        for d in kind:
            print("package", d.get("identity", ""))
for t in pkg["targets"]:
    if t["type"] != "regular":
        continue
    names = []
    for d in t["dependencies"]:
        for kind, value in d.items():
            names.append(value[0])
    print("target", t["name"], " ".join(names))
' <<<"$manifest")

packages=$(awk '$1 == "package" { print $2 }' <<<"$deps" | sorted)
if [ "$packages" != "grdb.swift " ]; then
    echo "error: third-party dependencies are [$packages]; only GRDB is allowed. A new dependency needs an ADR." >&2
    failed=1
fi

for module in $modules; do
    declared=$(awk -v m="$module" '$1 == "target" && $2 == m { $1 = ""; $2 = ""; print }' <<<"$deps" | sorted)
    expected=$(allowed "$module" | sorted)
    if [ "$declared" != "$expected" ]; then
        echo "error: Package.swift gives $module dependencies [$declared]; allowed: [$expected]" >&2
        failed=1
    fi
done

targets=$(awk '$1 == "target" { print $2 }' <<<"$deps" | sorted)
if [ "$targets" != "$(echo "$modules" | sorted)" ]; then
    echo "error: LogosKit targets are [$targets]; expected [$modules]. Update this script and CLAUDE.md with the new edges." >&2
    failed=1
fi

# 2. The imports.
for module in $modules; do
    expected=" $(allowed "$module") "
    while IFS=: read -r file line imported; do
        [ -z "$file" ] && continue
        case " $internal " in *" $imported "*) ;; *) continue ;; esac
        case "$expected" in *" $imported "*) ;; *)
            echo "error: $file:$line: $module must not import $imported" >&2
            failed=1
            ;;
        esac
    done < <(grep -rnE '^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+((struct|class|enum|protocol|func|var|let|typealias)[[:space:]]+)?[A-Za-z_]+' \
        "Sources/$module" --include='*.swift' |
        sed -E 's/^([^:]+):([0-9]+):[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+((struct|class|enum|protocol|func|var|let|typealias)[[:space:]]+)?([A-Za-z_]+).*/\1:\2:\6/')
done

if [ "$failed" -ne 0 ]; then
    exit 1
fi
echo "Module graph OK."
