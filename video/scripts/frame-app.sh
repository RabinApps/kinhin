#!/bin/bash
# Puts the app clip on a MacBook: the window sits on a desktop with a menu bar inside a notched screen, in a
# black lid on a silver base. The laptop is tilted in perspective and slides in from the right on a light
# background. Everything is drawn by ffmpeg (no Apple artwork, no logos), so it is safe to publish.
# Needs the `perspective` and `gradients` filters (stock builds have both). Not wired into export.sh yet.
#
# Usage: video/scripts/frame-app.sh [in] [out] [start-seconds] [length-seconds]
#   defaults: raw/app.mov  out/app-framed.mp4; start = raw/app.json's demoStartsAt (written by record.sh);
#   length = the app scene's length in out/timeline.json (scripts/retime.mjs), else 14
# Env:   SPEED  playback speed of the demo (default: the app scene's "speed" in script/launch.json, else 1)
#        SLIDE  seconds for the slide-in (default 2.5)   TILT  starting yaw in radians (default 0.5)
set -euo pipefail
cd "$(dirname "$0")/.."
[ -d /opt/homebrew/opt/ffmpeg-full/bin ] && export PATH="/opt/homebrew/opt/ffmpeg-full/bin:$PATH"
IN="${1:-raw/app.mov}"; OUT="${2:-out/app-framed.mp4}"
# read <file> <js expression over the parsed json `j`> <fallback>
jget() { [ -f "$1" ] && node -e "const j=JSON.parse(require('fs').readFileSync('$1','utf8')); const v=($2); process.stdout.write(String(v ?? ''))" 2>/dev/null || true; }
SS="${3:-$(jget raw/app.json 'j.demoStartsAt')}"; SS="${SS:-2}"
LEN="${4:-$(jget out/timeline.json 'j.scenes.app.length')}"; LEN="${LEN:-14}"
SPEED="${SPEED:-$(jget script/launch.json 'j.scenes.find(s=>s.id==="app").speed')}"; SPEED="${SPEED:-1}"
SLIDE="${SLIDE:-2.5}"; TILT="${TILT:-0.5}"
mkdir -p "$(dirname "$OUT")"

# Geometry (px on the 1920x1080 canvas, before the perspective).
SW=1200; SH=750            # screen
BZ=14                      # bezel
LW=$((SW + 2 * BZ)); LH=$((SH + 2 * BZ))   # lid
BW=1380; BH=26             # base
WH=680; WW=$((WH * 1600 / 1256))           # app window, 1600x1256 source
WX=$(((SW - WW) / 2)); WY=$((28 + (SH - 28 - WH) / 2))
LX=$(((1920 - BW) / 2)); LY=$(((1080 - (LH + BH - 2)) / 2))

# Alpha masks as geq expressions: all corners rounded, or only the bottom ones.
ALLR() { echo "a='255*if(gt(abs(X-W/2),W/2-$1)*gt(abs(Y-H/2),H/2-$1),lt(hypot(abs(X-W/2)-(W/2-$1),abs(Y-H/2)-(H/2-$1)),$1),1)'"; }
BOTR() { echo "a='255*if(gt(abs(X-W/2),W/2-$1)*gt(Y,H-$1),lt(hypot(abs(X-W/2)-(W/2-$1),Y-(H-$1)),$1),1)'"; }
GEQ() { echo "format=gbrap,geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':$1,format=rgba"; }

# Animation in terms of the output frame number `on` (30 fps): ease-out slide, yaw that settles then sways.
T='(on/30)'
E="(1-pow(1-min($T/$SLIDE,1),3))"
TH="($TILT*(1-$E)+0.10*sin(0.6*$T)*$E)"
D=2600; CX="(960+1400*(1-$E))"; CY=540
# `perspective` maps the whole 1920x1080 canvas, so project its corners (offset u scales by D/(D-u*sin th)).
SL="($D/($D+960*sin($TH)))"; SR="($D/($D-960*sin($TH)))"
XL="($CX-960*cos($TH)*$SL)"; XR="($CX+960*cos($TH)*$SR)"
Y0L="($CY-540*$SL)"; Y1L="($CY+540*$SL)"; Y0R="($CY-540*$SR)"; Y1R="($CY+540*$SR)"

SRC_LEN="$(python3 -c "print($LEN * $SPEED)")"   # seconds of the recording that fill LEN seconds at SPEED
ffmpeg -nostdin -y -loglevel error -ss "$SS" -t "$SRC_LEN" -i "$IN" \
  -f lavfi -i "gradients=s=1920x1080:r=30:d=$LEN:c0=0xffffff:c1=0xe6ebf5:x0=0:y0=0:x1=0:y1=1080:type=linear" \
  -f lavfi -i "gradients=s=${SW}x${SH}:r=30:d=$LEN:c0=0x2b3a67:c1=0x8e5ea2:x0=0:y0=0:x1=${SW}:y1=${SH}:type=linear" \
  -f lavfi -i "color=c=0x0b0b0c:s=${LW}x${LH}:r=30:d=$LEN" \
  -f lavfi -i "gradients=s=${BW}x${BH}:r=30:d=$LEN:c0=0xdfe1e5:c1=0xb4b7bd:x0=0:y0=0:x1=0:y1=${BH}:type=linear" \
  -f lavfi -i "color=c=0xa2a5ab:s=220x16:r=30:d=$LEN" \
  -f lavfi -i "color=c=0x0b0b0c:s=140x44:r=30:d=$LEN" \
  -f lavfi -i "color=c=black@0:s=1920x1080:r=30:d=$LEN,format=rgba" \
  -filter_complex "
    [0:v]setpts=PTS/${SPEED},fps=30,drawbox=x=14:y=6:w=130:h=48:color=0xefeded:t=fill,scale=${WW}:${WH},format=rgba,$(GEQ "$(ALLR 30)")[win];
    [win]split[w1][w2];
    [w2]colorchannelmixer=rr=0:gg=0:bb=0:aa=0.45,gblur=sigma=10[wsh];
    [2:v]format=rgba,drawbox=x=0:y=0:w=${SW}:h=28:color=black@0.28:t=fill[wall];
    [wall][wsh]overlay=${WX}:$((WY + 16)):format=auto[s1];
    [s1][w1]overlay=${WX}:${WY}:format=auto[s2];
    [6:v]format=rgba,$(GEQ "$(ALLR 10)")[notch];
    [s2][notch]overlay=(W-w)/2:-22:format=auto,$(GEQ "$(ALLR 22)")[screen];
    [3:v]format=rgba,$(GEQ "$(ALLR 36)")[lid0];
    [lid0][screen]overlay=${BZ}:${BZ}:format=auto[lid];
    [4:v]format=rgba,$(GEQ "$(BOTR 16)")[base0];
    [5:v]format=rgba,$(GEQ "$(BOTR 8)")[thumb];
    [base0][thumb]overlay=(W-w)/2:0:format=auto[base];
    [7:v][base]overlay=${LX}:$((LY + LH - 2)):format=auto[c1];
    [c1][lid]overlay=$(((1920 - LW) / 2)):${LY}:format=auto,format=yuva444p,
      perspective=x0='${XL}':y0='${Y0L}':x1='${XR}':y1='${Y0R}':x2='${XL}':y2='${Y1L}':x3='${XR}':y3='${Y1R}':sense=destination:eval=frame:interpolation=linear,
      split[fg][sh];
    [sh]colorchannelmixer=rr=0:gg=0:bb=0:aa=0.30,boxblur=lr=32:lp=6:ar=32:ap=6[shadow];
    [1:v]format=yuv420p[bg];
    [bg][shadow]overlay=0:46:format=auto[b1];
    [b1][fg]overlay=0:0:format=auto,format=yuv420p[v]" \
  -map "[v]" -an -c:v libx264 -crf 18 "$OUT"
echo "wrote $OUT"
