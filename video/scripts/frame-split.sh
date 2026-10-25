#!/bin/bash
# Puts two clips side by side in windows (one above the other in a portrait or square frame): rounded corners, an optional
# title bar with the three dots, a soft shadow, over the project's backdrop. Pure ffmpeg, like frame-terminal.sh; colours,
# frame size and scale come from the theme and format (scripts/project.mjs --env).
#
# Usage: video/scripts/frame-split.sh <left> <right> <out> <length> [left-delay] [right-delay] [left-bar] [right-bar] [ratio]
#   delay  seconds a clip waits on its first frame before it plays (default 0), to line one up with the other
#   bar    1 puts the clip under a title bar (terminals, browsers), 0 leaves it as it is (an app window with its own) (default 1)
#   ratio  the left or top window's share of the room, 0.3 to 0.7 (default 0.5)
# scripts/frames.mjs passes everything for each split scene; each clip arrives already cut to the scene's length by the camera
# pass when it needed one.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -d /opt/homebrew/opt/ffmpeg-full/bin ] && export PATH="/opt/homebrew/opt/ffmpeg-full/bin:$PATH"
[ -n "${VIDEO_W:-}" ] || eval "$(node scripts/project.mjs --env)"
IN_L="${1:?usage: frame-split.sh <left> <right> <out> <length> [left-delay] [right-delay] [left-bar] [right-bar] [ratio]}"
IN_R="${2:?usage: frame-split.sh <left> <right> <out> <length> ...}"
OUT="${3:?usage: frame-split.sh <left> <right> <out> <length> ...}"
LEN="${4:?usage: frame-split.sh <left> <right> <out> <length> ...}"
DELAY_L="${5:-0}"; DELAY_R="${6:-0}"
BAR_L="${7:-1}"; BAR_R="${8:-1}"
RATIO="${9:-0.5}"
mkdir -p "$(dirname "$OUT")"

W="$VIDEO_W"; H="$VIDEO_H"
size() { ffprobe -v error -select_streams v -show_entries stream=width,height -of csv=p=0:s=x "$1"; }

# Where each window goes, worked out once: the clip is scaled to fit its share of the room and the window hugs it.
# Prints: CW_L CH_L X_L Y_L CW_R CH_R X_R Y_R TB (content size, window position, title bar height). The sizes and the layout are
# plain assignments, so a clip ffprobe cannot read stops the script with its message (a process substitution would not).
SIZE_L="$(size "$IN_L")"
SIZE_R="$(size "$IN_R")"
read -r -d '' LAYOUT_PY <<'PY' || true
import sys
w, h, fit, narrow, ratio, bar_l, bar_r = int(sys.argv[1]), int(sys.argv[2]), float(sys.argv[3]), sys.argv[4] == '1', float(sys.argv[5]), int(sys.argv[6]), int(sys.argv[7])
clips = [tuple(int(v) for v in s.split('x')) for s in sys.argv[8:10]]
bars = [bar_l, bar_r]
sc = lambda v: max(1, round(v * fit))
tb, margin, gap = sc(46), sc(60), sc(40)
even = lambda v: max(2, int(v) // 2 * 2)
shares = [ratio, 1 - ratio]
out = []
if not narrow:
    # The bottom of the frame is kept for the captions (about 16%), so a tall clip's window never runs into them.
    reserve = max(margin, round(h * 0.16))
    room_w, room_h = w - 2 * margin - gap, h - margin - reserve
    col_x = margin
    for i, (cw0, ch0) in enumerate(clips):
        col_w = room_w * shares[i]
        top = tb * bars[i]
        s = min(col_w / cw0, (room_h - top) / ch0)
        cw, ch = even(cw0 * s), even(ch0 * s)
        out += [cw, ch, round(col_x + (col_w - cw) / 2), round(margin + (room_h - (ch + top)) / 2)]
        col_x += col_w + gap
else:
    # Stacked: the top 72% of the frame is for the windows, the rest for the captions.
    top_y, room_h = round(h * 0.05), h * 0.72
    room_w = w * 0.9
    band_y = top_y
    for i, (cw0, ch0) in enumerate(clips):
        band_h = (room_h - gap) * shares[i]
        top = tb * bars[i]
        s = min(room_w / cw0, (band_h - top) / ch0)
        cw, ch = even(cw0 * s), even(ch0 * s)
        out += [cw, ch, round((w - cw) / 2), round(band_y + (band_h - (ch + top)) / 2)]
        band_y += band_h + gap
print(*out, tb)
PY
LAYOUT="$(python3 -c "$LAYOUT_PY" "$W" "$H" "$VIDEO_FIT" "${VIDEO_NARROW:-0}" "$RATIO" "$BAR_L" "$BAR_R" "$SIZE_L" "$SIZE_R")"
read -r CW_L CH_L X_L Y_L CW_R CH_R X_R Y_R TB <<<"$LAYOUT"

R=$(python3 -c "print(max(4, round(18 * $VIDEO_FIT)))")
M=$(python3 -c "print(max(8, round(90 * $VIDEO_FIT)))")      # margin around a shadow layer so its blur can spread
DOT=$(python3 -c "print(max(4, round(16 * $VIDEO_FIT)))")
DX=$(python3 -c "print(max(1, round(20 * $VIDEO_FIT)))")      # the dots: first one's inset and the step between them
SHBLUR=$(python3 -c "print(max(2, round(30 * $VIDEO_FIT)))")
SHDROP=$(python3 -c "print(max(2, round(28 * $VIDEO_FIT)))")

ALLR() { echo "a='255*if(gt(abs(X-W/2),W/2-$1)*gt(abs(Y-H/2),H/2-$1),lt(hypot(abs(X-W/2)-(W/2-$1),abs(Y-H/2)-(H/2-$1)),$1),1)'"; }
GEQ() { echo "format=gbrap,geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':$1,format=rgba"; }
dot() { echo "color=c=$1:s=${DOT}x${DOT}:r=30:d=$LEN,format=rgba,$(GEQ "$(ALLR $((DOT / 2)))")"; }

# One window: input $1 (0 or 1), content size $2x$3, bar $4, delay $5, label prefix $6. Makes [$6win] and [$6shadow].
panel() {
  local i="$1" cw="$2" ch="$3" bar="$4" delay="$5" p="$6" top=0 wh
  [ "$bar" = 1 ] && top="$TB"
  wh=$((ch + top))
  echo "[$i:v]fps=30,tpad=start_mode=clone:start_duration=$delay,tpad=stop_mode=clone:stop_duration=60,trim=duration=$LEN,setpts=PTS-STARTPTS,scale=${cw}:${ch},format=rgba[${p}body];"
  echo "color=c=$BODY_COLOR:s=${cw}x${wh}:r=30:d=$LEN,format=rgba[${p}win0];"
  if [ "$bar" = 1 ]; then
    echo "color=c=$BAR_COLOR:s=${cw}x${top}:r=30:d=$LEN,format=rgba[${p}bar0];"
    echo "$(dot 0xff5f57)[${p}d1];$(dot 0xfebc2e)[${p}d2];$(dot 0x28c840)[${p}d3];"
    echo "[${p}bar0][${p}d1]overlay=$((DX)):$(((top - DOT) / 2)):format=auto[${p}b1];[${p}b1][${p}d2]overlay=$((DX * 5 / 2)):$(((top - DOT) / 2)):format=auto[${p}b2];[${p}b2][${p}d3]overlay=$((DX * 4)):$(((top - DOT) / 2)):format=auto[${p}bar];"
    echo "[${p}win0][${p}bar]overlay=0:0:format=auto[${p}win1];"
  else
    echo "[${p}win0]null[${p}win1];"
  fi
  echo "[${p}win1][${p}body]overlay=0:${top}:format=auto,$(GEQ "$(ALLR "$R")")[${p}w];"
  echo "[${p}w]split[${p}win][${p}ws];"
  echo "[${p}ws]alphaextract,pad=$((cw + 2 * M)):$((wh + 2 * M)):$M:$M:color=black,boxblur=lr=${SHBLUR}:lp=6,lutyuv=y='val*$SHADOW_ALPHA*1.2'[${p}sa];"
  echo "color=c=black:s=$((cw + 2 * M))x$((wh + 2 * M)):r=30:d=$LEN,format=rgba[${p}sc];"
  echo "[${p}sc][${p}sa]alphamerge[${p}shadow];"
}

GRAPH="gradients=speed=0.00001:s=${W}x${H}:r=30:d=$LEN:c0=$BG_FROM:c1=$BG_TO:x0=0:y0=0:x1=0:y1=${H}:type=linear,format=rgba[bg];
$(panel 0 "$CW_L" "$CH_L" "$BAR_L" "$DELAY_L" L)
$(panel 1 "$CW_R" "$CH_R" "$BAR_R" "$DELAY_R" R)
[bg][Lshadow]overlay=$((X_L - M)):$((Y_L + SHDROP - M)):format=auto[b1];
[b1][Rshadow]overlay=$((X_R - M)):$((Y_R + SHDROP - M)):format=auto[b2];
[b2][Lwin]overlay=${X_L}:${Y_L}:format=auto[b3];
[b3][Rwin]overlay=${X_R}:${Y_R}:format=auto,format=yuv420p[v]"

ffmpeg -nostdin -y -loglevel error -i "$IN_L" -i "$IN_R" -filter_complex "$GRAPH" \
  -map "[v]" -t "$LEN" -an -c:v libx264 -crf 18 "$OUT"
echo "wrote $OUT"
