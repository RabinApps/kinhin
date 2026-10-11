#!/bin/bash
# Joins the clips into the launch video and the web assets. Needs ffmpeg.
#
# Inputs (video/raw/):
#   opening.mp4   Motion Canvas "opening" project (intro + problem), rendered from the editor
#   app.mov       scripts/record.sh
#   install.mp4   vhs terminal/install.tape
#   closing.mp4   Motion Canvas "closing" project (lanes + outro)
# Optional inputs:
#   captions/app.srt, captions/install.srt   burned into those clips (committed; retime to your take)
#   raw/music.{mp3,m4a,wav,flac}             mixed under the whole video (looped, faded in and out)
#   NO_CAPTIONS=1 skips the captions
# Outputs (video/out/): launch.mp4, launch.webm, poster.png, hero.gif
# Env: HERO_START (default 16) and HERO_LEN (default 15) pick the hero GIF window in seconds;
#      POSTER_AT (default 20) picks the poster frame.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p out

for f in opening.mp4 app.mov install.mp4 closing.mp4; do
  [ -f "raw/$f" ] || { echo "missing raw/$f" >&2; exit 1; }
done

# Normalize every clip to 1080p30 H.264 on a white letterbox, burning captions in when a file is given.
# libass scales FontSize by height/288, so 14 is about 52 px on 1080p.
CAPTION_STYLE="Fontname=Helvetica,Fontsize=14,PrimaryColour=&H000000&,OutlineColour=&HFFFFFF&,BorderStyle=1,Outline=3,Shadow=0,Alignment=2,MarginV=40"
norm() { # input, output index, optional captions file
  local vf="scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:white,fps=30"
  if [ -n "${3:-}" ] && [ -f "$3" ] && [ -z "${NO_CAPTIONS:-}" ]; then
    vf="$vf,subtitles=$3:force_style='$CAPTION_STYLE'"
  fi
  ffmpeg -y -loglevel error -i "raw/$1" -vf "$vf,format=yuv420p" -an -c:v libx264 -crf 18 "out/n-$2.mp4"
}
norm opening.mp4 1
norm app.mov 2 captions/app.srt
norm install.mp4 3 captions/install.srt
norm closing.mp4 4
printf "file 'n-1.mp4'\nfile 'n-2.mp4'\nfile 'n-3.mp4'\nfile 'n-4.mp4'\n" > out/list.txt

ffmpeg -y -loglevel error -f concat -safe 0 -i out/list.txt -c copy -movflags +faststart out/silent.mp4

# Music is optional: loop it under the video with a 2 s fade in and a 3 s fade out.
music=""
for ext in mp3 m4a wav flac; do [ -f "raw/music.$ext" ] && music="raw/music.$ext" && break; done
if [ -n "$music" ]; then
  dur="$(ffprobe -v error -show_entries format=duration -of csv=p=0 out/silent.mp4)"
  fade_at="$(awk -v d="$dur" 'BEGIN { printf "%.2f", (d > 3 ? d - 3 : 0) }')"
  ffmpeg -y -loglevel error -i out/silent.mp4 -stream_loop -1 -i "$music" \
    -filter_complex "[1:a]volume=0.5,afade=t=in:d=2,afade=t=out:st=${fade_at}:d=3[a]" \
    -map 0:v -map "[a]" -t "$dur" -c:v copy -c:a aac -b:a 160k -movflags +faststart out/launch.mp4
else
  cp out/silent.mp4 out/launch.mp4
fi
rm -f out/silent.mp4
ffmpeg -y -loglevel error -i out/launch.mp4 -c:v libvpx-vp9 -crf 33 -b:v 0 -c:a libopus out/launch.webm
ffmpeg -y -loglevel error -ss "${POSTER_AT:-20}" -i out/launch.mp4 -frames:v 1 \
  -vf "scale=1200:630:force_original_aspect_ratio=increase,crop=1200:630" out/poster.png
ffmpeg -y -loglevel error -ss "${HERO_START:-16}" -t "${HERO_LEN:-15}" -i out/launch.mp4 \
  -vf "fps=12,scale=960:-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse" out/hero.gif
rm -f out/n-*.mp4 out/list.txt
ls -lh out
