#!/bin/bash
# Joins the clips into the launch video and the web assets. Needs ffmpeg.
#
# Usage: video/scripts/export.sh [preset]     (default native-app; see presets/*.json, or pass a path)
# Input: the clips the preset lists, in video/raw/. Each clip may be .mp4, .mov or .webm at any size.
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
# Captions need ffmpeg's `subtitles` filter (libass). Homebrew's plain `ffmpeg` lacks it; `ffmpeg-full` has it.
[ -d /opt/homebrew/opt/ffmpeg-full/bin ] && export PATH="/opt/homebrew/opt/ffmpeg-full/bin:$PATH"

PRESET="${1:-${PRESET:-native-app}}"
CLIPS="$(node scripts/clips.mjs "$PRESET")"

missing=0
while IFS=$'\x1f' read -r file captions make hint needs; do
  if [ ! -f "raw/$file" ]; then
    echo "missing raw/$file${make:+ (make it with: $make${needs:+, needs $needs})}${hint:+ ($hint)}" >&2
    missing=1
  fi
done <<< "$CLIPS"
[ "$missing" = 0 ] || exit 1

# Normalize every clip to 1080p30 H.264 on a white letterbox, burning captions in when a file is given.
# libass scales FontSize by height/288, so 14 is about 52 px on 1080p.
CAPTION_STYLE="Fontname=Helvetica,Fontsize=14,PrimaryColour=&H000000&,OutlineColour=&HFFFFFF&,BorderStyle=1,Outline=3,Shadow=0,Alignment=2,MarginV=40"
norm() { # input, output index, optional captions file
  local vf="scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:white,fps=30"
  if [ -n "${3:-}" ] && [ -f "$3" ] && [ -z "${NO_CAPTIONS:-}" ]; then
    vf="$vf,subtitles=$3:force_style='$CAPTION_STYLE'"
  fi
  ffmpeg -nostdin -y -loglevel error -i "raw/$1" -vf "$vf,format=yuv420p" -an -c:v libx264 -crf 18 "out/n-$2.mp4"
}
: > out/list.txt
index=0
while IFS=$'\x1f' read -r file captions make hint needs; do
  index=$((index + 1))
  norm "$file" "$index" "$captions"
  echo "file 'n-$index.mp4'" >> out/list.txt
done <<< "$CLIPS"

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
