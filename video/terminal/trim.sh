#!/bin/bash
# Masks the lines of the `kinhin doctor` output that show an empty config (token, cache path, config path,
# image) by painting over them in the page background, so the clip ends on the passing host checks.
# Usage: terminal/trim.sh [uncut.mp4] [out.mp4]   (run from video/)
# Env:   MASK_Y  pixel row of the top of the `token:` line in the 1920x1080 tape (default 455)
#        BG      page background colour (default white, the Builtin Light theme)
set -euo pipefail
IN="${1:-raw/install-uncut.mp4}"
OUT="${2:-raw/install.mp4}"
MASK_Y="${MASK_Y:-455}"
BG="${BG:-white}"
ffmpeg -v error -y -i "$IN" -vf "drawbox=x=0:y=${MASK_Y}:w=iw:h=ih-${MASK_Y}:color=${BG}:t=fill" \
    -c:v libx264 -pix_fmt yuv420p "$OUT"
echo "wrote $OUT"
