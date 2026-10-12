#!/bin/bash
# The template adapter's app recorder. It meets the contract every adapter's `record-app.sh` meets:
#   write $VIDEO_RAW_DIR/app.mov (a screen recording of your product, ideally a window about 1600x1256)
#   write $VIDEO_RAW_DIR/app.json   {"demoStartsAt": seconds into the file at which the story begins}
# This one makes a drifting gradient with a grid, with ffmpeg, so the pipeline has something to frame. Replace the body with
# whatever records your product: screencapture on a Mac, a Playwright session (scripts/record-web.sh), a script that
# drives your app in a container. Make the story start at a known moment and write that moment into app.json.
# Usage: video/adapters/template/record-app.sh [seconds]
# Env:   VIDEO_RAW_DIR  where to write: an absolute path (scripts/record-clip.mjs passes one); default video/raw/template
set -euo pipefail
cd "$(dirname "$0")/../.."
[ -d /opt/homebrew/opt/ffmpeg-full/bin ] && export PATH="/opt/homebrew/opt/ffmpeg-full/bin:$PATH"
SECONDS_TO_RECORD="${1:-30}"
RAW="${VIDEO_RAW_DIR:-raw/template}"
mkdir -p "$RAW"
ffmpeg -nostdin -y -loglevel error -f lavfi \
  -i "gradients=s=1600x1256:r=30:d=$SECONDS_TO_RECORD:c0=0x4c8bf5:c1=0xa970ff:speed=0.05,drawgrid=w=200:h=157:t=2:c=white@0.25" \
  -c:v libx264 -pix_fmt yuv420p -crf 20 "$RAW/app.mov"
echo '{"demoStartsAt": 0}' > "$RAW/app.json"
echo "wrote $RAW/app.mov"
