#!/bin/bash
# Website gate: the content pipeline (fails on dead links), typecheck, unit tests and a production build.
# Run after editing docs/ or website/. Installs dependencies on first use.
#   scripts/website-check.sh --opennext   also build the Cloudflare Worker and check its size (what CI deploys)
#   scripts/website-check.sh --e2e        also build the whole site (release snapshots included), check the Worker's
#                                         size, smoke-test it and run the browser tests (website/e2e); needs Chromium
#                                         (`cd website && npx playwright install chromium`, or set CHROMIUM_PATH)
set -euo pipefail

case "${1:-}" in
    "" | --opennext | --e2e) ;;
    *)
        echo "usage: $0 [--opennext|--e2e]" >&2
        exit 2
        ;;
esac
mode="${1:-}"

cd "$(dirname "$0")/../website"
# Install unless node_modules matches package.json + package-lock.json and still satisfies them. A stale tree (a
# dependency added or bumped since the last install) would otherwise fail later with ERR_MODULE_NOT_FOUND, before any
# check runs; a lockfile-only update is invisible to `npm ls`, so the two files are hashed into a stamp.
stamp=node_modules/.install-stamp
want=$(node -e 'const c = require("node:crypto"), fs = require("node:fs"); process.stdout.write(c.createHash("sha256").update(fs.readFileSync("package-lock.json")).update(fs.readFileSync("package.json")).digest("hex"))')
if [ ! -d node_modules ] || [ "$(cat "$stamp" 2>/dev/null)" != "$want" ] || ! npm ls --depth=0 >/dev/null 2>&1; then
    npm ci
    printf '%s\n' "$want" >"$stamp"
fi
npm run typecheck
npm test
npm run build
node scripts/check-bundle.mjs

case "$mode" in
    --opennext)
        npx opennextjs-cloudflare build
        scripts/check-worker-size.sh
        ;;
    --e2e)
        # The order CI uses: every release snapshot, the latest docs, the Worker build, then the checks against it.
        scripts/build-site.sh
        scripts/check-worker-size.sh
        scripts/smoke.sh
        npm run e2e
        ;;
esac
