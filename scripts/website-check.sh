#!/bin/bash
# Website gate: the content pipeline (fails on dead links), typecheck, unit tests and a production build.
# Run after editing docs/ or website/. Installs dependencies on first use.
#   scripts/website-check.sh --opennext   also build the Cloudflare Worker and check its size (what CI deploys)
#   scripts/website-check.sh --e2e        also build the whole site (release snapshots included), check the Worker's
#                                         size, smoke-test it and run the browser tests (website/e2e); needs Chromium
#                                         (`cd website && npx playwright install chromium`, or set CHROMIUM_PATH).
#                                         Runs only the specs changed since the previous commit (plus uncommitted work)
#                                         when nothing else under docs/ or website/ changed, and nothing at all when
#                                         neither did (scripts/e2e-select.sh)
#   scripts/website-check.sh --e2e-all    the same, but always the whole Playwright suite
set -euo pipefail

case "${1:-}" in
    "" | --opennext | --e2e | --e2e-all) ;;
    *)
        echo "usage: $0 [--opennext|--e2e|--e2e-all]" >&2
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
    --e2e | --e2e-all)
        # Which specs: only the ones changed since the previous commit (and uncommitted), unless something the site is
        # built from changed too; --e2e-all always runs everything. See scripts/e2e-select.sh.
        e2e=all
        specs=""
        if [ "$mode" = --e2e ]; then
            selection=$(../scripts/e2e-select.sh)
            e2e=$(sed -n 's/^e2e=//p' <<<"$selection")
            specs=$(sed -n 's/^specs=//p' <<<"$selection")
        fi
        if [ "$e2e" = none ]; then
            echo "e2e: nothing the browser tests cover changed since the previous commit; skipping them (--e2e-all to run them)"
            exit 0
        fi
        # The order CI uses: every release snapshot, the latest docs, the Worker build, then the checks against it.
        scripts/build-site.sh
        scripts/check-worker-size.sh
        scripts/smoke.sh
        if [ "$e2e" = specs ]; then
            echo "e2e: running only the changed specs: $specs"
            # shellcheck disable=SC2086 # space-separated spec paths without spaces
            npx playwright test $specs
        else
            npm run e2e
        fi
        ;;
esac
