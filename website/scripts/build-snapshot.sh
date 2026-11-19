#!/usr/bin/env bash
# Builds one release snapshot: the docs as they were at <tag>, rendered by the current site, written to
# .snapshots-out/<tag>/. scripts/build-site.sh moves them all into public/ once every snapshot is built, so the Worker serves them at
# /<tag>/ (see .github/workflows/docs.yml). They must not sit in public/ while another snapshot builds: Next copies public/ into every
# static export, and each snapshot would swallow the ones before it (hundreds of MB).
#
#   scripts/build-snapshot.sh <tag> [<content-root>]
#
# <content-root> is a checkout of the tag (CI makes a `git worktree`). It defaults to the current repo, which only
# makes sense to try the script out. Run it before the latest site's own content step: both write website/.generated.
set -euo pipefail
cd "$(dirname "$0")/.."
tag=${1:?usage: build-snapshot.sh <tag> [<content-root>]}
root=${2:-$(cd .. && pwd)}

export CONTENT_ROOT=$root DOCS_VERSION=$tag
node scripts/content/build.ts
rm -rf ".snapshots/$tag"
npx next build

dest=.snapshots-out/$tag
rm -rf "$dest"
mkdir -p "$dest"
cp -R ".snapshots/$tag/." "$dest/"
# The latest site serves the videos and posters; a snapshot does not carry its own copies.
find "$dest" -maxdepth 1 \( -name '*.mp4' -o -name '*.webm' -o -name '*-poster.png' \) -delete
# Markdown copies and llms.txt next to the pages (the static export has no middleware or route handlers).
cp -R .generated/md/. "$dest/"
cp .generated/llms.txt .generated/llms-full.txt "$dest/"
rm -rf "$dest/md"
echo "snapshot $tag: $(find "$dest" -type f | wc -l) files, $(du -sh "$dest" | cut -f1)"
