#!/usr/bin/env bash
# The whole deployable site: every release snapshot listed in versions.json, then the latest docs, as a Worker.
#
#   scripts/build-site.sh          build everything into .open-next/
#
# Snapshots need the release tags (`git fetch --tags`, or actions/checkout with fetch-depth: 0). A listed tag that is not
# in this checkout is skipped with a warning. A tag that exists but fails to build is an error when SNAPSHOT_STRICT=1
# (CI sets it, so a broken snapshot is caught on the pull request) and a warning otherwise.
set -euo pipefail
cd "$(dirname "$0")/.."
repo=$(cd .. && pwd)
work=$(mktemp -d)
trap 'git -C "$repo" worktree prune; rm -rf "$work"' EXIT

rm -rf public/v[0-9]*/ .snapshots .snapshots-out
for tag in $(node -e 'for (const v of JSON.parse(require("fs").readFileSync("versions.json","utf8"))) console.log(v)'); do
  if ! git -C "$repo" rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    echo "::warning::snapshot $tag skipped: no such tag in this checkout"
    continue
  fi
  git -C "$repo" worktree add --detach -f "$work/$tag" "$tag" >/dev/null
  if ! scripts/build-snapshot.sh "$tag" "$work/$tag"; then
    rm -rf ".snapshots-out/$tag"
    if [ "${SNAPSHOT_STRICT:-0}" = 1 ]; then
      echo "::error::snapshot $tag failed to build"
      exit 1
    fi
    echo "::warning::snapshot $tag failed to build; it will not be published"
  fi
done

# Every snapshot is built: publish them with the site (public/ is copied into the Worker's assets).
if [ -d .snapshots-out ]; then
  for d in .snapshots-out/*/; do [ -d "$d" ] && cp -R "$d" public/; done
  rm -rf .snapshots-out
fi

unset CONTENT_ROOT DOCS_VERSION
node scripts/content/build.ts
npx opennextjs-cloudflare build
