#!/bin/bash
# Refreshes video/reference/ from your own recordings, so people without a Mac can still rebuild the video:
#   reference/app.mp4 + app.json   the demo fleet, trimmed to start at the first job and compressed
#   reference/install.mp4          the terminal clip
# Run it after record.sh and the vhs tape. The clips are small (a few MB) and are committed.
# Usage: video/scripts/make-reference.sh [seconds of demo to keep, default 42]
set -euo pipefail
cd "$(dirname "$0")/.."
[ -d /opt/homebrew/opt/ffmpeg-full/bin ] && export PATH="/opt/homebrew/opt/ffmpeg-full/bin:$PATH"
KEEP="${1:-42}"
START="$(node -e "console.log(JSON.parse(require('fs').readFileSync('raw/app.json','utf8')).demoStartsAt)")"
mkdir -p reference
ffmpeg -nostdin -y -loglevel error -ss "$START" -t "$KEEP" -i raw/app.mov \
  -vf "scale=1280:-2,fps=30" -c:v libx264 -crf 29 -preset slow -pix_fmt yuv420p -an -movflags +faststart reference/app.mp4
echo '{"demoStartsAt": 0}' > reference/app.json
cp raw/install.mp4 reference/install.mp4
ls -l reference
