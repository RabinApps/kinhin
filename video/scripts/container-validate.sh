#!/bin/bash
# The image's validation entry point: checks your repository's videos without rendering them (see scripts/validate.mjs).
#   kinhin video validate launch         (this is what it runs, in a container)
#   <runtime> run --rm -v "$PWD":/project:ro IMAGE /work/scripts/container-validate.sh --project launch
# Exit 0 when every checked video can be built, 1 when one has a problem, 2 when the check could not run.
set -euo pipefail
cd /work
[ -d /project/.kinhin/videos ] || { echo "no /project/.kinhin/videos: mount your repository at /project" >&2; exit 2; }
[ -f scripts/validate.mjs ] || { echo "this video image predates 'kinhin video validate': use a newer image (--image) or update kinhin" >&2; exit 2; }
export VIDEO_SOURCE=/project
exec node scripts/validate.mjs "$@"
