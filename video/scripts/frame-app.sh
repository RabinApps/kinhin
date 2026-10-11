#!/bin/bash
# PROTOTYPE: puts the app clip in a bezel with rounded corners and a soft shadow, tilts it in perspective,
# and slides it in from the right on a light background. Pure ffmpeg (needs the `perspective` and `gradients`
# filters, both in a stock build). Not wired into export.sh yet.
#
# Usage: video/scripts/frame-app.sh [in] [out] [start-seconds] [length-seconds]
#   defaults: raw/app.mov  out/app-framed.mp4  2  14
# Env:   SLIDE  seconds for the slide-in (default 2.5)   TILT  starting yaw in radians (default 0.5)
set -euo pipefail
cd "$(dirname "$0")/.."
[ -d /opt/homebrew/opt/ffmpeg-full/bin ] && export PATH="/opt/homebrew/opt/ffmpeg-full/bin:$PATH"
IN="${1:-raw/app.mov}"; OUT="${2:-out/app-framed.mp4}"; SS="${3:-2}"; LEN="${4:-14}"
SLIDE="${SLIDE:-2.5}"; TILT="${TILT:-0.5}"
mkdir -p "$(dirname "$OUT")"

# Framed size: a 1000-px-wide window plus an 18-px bezel on each side (window aspect 1600x1256 -> 1000x785).
VW=1000; VH=785; B=18; FW=$((VW + 2 * B)); FH=$((VH + 2 * B)); R=44

# Animation, in terms of the output frame number `on` (30 fps): ease-out slide, yaw that settles then sways.
T='(on/30)'
E="(1-pow(1-min($T/$SLIDE,1),3))"
TH="($TILT*(1-$E)+0.10*sin(0.6*$T)*$E)"
D=2400   # viewing distance in px: smaller exaggerates the perspective
CX="(960+1300*(1-$E))"; CY=540
# Yaw about the vertical axis. `perspective` maps the whole 1920x1080 canvas (the framed window sits at its
# centre), so project the canvas corners: a point at horizontal offset u from the centre scales by D/(D-u*sin(th)).
SL="($D/($D+960*sin($TH)))"; SR="($D/($D-960*sin($TH)))"
XL="($CX-960*cos($TH)*$SL)"; XR="($CX+960*cos($TH)*$SR)"
Y0L="($CY-540*$SL)"; Y1L="($CY+540*$SL)"
Y0R="($CY-540*$SR)"; Y1R="($CY+540*$SR)"

MASK="a='255*if(gt(abs(X-W/2),W/2-$R)*gt(abs(Y-H/2),H/2-$R),lt(hypot(abs(X-W/2)-(W/2-$R),abs(Y-H/2)-(H/2-$R)),$R),1)'"

ffmpeg -nostdin -y -loglevel error -ss "$SS" -t "$LEN" -i "$IN" \
  -f lavfi -i "gradients=s=1920x1080:r=30:d=$LEN:c0=0xffffff:c1=0xe6ebf5:x0=0:y0=0:x1=0:y1=1080:type=linear" \
  -filter_complex "
    [0:v]fps=30,scale=${VW}:${VH},pad=${FW}:${FH}:${B}:${B}:color=0x1d1d1f,format=yuva444p,
         geq=lum='lum(X,Y)':cb='cb(X,Y)':cr='cr(X,Y)':${MASK},
         pad=1920:1080:(ow-iw)/2:(oh-ih)/2:color=0x00000000,
         perspective=x0='${XL}':y0='${Y0L}':x1='${XR}':y1='${Y0R}':x2='${XL}':y2='${Y1L}':x3='${XR}':y3='${Y1R}':sense=destination:eval=frame:interpolation=linear,
         split[fg][sh];
    [sh]colorchannelmixer=rr=0:gg=0:bb=0:aa=0.30,boxblur=32:6[shadow];
    [1:v]format=yuv420p[bg];
    [bg][shadow]overlay=0:46:format=auto[b1];
    [b1][fg]overlay=0:0:format=auto,format=yuv420p[v]" \
  -map "[v]" -an -c:v libx264 -crf 18 "$OUT"
echo "wrote $OUT"
