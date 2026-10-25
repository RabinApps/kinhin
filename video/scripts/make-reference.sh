#!/bin/bash
# Makes an adapter's committed reference clips from your own recordings in raw/<adapter>/, so people without the
# product's recording setup can still rebuild the video:
#   adapters/<name>/reference/<app clip>.mp4 + .json   the recording trimmed to start at the story and compressed
#   adapters/<name>/reference/<browser clip>.mp4       a browser session, compressed
#   adapters/<name>/reference/<terminal clip>*.mp4     the terminal variants (scripts/record-terminal.sh --all)
# The clips are small (a few hundred KB) and are committed.
# Usage: video/scripts/make-reference.sh [--adapter NAME] [--terminal] [seconds of the app clip to keep, default 42]
#   --terminal  refresh only the terminal clips
set -euo pipefail
cd "$(dirname "$0")/.."
[ -d /opt/homebrew/opt/ffmpeg-full/bin ] && export PATH="/opt/homebrew/opt/ffmpeg-full/bin:$PATH"
ADAPTER="${VIDEO_ADAPTER:-}"; TERMINAL_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --adapter) ADAPTER="${2:?--adapter needs a name}"; shift ;;
    --terminal) TERMINAL_ONLY=1 ;;
    *) break ;;
  esac
  shift
done
KEEP="${1:-42}"
[ -n "$ADAPTER" ] || ADAPTER="$(node scripts/project.mjs --adapter)"
[ -n "$ADAPTER" ] || { echo "no adapter: pass --adapter NAME" >&2; exit 2; }
RAW="raw/$ADAPTER"; REF="adapters/$ADAPTER/reference"
mkdir -p "$REF"
CLIPS="$(node -e "const c=JSON.parse(require('fs').readFileSync('adapters/$ADAPTER/adapter.json','utf8')).clips;for(const [k,v] of Object.entries(c))console.log(k+' '+v.kind)")"
while read -r clip kind; do
  if [ "$kind" = app ] && [ "$TERMINAL_ONLY" = 0 ]; then
    [ -f "$RAW/$clip.mov" ] || { echo "no $RAW/$clip.mov: record it first"; continue; }
    START="$(node -e "try{console.log(JSON.parse(require('fs').readFileSync('$RAW/$clip.json','utf8')).demoStartsAt||0)}catch{console.log(0)}")"
    ffmpeg -nostdin -y -loglevel error -ss "$START" -t "$KEEP" -i "$RAW/$clip.mov" \
      -vf "scale=1280:-2,fps=30" -c:v libx264 -crf 29 -preset slow -pix_fmt yuv420p -an -movflags +faststart "$REF/$clip.mp4"
    echo '{"demoStartsAt": 0}' > "$REF/$clip.json"
    # The pointer log (record-app.sh --pointer) is cut the same way: its times now count from the story's start.
    if [ -f "$RAW/$clip-pointer.json" ]; then
      node scripts/pointer-log.mjs "$RAW/$clip-pointer.json" "$REF/$clip-pointer.json" "$START" "$KEEP"
    else
      # No log for this take: drop the last one's, or its clicks would zoom the new clip.
      rm -f "$REF/$clip-pointer.json"
    fi
  elif [ "$kind" = browser ] && [ "$TERMINAL_ONLY" = 0 ]; then
    [ -f "$RAW/$clip.webm" ] || { echo "no $RAW/$clip.webm: record it first"; continue; }
    ffmpeg -nostdin -y -loglevel error -t "$KEEP" -i "$RAW/$clip.webm" \
      -vf "scale=1280:-2,fps=30" -c:v libx264 -crf 29 -preset slow -pix_fmt yuv420p -an -movflags +faststart "$REF/$clip.mp4"
    echo '{"demoStartsAt": 0}' > "$REF/$clip.json"
  elif [ "$kind" = terminal ]; then
    for f in "$RAW/$clip".mp4 "$RAW/$clip"-*.mp4; do
      [ -f "$f" ] || continue
      case "$f" in *-uncut.mp4) ;; *) cp "$f" "$REF/" ;; esac
    done
  fi
done <<< "$CLIPS"
ls -l "$REF"
