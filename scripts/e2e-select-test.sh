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
expect specs "e2e/home.spec.ts" website/e2e/home.spec.ts website/e2e/visual.spec.ts
expect specs "e2e/home.spec.ts" website/e2e/home.spec.ts website/e2e/__screenshots__/desktop/visual.spec.ts/home-dark.png
# Visual specs are opt-in: alone they select nothing (Playwright fails with "No tests found"), unless E2E_VISUAL is set.
expect none "" website/e2e/visual.spec.ts
expect none "" website/e2e/__screenshots__/desktop/visual.spec.ts/home-dark.png
expect none "" website/e2e/__screenshots__/mobile/visual.spec.ts/home-dark.png website/e2e/visual.spec.ts
E2E_VISUAL=1 expect specs "e2e/visual.spec.ts" website/e2e/__screenshots__/desktop/visual.spec.ts/home-dark.png
E2E_VISUAL=1 expect specs "e2e/visual.spec.ts" website/e2e/visual.spec.ts
# A baseline whose spec was deleted.
expect all "" website/e2e/__screenshots__/desktop/gone.spec.ts/home-dark.png
# A baseline that is not under a spec's directory is not understood: everything.
expect all "" website/e2e/__screenshots__/desktop/orphan.png
# Deleted specs (no file on disk) and quoted paths run everything.
expect all "" website/e2e/removed.spec.ts
expect all "" website/e2e/home.spec.ts website/e2e/removed.spec.ts
expect all "" '"website/public/\346\227\245.png"'
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

# Through git, not --stdin: a non-ASCII filename must not be quoted (core.quotepath) and so missed, and a deleted spec
# must run everything. Runs in a throwaway repository, so the real one is untouched.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
(
    cd "$tmp"
    git init -q
    git config user.email t@example.com
    git config user.name t
    git config commit.gpgsign false
    mkdir -p scripts website/e2e website/public website/e2e/__screenshots__/desktop/visual.spec.ts
    cp "$OLDPWD/scripts/e2e-select.sh" scripts/
    : >website/e2e/home.spec.ts
    : >website/e2e/seo.spec.ts
    : >website/e2e/visual.spec.ts
    : >website/e2e/__screenshots__/desktop/visual.spec.ts/home.png
    git add -A && git commit -q -m base
    base=$(git rev-parse HEAD)
    check() { # check <e2e> <label> [specs]: what consumers act on (none skips Playwright, specs runs only those)
        out=$(bash scripts/e2e-select.sh "$base")
        got=$(sed -n 's/^e2e=//p' <<<"$out")
        got_specs=$(sed -n 's/^specs=//p' <<<"$out")
        if [[ $got != "$1" || $got_specs != "${3:-}" ]]; then
            echo "FAIL (git): $2 -> e2e=$got specs='$got_specs' (want $1 '${3:-}')"
            exit 1
        fi
    }
    : >"website/public/日本語.png"
    git add -A && git commit -q -m asset
    check all "non-ASCII website asset"
    git reset -q --hard "$base"
    git rm -q website/e2e/seo.spec.ts && git commit -q -m delete
    check all "deleted spec"
    git reset -q --hard "$base"
    echo x >website/e2e/home.spec.ts && git commit -q -am edit
    check specs "edited spec" "e2e/home.spec.ts"
    git reset -q --hard "$base"
    echo x >website/e2e/visual.spec.ts && echo x >website/e2e/__screenshots__/desktop/visual.spec.ts/home.png && git commit -q -am visual
    check none "visual-only change skips Playwright"
    echo x >website/e2e/home.spec.ts && git commit -q -am mixed
    check specs "visual and enabled spec runs only the enabled one" "e2e/home.spec.ts"
    git reset -q --hard "$base"
    git rm -q website/e2e/visual.spec.ts && git commit -q -m delete-visual
    check all "deleted spec"
    # A baseline whose spec is already gone (deleted before the base) and then changes.
    git reset -q --hard "$base"
    git rm -q website/e2e/visual.spec.ts && git commit -q -m orphaned
    base=$(git rev-parse HEAD)
    echo y >website/e2e/__screenshots__/desktop/visual.spec.ts/home.png && git commit -q -am baseline
    E2E_VISUAL=1 check all "changed baseline of a deleted spec"
) || failures=$((failures + 1))

if [[ $failures -ne 0 ]]; then
    echo "e2e-select test: $failures case(s) failed" >&2
    exit 1
fi
echo "e2e-select test: all cases passed"
