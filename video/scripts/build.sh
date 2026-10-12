#!/bin/bash
# Builds the voice-over launch video end to end: voice, retime, title scenes, framed clips, final cut.
#
#   video/scripts/build.sh                 on this machine (needs Node, ffmpeg with libass, Chromium; see doctor.sh)
#   video/scripts/build.sh --container     in a container: Apple's `container` if installed, else Docker
#   video/scripts/build.sh --runtime docker --container    pick the runtime
#   video/scripts/build.sh --theme midnight --format 9:16  another look or frame (the project's own is the default)
#   video/scripts/build.sh --project my-video              build video/script/my-video.json
#
# It uses your own recordings in raw/ (record.sh, the vhs tape) when they exist, and the small committed clips
# in reference/ otherwise, so it works on any machine, including Linux. Output: video/out/ (launch.mp4,
# launch.webm, poster.png, hero.gif) and out/launch.srt (every caption, for a player).
# Env: VOICE_ENGINE / VOICE override the script's voice (kokoro af_heart); NO_MUSIC=1 skips the music download;
#      NO_CAPTIONS=1; the container's size: CONTAINER_CPUS (default 4), CONTAINER_MEMORY (default 6G).
set -euo pipefail
cd "$(dirname "$0")/.."

CONTAINER=0; RUNTIME=""
while [ $# -gt 0 ]; do
  case "$1" in
    --container) CONTAINER=1 ;;
    --runtime) RUNTIME="${2:?--runtime needs container or docker}"; shift ;;
    --theme) export VIDEO_THEME="${2:?--theme needs a name (see video/themes/)}"; shift ;;
    --format) export VIDEO_FORMAT="${2:?--format needs 16:9, 9:16, 4:5 or 1:1}"; shift ;;
    --project) export VIDEO_PROJECT="${2:?--project needs a name (video/script/<name>.json)}"; shift ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

if [ "$CONTAINER" = 1 ] && [ -z "${KINHIN_VIDEO_IN_CONTAINER:-}" ]; then
  # Apple's container first, Docker as the fallback.
  if [ -z "$RUNTIME" ]; then
    if command -v container >/dev/null 2>&1 && container system status >/dev/null 2>&1; then RUNTIME=container
    elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then RUNTIME=docker
    else echo "no running container runtime: start Apple's container (container system start) or Docker" >&2; exit 1; fi
  fi
  IMAGE=kinhin-video
  echo "==> using $RUNTIME"
  "$RUNTIME" build -t "$IMAGE" -f Containerfile .
  mkdir -p raw out
  # The image has its own node_modules (Linux binaries), so the sources are copied in at start-up and only the
  # results are written back: raw/ (renders, music) and out/.
  # The size flags differ: Docker's -c is CPU *shares*, so use --cpus there.
  if [ "$RUNTIME" = docker ]; then SIZE=(--cpus "${CONTAINER_CPUS:-4}" --memory "${CONTAINER_MEMORY:-6g}")
  else SIZE=(-c "${CONTAINER_CPUS:-4}" -m "${CONTAINER_MEMORY:-6G}"); fi
  "$RUNTIME" run --rm "${SIZE[@]}" \
    -v "$PWD":/src -v "$PWD/raw":/work/raw -v "$PWD/out":/work/out \
    -e NO_MUSIC="${NO_MUSIC:-}" -e NO_CAPTIONS="${NO_CAPTIONS:-}" -e VOICE_ENGINE="${VOICE_ENGINE:-}" -e VOICE="${VOICE:-}" \
    -e VIDEO_THEME="${VIDEO_THEME:-}" -e VIDEO_FORMAT="${VIDEO_FORMAT:-}" -e VIDEO_PROJECT="${VIDEO_PROJECT:-}" \
    "$IMAGE" bash -c 'rsync -a --exclude node_modules --exclude raw --exclude out --exclude .venv-tts --exclude output /src/ /work/ && cd /work && { cp -r fonts/. /usr/local/share/fonts/ 2>/dev/null; fc-cache -f; } && scripts/build.sh'
  echo "==> done: see video/out/"
  exit 0
fi

step() { printf '\n==> %s\n' "$*"; }
[ -d node_modules ] || { step "npm ci"; npm ci; }
export PATH="/opt/homebrew/opt/ffmpeg-full/bin:$PATH"   # ffmpeg with libass on a Mac; harmless elsewhere
mkdir -p raw out

step "voice-over (${VOICE_ENGINE:-the scripted engine})"
rm -f out/voice-timings.json
# The ONNX runtime aborts while shutting down (after the work is done), so judge the run by its result file.
node scripts/voice.mjs ${VOICE_ENGINE:+--engine "$VOICE_ENGINE"} ${VOICE:+--voice "$VOICE"} 2>&1 | grep -v libc++ || true
[ -s out/voice-timings.json ] || { echo "voice-over failed: no out/voice-timings.json" >&2; exit 1; }
step "retime the scenes to the voice"
node scripts/retime.mjs
step "check the project"
node scripts/project.mjs
step "title scenes (headless Chromium)"
node scripts/render-titles.mjs
step "the app and terminal clips in frames"
node scripts/frames.mjs
[ -n "${NO_MUSIC:-}" ] || { step "music"; scripts/fetch-music.sh; }
step "final cut"
node scripts/assemble.mjs
ls -lh out/*.mp4 out/*.webm out/*-poster.png out/*-hero.gif out/*.srt 2>/dev/null | tail -8
