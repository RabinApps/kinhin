#!/bin/bash
# Website gate: the content pipeline (fails on dead links), typecheck, unit tests and a production build.
# Run after editing docs/ or website/. Installs dependencies on first use.
#   scripts/website-check.sh --opennext   also build the Cloudflare Worker (what CI deploys)
#   scripts/website-check.sh --e2e        also build the Worker and run the browser tests (website/e2e); needs Chromium
#                                         (`cd website && npx playwright install chromium`, or set CHROMIUM_PATH)
set -euo pipefail

cd "$(dirname "$0")/../website"
# npm ci unless node_modules is present and still satisfies package.json. A stale install (a dependency added
# since the last install) would otherwise fail later with ERR_MODULE_NOT_FOUND, before any check runs.
npm ls --depth=0 >/dev/null 2>&1 || npm ci
npm run typecheck
npm test
npm run build
node scripts/check-bundle.mjs

case "${1:-}" in
    --opennext) npx opennextjs-cloudflare build ;;
    --e2e)
        scripts/build-site.sh
        npm run e2e
        ;;
esac
