#!/bin/bash
# Puts the terminal clip in a macOS-style window (rounded corners, title bar with the three dots, soft shadow)
# over the project's backdrop, so it matches the laptop shot. Pure ffmpeg, like frame-app.sh; colours, frame size
# and scale come from the theme and format (scripts/project.mjs --env).
#
# Usage: video/scripts/frame-terminal.sh [in] [out] [length-seconds]
#   defaults: raw/install.mp4 (else reference/install.mp4)  out/install-framed.mp4  the clip's own length
set -euo pipefail
cd "$(dirname "$0")/.."
[ -d /opt/homebrew/opt/ffmpeg-full/bin ] && export PATH="/opt/homebrew/opt/ffmpeg-full/bin:$PATH"
[ -n "${VIDEO_W:-}" ] || eval "$(node scripts/project.mjs --env)"
if [ -n "${1:-}" ]; then IN="$1"; elif [ -f raw/install.mp4 ]; then IN=raw/install.mp4; else IN=reference/install.mp4; fi
OUT="${2:-out/install-framed.mp4}"
mkdir -p "$(dirname "$OUT")"
LEN="${3:-$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$IN")}"

W="$VIDEO_W"; H="$VIDEO_H"
sc() { python3 -c "print(max(1, round($1 * $VIDEO_FIT)))"; }
CLIP_W="$(ffprobe -v error -select_streams v -show_entries stream=width -of csv=p=0 "$IN")"
CLIP_H="$(ffprobe -v error -select_streams v -show_entries stream=height -of csv=p=0 "$IN")"
if [ "${VIDEO_NARROW:-0}" = 1 ]; then CW=$((W * 92 / 100)); else CW=$(sc 1560); fi   # content width
CH=$((CW * CLIP_H / CLIP_W)); TB=$(sc 46); WW=$CW; WH=$((CH + TB)); R=$(sc 22)         # content, title bar, window
M=$(sc 90)   # margin around the shadow layer so the blur can spread outside the window
WX=$(((W - WW) / 2))
# Portrait and square frames put the window high, leaving the lower part for the captions.
if [ "${VIDEO_NARROW:-0}" = 1 ]; then WY=$((H * 8 / 100)); else WY=$(((H - WH) / 2 - $(sc 10))); fi
DOT=$(sc 20)
ALLR() { echo "a='255*if(gt(abs(X-W/2),W/2-$1)*gt(abs(Y-H/2),H/2-$1),lt(hypot(abs(X-W/2)-(W/2-$1),abs(Y-H/2)-(H/2-$1)),$1),1)'"; }
GEQ() { echo "format=gbrap,geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':$1,format=rgba"; }
dot() { echo "color=c=$1:s=${DOT}x${DOT}:r=30:d=$LEN,format=rgba,$(GEQ "$(ALLR $((DOT / 2)))")"; }

ffmpeg -nostdin -y -loglevel error -i "$IN" \
  -f lavfi -i "gradients=speed=0.00001:s=${W}x${H}:r=30:d=$LEN:c0=$BG_FROM:c1=$BG_TO:x0=0:y0=0:x1=0:y1=${H}:type=linear" \
  -f lavfi -i "color=c=$BAR_COLOR:s=${WW}x${TB}:r=30:d=$LEN" \
  -f lavfi -i "$(dot 0xff5f57)" -f lavfi -i "$(dot 0xfebc2e)" -f lavfi -i "$(dot 0x28c840)" \
  -filter_complex "
    [0:v]scale=${CW}:${CH}:force_original_aspect_ratio=decrease,pad=${CW}:${CH}:(ow-iw)/2:(oh-ih)/2:$BODY_COLOR,format=rgba[body];
    [1:v]format=rgba[bg];
    [2:v]format=rgba[bar];
    [bar][3:v]overlay=$(sc 24):$(((TB - DOT) / 2)):format=auto[b1];[b1][4:v]overlay=$(sc 54):$(((TB - DOT) / 2)):format=auto[b2];[b2][5:v]overlay=$(sc 84):$(((TB - DOT) / 2)):format=auto[bar2];
    color=c=$BODY_COLOR:s=${WW}x${WH}:r=30:d=$LEN,format=rgba[win0];
    [win0][bar2]overlay=0:0:format=auto[win1];
    [win1][body]overlay=0:${TB}:format=auto,$(GEQ "$(ALLR "$R")")[win];
    [win]split[w][ws];
    [ws]alphaextract,pad=$((WW + 2 * M)):$((WH + 2 * M)):$M:$M:color=black,boxblur=lr=$(sc 30):lp=6,lutyuv=y='val*$SHADOW_ALPHA*1.2'[sa];
    color=c=black:s=$((WW + 2 * M))x$((WH + 2 * M)):r=30:d=$LEN,format=rgba[sc];
    [sc][sa]alphamerge[shadow];
    [bg][shadow]overlay=$((WX - M)):$((WY + $(sc 34) - M)):format=auto[b3];
    [b3][w]overlay=${WX}:${WY}:format=auto,format=yuv420p[v]" \
  -map "[v]" -t "$LEN" -an -c:v libx264 -crf 18 "$OUT"
echo "wrote $OUT"
