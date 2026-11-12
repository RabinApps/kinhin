#!/bin/bash
# Fails on any compiler warning or error in this repo's own Sources/ and Tests/.
#
# Builds the package and its test targets from scratch in a separate scratch path (.build/warnings), because an
# incremental build only re-prints warnings for files it recompiles. Third-party warnings (for example a dependency's
# deprecated Package.swift platform) are not ours to fix and are ignored: only diagnostics located in
# Sources/ or Tests/ count.
#
#   scripts/warnings-check.sh          clean build in .build/warnings, then scan
#   scripts/warnings-check.sh --warm   keep the previous scratch build (fast, but only recompiled files re-report)
set -euo pipefail

cd "$(dirname "$0")/.."

scratch=".build/warnings"
if [[ "${1:-}" != "--warm" ]]; then
    rm -rf "$scratch"
fi

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

if ! swift build --build-system swiftbuild --build-tests --scratch-path "$scratch" >"$log" 2>&1; then
    sed 's/\x1b\[[0-9;]*m//g' "$log" | tail -40
    echo "warnings check: build failed" >&2
    exit 1
fi

root="$PWD"
found="$(sed 's/\x1b\[[0-9;]*m//g; s/\x1b\]8;;[^\x1b]*\x1b\\//g' "$log" |
    grep -E "^${root}/(Sources|Tests)/[^ ]*: (warning|error):" | sed 's/ \[#.*//' | sort -u || true)"

if [[ -n "$found" ]]; then
    echo "$found" | sed "s|^${root}/||"
    echo "warnings check: $(echo "$found" | wc -l | tr -d ' ') warning(s) in Sources/Tests; fix them" >&2
    exit 1
fi
echo "warnings check: clean"
