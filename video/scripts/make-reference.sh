#!/bin/bash
# Refreshes video/reference/ from your own recordings, so people without a Mac can still rebuild the video:
#   reference/app.mp4 + app.json   the demo fleet, trimmed to start at the first job and compressed
#   reference/install*.mp4         the terminal clips: install, install-dark, install-portrait, install-dark-portrait
#                                  (scripts/record-terminal.sh --all)
# Run it after record.sh and the vhs tape. The clips are small (a few MB) and are committed.
# Usage: video/scripts/make-reference.sh [--terminal] [seconds of demo to keep, default 42]
#   --terminal  refresh only the terminal clips
set -euo pipefail
cd "$(dirname "$0")/.."
[ -d /opt/homebrew/opt/ffmpeg-full/bin ] && export PATH="/opt/homebrew/opt/ffmpeg-full/bin:$PATH"
TERMINAL_ONLY=0; [ "${1:-}" = --terminal ] && { TERMINAL_ONLY=1; shift; }
KEEP="${1:-42}"
if [ "$TERMINAL_ONLY" = 0 ]; then
START="$(node -e "console.log(JSON.parse(require('fs').readFileSync('raw/app.json','utf8')).demoStartsAt)")"
mkdir -p reference
ffmpeg -nostdin -y -loglevel error -ss "$START" -t "$KEEP" -i raw/app.mov \
  -vf "scale=1280:-2,fps=30" -c:v libx264 -crf 29 -preset slow -pix_fmt yuv420p -an -movflags +faststart reference/app.mp4
echo '{"demoStartsAt": 0}' > reference/app.json
fi
mkdir -p reference
for f in raw/install*.mp4; do case "$f" in *-uncut.mp4) ;; *) cp "$f" reference/ ;; esac; done
ls -l reference
