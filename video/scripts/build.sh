#!/bin/bash
# Builds the voice-over launch video end to end: voice, retime, title scenes, framed clips, final cut.
#
#   video/scripts/build.sh                 on this machine (needs Node, ffmpeg with libass, Chromium; see doctor.sh)
#   video/scripts/build.sh --container     in a container: Apple's `container` if installed, else Docker
#   video/scripts/build.sh --runtime docker --container    pick the runtime
#   video/scripts/build.sh --theme midnight --format 9:16  another look or frame (the project's own is the default)
#   video/scripts/build.sh --platform android             the mobile screens of the look's platform (ios or android)
#   video/scripts/build.sh --project my-video              build video/script/my-video.json
#   video/scripts/build.sh --source ~/code/acme --project promo   build ~/code/acme/.kinhin/videos/promo.yml (your own repository)
#   video/scripts/build.sh --adapter my-product            use another adapter's clips (video/adapters/)
#   video/scripts/build.sh --music off                     no music; or a catalog track, a file (music/my-track.mp3), or an https URL (with VIDEO_MUSIC_SHA256)
#   video/scripts/build.sh --fast                          a preview: quicker encode, no WebM
#   video/scripts/build.sh --captions off                  no burned-in captions (on, off, or all scenes); the .srt is still written
#   video/scripts/build.sh --caption-style box             outline, box, shadow, bold or minimal
#
# It uses your own recordings in raw/<adapter>/ when they exist, and the small committed clips in
# adapters/<adapter>/reference/ otherwise, so it works on any machine, including Linux. Output: video/out/ (launch.mp4,
# launch.webm, poster.png, hero.gif) and out/launch.srt (every caption, for a player).
# Env: VIDEO_IMAGE=<image> runs a published image instead of building one (--container); VOICE_ENGINE / VOICE override the script's voice (kokoro af_heart); NO_MUSIC=1 (same as --music off); VIDEO_MUSIC_VOLUME=0.2;
#      VIDEO_CAPTIONS=off; CONTAINER_NETWORK=none (Docker) runs the build with no network; the container's size: CONTAINER_CPUS (default 4), CONTAINER_MEMORY (default 6G).
set -euo pipefail
CALLER_DIR="$PWD"   # --source is relative to where you ran this, not to video/
cd "$(dirname "$0")/.."

CONTAINER=0; RUNTIME=""
while [ $# -gt 0 ]; do
  case "$1" in
    --container) CONTAINER=1 ;;
    --runtime) RUNTIME="${2:?--runtime needs container or docker}"; shift ;;
    --theme) export VIDEO_THEME="${2:?--theme needs a name (see video/themes/)}"; shift ;;
    --format) export VIDEO_FORMAT="${2:?--format needs 16:9, 9:16, 4:5 or 1:1}"; shift ;;
    --platform) export VIDEO_PLATFORM="${2:?--platform needs ios or android}"; shift ;;
    --project) export VIDEO_PROJECT="${2:?--project needs a name (video/script/<name>.json)}"; shift ;;
    --source) export VIDEO_SOURCE="$(cd "$CALLER_DIR" && cd "${2:?--source needs the directory of your repository}" && pwd)"; shift ;;
    --music) export VIDEO_MUSIC="${2:?--music needs a track, a file, a URL, or off}"; shift ;;
    --adapter) export VIDEO_ADAPTER="${2:?--adapter needs a name (see video/adapters/)}"; shift ;;
    --fast) export VIDEO_FAST=1 ;;
    --captions) export VIDEO_CAPTIONS="${2:?--captions needs on, off or all}"; shift ;;
    --caption-style) export VIDEO_CAPTION_STYLE="${2:?--caption-style needs a name (outline, box, shadow, bold, minimal)}"; shift ;;
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
  echo "==> using $RUNTIME"
  # Low disk space breaks container builds in confusing ways ("read-only file system", "input/output error"): say so.
  FREE_KB="$(df -k . | awk 'NR==2 {print $4}')"
  if [ "${FREE_KB:-0}" -lt 3000000 ]; then
    echo "only $((FREE_KB / 1024)) MB free here: container builds need several GB. Apple's container keeps its build cache" >&2
    echo "in a builder VM that can grow large; 'container builder stop && container builder delete' empties it." >&2
    exit 1
  fi
  # The image is named by a hash of what goes into it, and built only when that image does not exist yet: rebuilding
  # an unchanged image on every run is slow and, with Apple's container, grows its build cache.
  # The architecture is part of the name: an arm64 image must not satisfy an x64 build (DOCKER_DEFAULT_PLATFORM selects one).
  IMAGE="kinhin-video:$( (cat Dockerfile package.json package-lock.json music/catalog.json; echo "${DOCKER_DEFAULT_PLATFORM:-$(uname -m)}") | shasum -a 256 | cut -c1-12)"
  # VIDEO_IMAGE uses a published image instead (a release build in CI pulls the one made for that release). It must exist or
  # be pullable: there is no silent fallback to a different image.
  if [ -n "${VIDEO_IMAGE:-}" ]; then
    IMAGE="$VIDEO_IMAGE"
    if ! "$RUNTIME" image inspect "$IMAGE" >/dev/null 2>&1; then
      echo "==> pulling $IMAGE"
      "$RUNTIME" image pull "$IMAGE" || { echo "could not get the image $IMAGE (VIDEO_IMAGE)" >&2; exit 1; }
    fi
    echo "==> using image $IMAGE"
  elif "$RUNTIME" image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "==> image $IMAGE already built"
  else
    # An absolute, symlink-free context path: Apple's `container build` (before 1.5.0) silently drops directories when the
    # context sits under a symlink such as /tmp or /var/folders (apple/container#2285).
    CONTEXT="$(pwd -P)"
    "$RUNTIME" build -t "$IMAGE" -f "$CONTEXT/Dockerfile" "$CONTEXT"
  fi
  mkdir -p raw out
  # The image has its own node_modules (Linux binaries), so the sources are copied in at start-up and only the
  # results are written back: raw/ (renders, music) and out/.
  # The size flags differ: Docker's -c is CPU *shares*, so use --cpus there.
  # Ask for four CPUs, but never more than the machine has: Docker refuses a count above it (a small hosted runner has two).
  HAVE="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)"
  WANT="${CONTAINER_CPUS:-4}"; CPUS=$((WANT < HAVE ? WANT : HAVE))
  if [ "$RUNTIME" = docker ]; then SIZE=(--cpus "$CPUS" --memory "${CONTAINER_MEMORY:-6g}")
  else SIZE=(-c "$CPUS" -m "${CONTAINER_MEMORY:-6G}"); fi
  # CONTAINER_NETWORK=none (Docker) proves the build needs nothing from the network once the image exists.
  NET=(); [ -n "${CONTAINER_NETWORK:-}" ] && NET=(--network "$CONTAINER_NETWORK")
  # Your repository (--source) is mounted read-only at /project; its .kinhin/videos/ holds the configs.
  SRCMOUNT=(); [ -n "${VIDEO_SOURCE:-}" ] && SRCMOUNT=(-v "$VIDEO_SOURCE":/project:ro -e VIDEO_SOURCE=/project)
  "$RUNTIME" run --rm "${SIZE[@]}" ${SRCMOUNT[@]+"${SRCMOUNT[@]}"} ${NET[@]+"${NET[@]}"} \
    -v "$PWD":/src -v "$PWD/raw":/work/raw -v "$PWD/out":/work/out \
    -e NO_MUSIC="${NO_MUSIC:-}" -e VIDEO_MUSIC="${VIDEO_MUSIC:-}" -e VIDEO_MUSIC_SHA256="${VIDEO_MUSIC_SHA256:-}" -e VIDEO_MUSIC_VOLUME="${VIDEO_MUSIC_VOLUME:-}" -e NO_CAPTIONS="${NO_CAPTIONS:-}" -e VOICE_ENGINE="${VOICE_ENGINE:-}" -e VOICE="${VOICE:-}" \
    -e VIDEO_THEME="${VIDEO_THEME:-}" -e VIDEO_FORMAT="${VIDEO_FORMAT:-}" -e VIDEO_PLATFORM="${VIDEO_PLATFORM:-}" -e VIDEO_PROJECT="${VIDEO_PROJECT:-}" -e VIDEO_ADAPTER="${VIDEO_ADAPTER:-}" -e VIDEO_FAST="${VIDEO_FAST:-}" -e VIDEO_CAPTIONS="${VIDEO_CAPTIONS:-}" -e VIDEO_CAPTION_STYLE="${VIDEO_CAPTION_STYLE:-}" \
    "$IMAGE" bash -c 'rsync -a --exclude node_modules --exclude raw --exclude out --exclude .venv-tts --exclude output --exclude .generated /src/ /work/ && cd /work && { cp -r fonts/. /usr/local/share/fonts/ 2>/dev/null; fc-cache -f; } && scripts/build.sh'
  echo "==> done: see video/out/<name>/"
  exit 0
fi

step() { printf '\n==> %s\n' "$*"; }
[ -d node_modules ] || { step "npm ci"; npm ci; }
export PATH="/opt/homebrew/opt/ffmpeg-full/bin:$PATH"   # ffmpeg with libass on a Mac; harmless elsewhere
mkdir -p raw out

step "check the project"
node scripts/project.mjs
step "claims"
node scripts/video-claims-lint.mjs --project "${VIDEO_PROJECT:-launch}"
step "voice-over (${VOICE_ENGINE:-the scripted engine})"
mkdir -p out/.work; rm -f out/.work/voice-timings.json
# The ONNX runtime aborts while shutting down (after the work is done), so judge the run by its result file.
node scripts/voice.mjs ${VOICE_ENGINE:+--engine "$VOICE_ENGINE"} ${VOICE:+--voice "$VOICE"} 2>&1 | grep -v libc++ || true
[ -s out/.work/voice-timings.json ] || { echo "voice-over failed: no out/.work/voice-timings.json" >&2; exit 1; }
step "retime the scenes to the voice"
node scripts/retime.mjs
step "title scenes (headless Chromium)"
node scripts/render-titles.mjs
step "the app and terminal clips in frames"
node scripts/frames.mjs
step "music"
node scripts/fetch-music.mjs
step "final cut"
node scripts/assemble.mjs
# What this build made (the WebM is skipped by --fast, so a glob can match nothing: that is not an error).
find out -mindepth 2 -maxdepth 2 -not -path 'out/.work/*' -newer package.json -type f \( -name '*.mp4' -o -name '*.webm' -o -name '*-poster.png' -o -name '*-hero.gif' -o -name '*.srt' \) -exec ls -lh {} + 2>/dev/null | tail -8 || true
