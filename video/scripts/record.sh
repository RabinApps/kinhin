#!/bin/bash
# Records the kinhin window running the scripted demo fleet (macOS, Apple Silicon).
# Needs Screen Recording + Accessibility permission for your terminal.
#
# Usage: video/scripts/record.sh [seconds]    (default 50: one full pass of the 48 s loop)
# Env:   KINHIN_DEMO  demo script: a built-in name (default "launch") or a repo-relative/absolute .json path
#        VIDEO_OUT    output file (default video/raw/app.mov)
# Output: video/raw/app.mov
set -euo pipefail
cd "$(dirname "$0")/../.."

SECONDS_TO_RECORD="${1:-50}"
DEMO="${KINHIN_DEMO:-launch}"
OUT="${VIDEO_OUT:-video/raw/app.mov}"
mkdir -p "$(dirname "$OUT")"
SUPPORT_DIR="$(mktemp -d)"

echo "==> building and launching the demo app (KINHIN_DEMO=$DEMO)"
KINHIN_SUPPORT_DIR="$SUPPORT_DIR" KINHIN_DEMO="$DEMO" scripts/dev-run.sh --env-tokens &
APP_PID=$!
trap 'kill "$APP_PID" 2>/dev/null || true; rm -rf "$SUPPORT_DIR"' EXIT

echo "==> waiting for the kinhin process"
# The debug binary's process and window owner are "kinhin-app" (the bundled app is "kinhin").
PROC=kinhin-app
for _ in $(seq 1 120); do pgrep -x "$PROC" >/dev/null && break; sleep 1; done
pgrep -x "$PROC" >/dev/null || { echo "$PROC did not start" >&2; exit 1; }
sleep 3

# Window id of kinhin's main window (occlusion-proof capture), see shots/tools/winid.swift.
[ -x shots/tools/winid ] || swiftc -O shots/tools/winid.swift -o shots/tools/winid
WID="$(shots/tools/winid "$PROC" || true)"
[ -n "$WID" ] || { echo "no kinhin window; open it from the menu bar item first" >&2; exit 1; }

# A taller window shows the whole Fleet tab without scrolling (needs Accessibility for the terminal).
osascript -e "tell application \"System Events\" to tell process \"$PROC\" to set {position, size} of window 1 to {{300, 40}, {820, 880}}" \
    >/dev/null 2>&1 || echo "(could not resize the window; grant Accessibility to your terminal)" >&2
sleep 1

echo "==> recording window $WID for ${SECONDS_TO_RECORD}s"
screencapture -x -o -v -V "$SECONDS_TO_RECORD" -l"$WID" "$OUT"
echo "==> wrote $OUT"
