#!/bin/bash
# Produces every clip of a preset that has a `make` command and is not in raw/ yet, then exports the video.
# Clips without a `make` (the Motion Canvas title scenes) are rendered by hand from the editor; this says which.
#
# Usage: video/scripts/make.sh [preset] [--force]    (default native-app; --force remakes existing clips)
set -euo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$0")/.."

PRESET=native-app
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$SELF" | sed '$d'; exit 0 ;;
    *) PRESET="$arg" ;;
  esac
done

CLIPS="$(node scripts/clips.mjs "$PRESET")"
mkdir -p raw
while IFS=$'\x1f' read -r file captions make hint needs; do
  if [ -f "raw/$file" ] && [ "$FORCE" = 0 ]; then echo "==> raw/$file exists"; continue; fi
  if [ -z "$make" ]; then echo "==> raw/$file is made by hand: $hint"; continue; fi
  echo "==> making raw/$file: $make"
  bash -c "$make" < /dev/null
done <<< "$CLIPS"

exec scripts/export.sh "$PRESET"
