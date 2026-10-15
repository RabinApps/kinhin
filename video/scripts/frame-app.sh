#!/bin/bash
# Puts the app clip on a MacBook: the window sits on a desktop with a menu bar inside a notched screen, in a
# lid on a base. The laptop is tilted in perspective and slides in from the right over the theme's backdrop.
# Everything is drawn by ffmpeg (no Apple artwork, no logos), so it is safe to publish. Colours, frame size and
# scale come from the project's theme and format (scripts/project.mjs --env).
# Needs the `perspective` and `gradients` filters (stock builds have both).
#
# Usage: video/scripts/frame-app.sh <in> [out] [start-seconds] [length-seconds]
#   defaults: out/app-framed.mp4, start 2, length 14. scripts/frames.mjs passes everything for each device scene.
# Env:   SPEED  playback speed of the demo (default 1)
#        SLIDE  seconds for the slide-in (default 2.5)   TILT  starting yaw in radians (default 0.5)
set -euo pipefail
cd "$(dirname "$0")/.."
[ -d /opt/homebrew/opt/ffmpeg-full/bin ] && export PATH="/opt/homebrew/opt/ffmpeg-full/bin:$PATH"
[ -n "${VIDEO_W:-}" ] || eval "$(node scripts/project.mjs --env)"
IN="${1:?usage: frame-app.sh <in> [out] [start] [length]}"
OUT="${2:-out/app-framed.mp4}"
SS="${3:-2}"
LEN="${4:-14}"
SPEED="${SPEED:-1}"
SLIDE="${SLIDE:-2.5}"; TILT="${TILT:-0.5}"
mkdir -p "$(dirname "$OUT")"

W="$VIDEO_W"; H="$VIDEO_H"
sc() { python3 -c "print(max(1, round($1 * $VIDEO_FIT)))"; }   # a 1920x1080 design size, scaled to this format
# Geometry (px on the canvas, before the perspective).
SW=$(sc 1320); SH=$(sc 825)            # screen
BZ=$(sc 16)                            # bezel
LW=$((SW + 2 * BZ)); LH=$((SH + 2 * BZ))   # lid
BW=$(sc 1520); BH=$(sc 28)             # base
WH=$(sc 752); WW=$((WH * 1600 / 1256)) # app window, 1600x1256 source
MB=$(sc 32)                            # menu bar
WX=$(((SW - WW) / 2)); WY=$((MB + (SH - MB - WH) / 2))
LX=$(((W - BW) / 2)); LY=$(((H - (LH + BH - 2)) / 2))
M=$(sc 60)                             # margin around a shadow layer so its blur can spread

# Alpha masks as geq expressions: all corners rounded, or only the bottom ones.
ALLR() { echo "a='255*if(gt(abs(X-W/2),W/2-$1)*gt(abs(Y-H/2),H/2-$1),lt(hypot(abs(X-W/2)-(W/2-$1),abs(Y-H/2)-(H/2-$1)),$1),1)'"; }
BOTR() { echo "a='255*if(gt(abs(X-W/2),W/2-$1)*gt(Y,H-$1),lt(hypot(abs(X-W/2)-(W/2-$1),Y-(H-$1)),$1),1)'"; }
GEQ() { echo "format=gbrap,geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':$1,format=rgba"; }

# Animation in terms of the output frame number `on` (30 fps): ease-out slide, yaw that settles then sways.
T='(on/30)'
E="(1-pow(1-min($T/$SLIDE,1),3))"
TH="($TILT*(1-$E)+0.10*sin(0.6*$T)*$E)"
D=$(sc 3000); HW=$((W / 2)); HH=$((H / 2))
CX="($HW+$(sc 1500)*(1-$E))"
# Portrait and square frames put the laptop high, leaving the lower part for the captions.
if [ "${VIDEO_NARROW:-0}" = 1 ]; then CY=$((H * 36 / 100)); else CY=$((HH - $(sc 60))); fi
# `perspective` maps the whole canvas, so project its corners (offset u scales by D/(D-u*sin th)).
SL="($D/($D+$HW*sin($TH)))"; SR="($D/($D-$HW*sin($TH)))"
XL="($CX-$HW*cos($TH)*$SL)"; XR="($CX+$HW*cos($TH)*$SR)"
Y0L="($CY-$HH*$SL)"; Y1L="($CY+$HH*$SL)"; Y0R="($CY-$HH*$SR)"; Y1R="($CY+$HH*$SR)"

SRC_LEN="$(python3 -c "print($LEN * $SPEED)")"   # seconds of the recording that fill LEN seconds at SPEED
# The top-left toolbar button is covered with the toolbar's own colour (0x29282b), so the cover reads as empty toolbar.
ffmpeg -nostdin -y -loglevel error -ss "$SS" -t "$SRC_LEN" -i "$IN" \
  -f lavfi -i "gradients=speed=0.00001:s=${W}x${H}:r=30:d=$LEN:c0=$BG_FROM:c1=$BG_TO:x0=0:y0=0:x1=0:y1=${H}:type=linear" \
  -f lavfi -i "gradients=speed=0.00001:s=${SW}x${SH}:r=30:d=$LEN:c0=$WALL_FROM:c1=$WALL_TO:x0=0:y0=0:x1=${SW}:y1=${SH}:type=linear" \
  -f lavfi -i "color=c=$LID_COLOR:s=${LW}x${LH}:r=30:d=$LEN" \
  -f lavfi -i "gradients=speed=0.00001:s=${BW}x${BH}:r=30:d=$LEN:c0=$BASE_FROM:c1=$BASE_TO:x0=0:y0=0:x1=0:y1=${BH}:type=linear" \
  -f lavfi -i "color=c=$THUMB_COLOR:s=$(sc 250)x$(sc 18):r=30:d=$LEN" \
  -f lavfi -i "color=c=$LID_COLOR:s=$(sc 170)x$(sc 50):r=30:d=$LEN" \
  -f lavfi -i "color=c=black@0:s=${W}x${H}:r=30:d=$LEN,format=rgba" \
  -filter_complex "
    [0:v]setpts=PTS/${SPEED},fps=30,drawbox=x=14:y=6:w=130:h=48:color=0x29282b:t=fill,scale=${WW}:${WH},format=rgba,$(GEQ "$(ALLR "$(sc 34)")")[win];
    [win]split[w1][w2];
    [w2]alphaextract,pad=$((WW + 2 * M)):$((WH + 2 * M)):$M:$M:color=black,boxblur=lr=$(sc 16):lp=4,lutyuv=y='val*0.5'[wsa];
    color=c=black:s=$((WW + 2 * M))x$((WH + 2 * M)):r=30:d=$LEN,format=rgba[wsc];
    [wsc][wsa]alphamerge[wsh];
    [2:v]format=rgba,drawbox=x=0:y=0:w=${SW}:h=${MB}:color=black@0.28:t=fill[wall];
    [wall][wsh]overlay=$((WX - M)):$((WY + $(sc 16) - M)):format=auto[s1];
    [s1][w1]overlay=${WX}:${WY}:format=auto[s2];
    [6:v]format=rgba,$(GEQ "$(ALLR "$(sc 12)")")[notch];
    [s2][notch]overlay=(W-w)/2:-$(sc 26):format=auto,$(GEQ "$(ALLR "$(sc 26)")")[screen];
    [3:v]format=rgba,$(GEQ "$(ALLR "$(sc 40)")")[lid0];
    [lid0][screen]overlay=${BZ}:${BZ}:format=auto[lid];
    [4:v]format=rgba,$(GEQ "$(BOTR "$(sc 18)")")[base0];
    [5:v]format=rgba,$(GEQ "$(BOTR "$(sc 9)")")[thumb];
    [base0][thumb]overlay=(W-w)/2:0:format=auto[base];
    [7:v][base]overlay=${LX}:$((LY + LH - 2)):format=auto[c1];
    [c1][lid]overlay=$(((W - LW) / 2)):${LY}:format=auto,format=yuva444p,
      perspective=x0='${XL}':y0='${Y0L}':x1='${XR}':y1='${Y0R}':x2='${XL}':y2='${Y1L}':x3='${XR}':y3='${Y1R}':sense=destination:eval=frame:interpolation=linear,
      split[fg][sh];
    [sh]lutyuv=a='if(lt(val\\,12)\\,0\\,val)',colorchannelmixer=rr=0:gg=0:bb=0:aa=${SHADOW_ALPHA},boxblur=lr=$(sc 32):lp=6:ar=$(sc 32):ap=6[shadow];
    [1:v]format=yuv420p[bg];
    [bg][shadow]overlay=0:$(sc 46):format=auto[b1];
    [b1][fg]overlay=0:0:format=auto,format=yuv420p[v]" \
  -map "[v]" -an -c:v libx264 -crf 18 "$OUT"
echo "wrote $OUT"
