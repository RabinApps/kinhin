#!/bin/bash
# The image's entry point: builds one video of YOUR repository, with the suite already inside the image.
#   kinhin video build launch            (this is what it runs, in a container)
#   <runtime> run --rm -v "$PWD":/project:ro -v "$PWD/.kinhin/videos/out":/work/out -v "$PWD/.kinhin/videos/.cache":/work/raw \
#       IMAGE /work/scripts/container-build.sh --project launch [--theme T] [--format F] [--captions on|off|all] [--music M] [--fast]
# Your repository is mounted at /project; its .kinhin/videos/ holds the configs (and fonts/ for your own fonts).
set -euo pipefail
cd /work
[ -d /project/.kinhin/videos ] || { echo "no /project/.kinhin/videos: mount your repository at /project" >&2; exit 2; }
if [ -d /project/.kinhin/videos/fonts ]; then cp -r /project/.kinhin/videos/fonts/. /usr/local/share/fonts/; fc-cache -f; fi
export VIDEO_SOURCE=/project
# The finished video is out/<name>/; out/.work is scratch (timeline, clips, voice) and is not left in your repository.
status=0
scripts/build.sh "$@" || status=$?
[ -n "${KEEP_WORK:-}" ] || rm -rf out/.work
exit "$status"
