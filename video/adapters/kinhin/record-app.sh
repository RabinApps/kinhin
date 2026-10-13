#!/bin/bash
# The kinhin adapter's app recorder: records the kinhin window running the scripted demo fleet (macOS, Apple Silicon).
# This is the contract an adapter's `record-app.sh` meets: write <raw dir>/app.mov and app.json ({"demoStartsAt": seconds}).
# Needs Screen Recording + Accessibility permission for your terminal.
#
# Usage: video/adapters/kinhin/record-app.sh [seconds]    (default 80: the demo starts ~15 s in and plays 48 s)
# Env:   KINHIN_DEMO  demo script: a built-in name (default "launch") or a repo-relative/absolute .json path
#        VIDEO_RAW_DIR  where the clip goes (default video/raw/kinhin); it writes app.mov and app.json there
#        VIDEO_OUT      output file instead of <VIDEO_RAW_DIR>/app.mov
# Output: video/raw/kinhin/app.mov
set -euo pipefail
cd "$(dirname "$0")/../../.."   # the repository root

SECONDS_TO_RECORD="${1:-80}"
DEMO="${KINHIN_DEMO:-launch}"
OUT="${VIDEO_OUT:-${VIDEO_RAW_DIR:-video/raw/kinhin}/app.mov}"
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"   # screencapture will not overwrite
SUPPORT_DIR="$(mktemp -d)"

echo "==> building the demo app"
swift build --product kinhin-app >/dev/null
# The demo script starts at a fixed moment (the app idles until then), so frame-app.sh knows where in the
# recording the story begins: app.json holds that moment and when the recording started.
now() { python3 -c 'import time; print(f"{time.time():.3f}")'; }
ORIGIN="$(python3 -c 'import time; print(f"{time.time() + 15:.3f}")')"
echo "==> launching the demo app (KINHIN_DEMO=$DEMO)"
KINHIN_SUPPORT_DIR="$SUPPORT_DIR" KINHIN_DEMO="$DEMO" KINHIN_DEMO_ORIGIN="$ORIGIN" scripts/dev-run.sh --env-tokens &
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

echo "==> recording window $WID for ${SECONDS_TO_RECORD}s (keep the mouse pointer off the window)"
REC_START="$(now)"
screencapture -x -o -v -V "$SECONDS_TO_RECORD" -l"$WID" "$OUT"
# Seconds into the file at which the demo script begins. screencapture starts writing about 2.2 s after it is
# launched, so the script appears that much later than the wall clock says.
python3 - "$ORIGIN" "$REC_START" "${OUT%.*}.json" <<'PY'
import json, sys
origin, rec = float(sys.argv[1]), float(sys.argv[2])
json.dump({"demoStartsAt": round(max(0.0, origin - rec) + 2.2, 2)}, open(sys.argv[3], "w"))
PY
echo "==> wrote $OUT"
