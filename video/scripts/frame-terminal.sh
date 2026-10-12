#!/bin/bash
# Puts the terminal clip in a macOS-style window (rounded corners, title bar with the three dots, soft shadow)
# on the same backdrop as the MacBook shot, so the two scenes match. Pure ffmpeg, like frame-app.sh.
#
# Usage: video/scripts/frame-terminal.sh [in] [out]     defaults: raw/install.mp4 (else reference/install.mp4)  out/install-framed.mp4
set -euo pipefail
cd "$(dirname "$0")/.."
[ -d /opt/homebrew/opt/ffmpeg-full/bin ] && export PATH="/opt/homebrew/opt/ffmpeg-full/bin:$PATH"
if [ -n "${1:-}" ]; then IN="$1"; elif [ -f raw/install.mp4 ]; then IN=raw/install.mp4; else IN=reference/install.mp4; fi
OUT="${2:-out/install-framed.mp4}"
mkdir -p "$(dirname "$OUT")"
LEN="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$IN")"

CW=1560; CH=878; TB=46; WW=$CW; WH=$((CH + TB)); R=22      # content, title bar, window
M=90   # margin around the shadow layer so the blur can spread outside the window
WX=$(((1920 - WW) / 2)); WY=$(((1080 - WH) / 2 - 10))
ALLR() { echo "a='255*if(gt(abs(X-W/2),W/2-$1)*gt(abs(Y-H/2),H/2-$1),lt(hypot(abs(X-W/2)-(W/2-$1),abs(Y-H/2)-(H/2-$1)),$1),1)'"; }
GEQ() { echo "format=gbrap,geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':$1,format=rgba"; }
dot() { echo "color=c=$1:s=20x20:r=30:d=$LEN,format=rgba,$(GEQ "$(ALLR 10)")"; }

ffmpeg -nostdin -y -loglevel error -i "$IN" \
  -f lavfi -i "gradients=speed=0.00001:s=1920x1080:r=30:d=$LEN:c0=0xffffff:c1=0xe6ebf5:x0=0:y0=0:x1=0:y1=1080:type=linear" \
  -f lavfi -i "color=c=0xe9e8e8:s=${WW}x${TB}:r=30:d=$LEN" \
  -f lavfi -i "$(dot 0xff5f57)" -f lavfi -i "$(dot 0xfebc2e)" -f lavfi -i "$(dot 0x28c840)" \
  -filter_complex "
    [0:v]scale=${CW}:${CH},format=rgba[body];
    [1:v]format=rgba[bg];
    [2:v]format=rgba[bar];
    [bar][3:v]overlay=24:13:format=auto[b1];[b1][4:v]overlay=54:13:format=auto[b2];[b2][5:v]overlay=84:13:format=auto[bar2];
    color=c=white:s=${WW}x${WH}:r=30:d=$LEN,format=rgba[win0];
    [win0][bar2]overlay=0:0:format=auto[win1];
    [win1][body]overlay=0:${TB}:format=auto,$(GEQ "$(ALLR $R)")[win];
    [win]split[w][ws];
    [ws]alphaextract,pad=$((WW + 2 * M)):$((WH + 2 * M)):$M:$M:color=black,boxblur=lr=30:lp=6,lutyuv=y='val*0.34'[sa];
    color=c=black:s=$((WW + 2 * M))x$((WH + 2 * M)):r=30:d=$LEN,format=rgba[sc];
    [sc][sa]alphamerge[shadow];
    [bg][shadow]overlay=$((WX - M)):$((WY + 34 - M)):format=auto[b3];
    [b3][w]overlay=${WX}:${WY}:format=auto,format=yuv420p[v]" \
  -map "[v]" -t "$LEN" -an -c:v libx264 -crf 18 "$OUT"
echo "wrote $OUT"
