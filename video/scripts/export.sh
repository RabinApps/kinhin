#!/bin/bash
# Joins the clips into the launch video and the web assets. Needs ffmpeg.
#
# Inputs (video/raw/):
#   opening.mp4   Motion Canvas "opening" project (intro + problem), rendered from the editor
#   app.mov       scripts/record.sh
#   install.mp4   vhs terminal/install.tape
#   closing.mp4   Motion Canvas "closing" project (lanes + outro)
# Outputs (video/out/): launch.mp4, launch.webm, poster.png, hero.gif
# Env: HERO_START (default 16) and HERO_LEN (default 15) pick the hero GIF window in seconds;
#      POSTER_AT (default 20) picks the poster frame.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p out

for f in opening.mp4 app.mov install.mp4 closing.mp4; do
  [ -f "raw/$f" ] || { echo "missing raw/$f" >&2; exit 1; }
done

# Normalize every clip to 1080p30 H.264 on a white letterbox, then concat.
norm() {
  ffmpeg -y -loglevel error -i "raw/$1" \
    -vf "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:white,fps=30,format=yuv420p" \
    -an -c:v libx264 -crf 18 "out/n-$2.mp4"
}
norm opening.mp4 1
norm app.mov 2
norm install.mp4 3
norm closing.mp4 4
printf "file 'n-1.mp4'\nfile 'n-2.mp4'\nfile 'n-3.mp4'\nfile 'n-4.mp4'\n" > out/list.txt

ffmpeg -y -loglevel error -f concat -safe 0 -i out/list.txt -c copy -movflags +faststart out/launch.mp4
ffmpeg -y -loglevel error -i out/launch.mp4 -c:v libvpx-vp9 -crf 33 -b:v 0 -an out/launch.webm
ffmpeg -y -loglevel error -ss "${POSTER_AT:-20}" -i out/launch.mp4 -frames:v 1 \
  -vf "scale=1200:630:force_original_aspect_ratio=increase,crop=1200:630" out/poster.png
ffmpeg -y -loglevel error -ss "${HERO_START:-16}" -t "${HERO_LEN:-15}" -i out/launch.mp4 \
  -vf "fps=12,scale=960:-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse" out/hero.gif
rm -f out/n-*.mp4 out/list.txt
ls -lh out
