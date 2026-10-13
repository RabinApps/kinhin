#!/bin/bash
# Thread-sanitizer test run: builds with --sanitize thread and runs the whole
# suite SERIALLY. Usage: scripts/tsan.sh [-- <extra swift test args>]
#
# Why serial: under TSan, `--parallel` collides the worker bundles on the
# tests' fixed temp paths (UpdateCheckTests' version-named DMG, scratch
# configs), which fails suites at random — and the default target can exit 0
# mid-run while other bundles are still going. Do not add --parallel here.
#
# Why the exit code still surprises you: under TSan the process exit code
# tracks sanitizer reports, not test results. TSan aborts the run at exit the
# moment it has a report, so a target whose tests ALL PASS still exits 1.
# Read this script's summary to tell the two apart:
#   - "No ThreadSanitizer reports" + test failures  -> real test regression.
#   - reports listed                                -> fix the race.
set -euo pipefail

cd "$(dirname "$0")/.."

LOG=".build/tsan.log"
mkdir -p .build

# Strip a literal `--` so `scripts/tsan.sh -- --filter Foo` forwards the
# filter to swift test instead of passing the separator through as an argv
# element (swift test would reject it). Expand the array with the
# `+`-guarded form: under `set -u`, bash 3.2 treats an empty "${args[@]}"
# as unbound, and the naive workaround (a `:-` default) would insert a
# literal empty-string argument that swift test rejects (exit 64).
args=()
for arg in "$@"; do
    [[ $arg == "--" ]] || args+=("$arg")
done

echo "==> swift test --build-system swiftbuild --sanitize thread (serial; expect a few minutes)"
set +e
swift test --build-system swiftbuild --sanitize thread ${args[@]+"${args[@]}"} 2>&1 | tee "$LOG"
status=${PIPESTATUS[0]}
set -e

echo
echo "==> sanitizer summary"
if grep -q "WARNING: ThreadSanitizer" "$LOG"; then
    echo "ThreadSanitizer reports (grouped by SUMMARY):"
    grep "SUMMARY: ThreadSanitizer" "$LOG" | sort | uniq -c | sort -rn | sed 's/^/  /'
    echo "Full stacks: $LOG"
    echo "  -> fix the race (see the Style section of CONTRIBUTING.md)."
    exit 1
else
    echo "No ThreadSanitizer reports."
    if [ "$status" -ne 0 ]; then
        echo "Test failures (exit $status):"
        grep -E "error: -\[" "$LOG" | sed 's/^/  /' | head -20
    fi
    exit "$status"
fi
