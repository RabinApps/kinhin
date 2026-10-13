#!/bin/bash
# Smoke-tests a video image the way a user runs it: builds a small video of a throwaway repository inside the image and verifies the
# result with the image's own checker (frame size, length, loudness, black frames, captions, poster). CI runs this before it
# publishes an image; run it yourself on one you built:
#
#   docker build -t kinhin-video:local video/
#   video/scripts/image-smoke.sh kinhin-video:local            # Docker (default)
#   video/scripts/image-smoke.sh kinhin-video:local container  # Apple container (the image must be in its store)
#
# Needs no network once the image exists. Takes a few minutes the first time (the voice model loads).
set -euo pipefail
IMAGE="${1:?usage: image-smoke.sh IMAGE [docker|container]}"
RUNTIME="${2:-docker}"
case "$RUNTIME" in docker|container) ;; *) echo "runtime must be docker or container" >&2; exit 2 ;; esac

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/repo/.kinhin/videos" "$work/out" "$work/cache"
cat > "$work/repo/.kinhin/videos/smoke.yml" <<'YAML'
name: Smoke
theme: clean
voice: { engine: kokoro, name: af_heart }
music: first-light-particles
scenes:
  - id: hello
    type: title
    props: { title: Smoke test, subtitle: One file, one command }
    narration: This is a smoke test of the video image.
  - id: steps
    type: statement
    props: { text: "Voice, scenes and music.", sub: "All from one config." }
    narration: It has a voice, drawn scenes and a music track from the catalog.
YAML

echo "==> building a video inside $IMAGE ($RUNTIME)"
"$RUNTIME" run --rm \
  -v "$work/repo":/project:ro -v "$work/out":/work/out -v "$work/cache":/work/raw \
  "$IMAGE" /work/scripts/container-build.sh --project smoke --fast

echo "==> verifying it with the image's own checker"
"$RUNTIME" run --rm -v "$work/out":/work/out "$IMAGE" node /work/scripts/video-ci.mjs verify /work/out

[ -s "$work/out/smoke.mp4" ] || { echo "no smoke.mp4 was produced" >&2; exit 1; }
echo "==> ok: $IMAGE builds and verifies a video"
