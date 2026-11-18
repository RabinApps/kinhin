#!/usr/bin/env bash
# Guards the Worker script size. Cloudflare's limit is 3 MiB gzipped (3145728) on the free plan and 10 MiB on paid. This build is
# already about 3.0 MB: it fails above MAX_GZIP_BYTES (default 3.1 MB, just under the free limit) and warns above 2.9 MB.
#   scripts/check-worker-size.sh                           after scripts/build-site.sh
#   MAX_GZIP_BYTES=10000000 scripts/check-worker-size.sh   on a paid plan
set -euo pipefail
cd "$(dirname "$0")/.."
max=${MAX_GZIP_BYTES:-3100000}
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
npx wrangler deploy --dry-run --outdir "$out" >/dev/null 2>&1 || npx wrangler deploy --dry-run --outdir "$out"
gz=$(cat "$out"/*.js | gzip -c | wc -c | tr -d ' ')
echo "worker: $(cat "$out"/*.js | wc -c | tr -d ' ') bytes, $gz gzipped (limit $max)"
[ "$gz" -le 2900000 ] || [ "$max" -gt 3100000 ] || echo "::warning::the Worker is $gz bytes gzipped: within 7% of the free plan limit (3145728)"
[ "$gz" -le "$max" ] || { echo "::error::the Worker is $gz bytes gzipped, over $max"; exit 1; }
