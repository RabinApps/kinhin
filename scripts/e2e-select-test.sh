#!/bin/bash
# Table test for scripts/e2e-select.sh: each case is a list of changed paths and the expected `e2e`/`specs` output.
# Runs in scripts/check.sh. No toolchain needed.
set -euo pipefail

cd "$(dirname "$0")/.."

failures=0

expect() { # expect <e2e> <specs> <path>...
    local want_e2e=$1 want_specs=$2
    shift 2
    local out
    out=$(printf '%s\n' "$@" | bash scripts/e2e-select.sh --stdin)
    local got_e2e got_specs
    got_e2e=$(sed -n 's/^e2e=//p' <<<"$out")
    got_specs=$(sed -n 's/^specs=//p' <<<"$out")
    if [[ $got_e2e != "$want_e2e" || $got_specs != "$want_specs" ]]; then
        echo "FAIL: $* -> e2e=$got_e2e specs='$got_specs' (want e2e=$want_e2e specs='$want_specs')"
        failures=$((failures + 1))
    fi
}

# Spec-only changes narrow.
expect specs "e2e/home.spec.ts" website/e2e/home.spec.ts
expect specs "e2e/home.spec.ts e2e/seo.spec.ts" website/e2e/home.spec.ts website/e2e/seo.spec.ts
expect specs "e2e/home.spec.ts" website/e2e/home.spec.ts website/e2e/home.spec.ts
expect specs "e2e/home.spec.ts" website/e2e/home.spec.ts Sources/kinhin/Main.swift README.md
expect specs "e2e/visual.spec.ts" website/e2e/visual.spec.ts-snapshots/home-desktop-linux.png
expect specs "e2e/visual.spec.ts" website/e2e/visual.spec.ts website/e2e/visual.spec.ts-snapshots/home-desktop-linux.png
# Nothing the browser tests can see.
expect none "" Sources/kinhin/Main.swift Tests/KinhinCLITests/FooTests.swift
expect none "" skills/kinhin-x/SKILL.md video/script/launch.json design/kinhin-app.fig README.md
expect none "" .github/workflows/ci.yml scripts/check.sh
expect none "" # no files at all
# Anything the site is built from, or the browser tests share, runs everything.
expect all "" website/src/app/page.tsx
expect all "" website/e2e/home.spec.ts website/src/app/page.tsx
expect all "" website/e2e/support/site.ts
expect all "" website/e2e/support/fixtures.ts website/e2e/home.spec.ts
expect all "" website/playwright.config.ts
expect all "" website/package-lock.json
expect all "" website/versions.json
expect all "" website/public/_headers
expect all "" website/guide/quick-start.md
expect all "" docs/guide.md
expect all "" docs/forges/azuredevops.md website/e2e/home.spec.ts
expect all "" website/some-new-file.txt
# What runs the browser tests.
expect all "" .github/workflows/docs.yml
expect all "" scripts/website-check.sh
expect all "" scripts/e2e-select.sh

if [[ $failures -ne 0 ]]; then
    echo "e2e-select test: $failures case(s) failed" >&2
    exit 1
fi
echo "e2e-select test: all cases passed"
