#!/bin/bash
# Paints over everything from a pixel row down in a terminal clip, in the terminal's background colour, so a clip can
# end before output that should not show (an adapter's "hideFromLine"; see scripts/record-terminal.sh).
# Usage: scripts/mask-terminal.sh <uncut.mp4> <out.mp4>
# Env:   MASK_Y  pixel row where the masked area starts (required)
#        BG      terminal background colour (default white, the Builtin Light theme)
set -euo pipefail
IN="${1:?usage: mask-terminal.sh <uncut.mp4> <out.mp4>}"
OUT="${2:?usage: mask-terminal.sh <uncut.mp4> <out.mp4>}"
MASK_Y="${MASK_Y:?set MASK_Y (pixel row where the masked area starts)}"
BG="${BG:-white}"
ffmpeg -v error -y -i "$IN" -vf "drawbox=x=0:y=${MASK_Y}:w=iw:h=ih-${MASK_Y}:color=${BG}:t=fill" \
    -c:v libx264 -pix_fmt yuv420p "$OUT"
echo "wrote $OUT"
