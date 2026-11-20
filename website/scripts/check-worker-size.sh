#!/usr/bin/env bash
# Guards the Worker script size. Cloudflare's limit is 3 MiB gzipped (3145728) on the free plan and 10 MiB on paid. The build is
# about 1.2 MB (diagram libraries are kept out of it, see scripts/check-bundle.mjs): it warns above 2.4 MB and fails above
# MAX_GZIP_BYTES (default 2.8 MB), leaving room under the free-plan limit.
#   scripts/check-worker-size.sh                           after scripts/build-site.sh
#   MAX_GZIP_BYTES=10000000 scripts/check-worker-size.sh   on a paid plan
set -euo pipefail
cd "$(dirname "$0")/.."
max=${MAX_GZIP_BYTES:-2800000}
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
npx wrangler deploy --dry-run --outdir "$out" >/dev/null 2>&1 || npx wrangler deploy --dry-run --outdir "$out"
gz=$(cat "$out"/*.js | gzip -c | wc -c | tr -d ' ')
echo "worker: $(cat "$out"/*.js | wc -c | tr -d ' ') bytes, $gz gzipped (limit $max)"
[ "$gz" -le 2400000 ] || echo "::warning::the Worker is $gz bytes gzipped: getting close to the free plan limit (3145728)"
[ "$gz" -le "$max" ] || { echo "::error::the Worker is $gz bytes gzipped, over $max"; exit 1; }
