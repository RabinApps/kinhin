#!/bin/bash
# Records the kinhin window running the scripted demo fleet (macOS, Apple Silicon).
# Needs Screen Recording + Accessibility permission for your terminal.
#
# Usage: video/scripts/record.sh [seconds]    (default 50: one full pass of the 48 s loop)
# Output: video/raw/app.mov
set -euo pipefail
cd "$(dirname "$0")/../.."

SECONDS_TO_RECORD="${1:-50}"
mkdir -p video/raw
SUPPORT_DIR="$(mktemp -d)"

echo "==> building and launching the demo app (KINHIN_DEMO=launch)"
KINHIN_SUPPORT_DIR="$SUPPORT_DIR" KINHIN_DEMO=launch scripts/dev-run.sh --env-tokens &
APP_PID=$!
trap 'kill "$APP_PID" 2>/dev/null || true; rm -rf "$SUPPORT_DIR"' EXIT

echo "==> waiting for the kinhin process"
for _ in $(seq 1 120); do pgrep -x kinhin >/dev/null && break; sleep 1; done
pgrep -x kinhin >/dev/null || { echo "kinhin did not start" >&2; exit 1; }
sleep 3

# Window id of kinhin's main window (occlusion-proof capture), see shots/tools/winid.swift.
[ -x shots/tools/winid ] || swiftc -O shots/tools/winid.swift -o shots/tools/winid
WID="$(shots/tools/winid kinhin)"
[ -n "$WID" ] || { echo "no kinhin window; open it from the menu bar item first" >&2; exit 1; }

# Bring the Fleet tab forward; drive.py also captures a still we do not need here.
python3 shots/tools/drive.py fleet demo-fleet >/dev/null

echo "==> recording window $WID for ${SECONDS_TO_RECORD}s"
screencapture -x -o -v -V "$SECONDS_TO_RECORD" -l"$WID" video/raw/app.mov
echo "==> wrote video/raw/app.mov"
