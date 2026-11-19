#!/bin/bash
# Decide which Playwright specs (website/e2e) a change needs, from the files it changes.
#
#   scripts/e2e-select.sh                  changed files = since the previous commit (HEAD~1...HEAD) plus uncommitted work
#   scripts/e2e-select.sh <base-ref>       changed files = `git diff --name-only --no-renames <base-ref>...HEAD` (CI: the PR base)
#   scripts/e2e-select.sh --stdin          changed files = one path per line on stdin (used by the test)
#
# Prints key=value lines (append them to $GITHUB_OUTPUT):
#   e2e=none|specs|all   none: nothing the browser tests can see changed; specs: run only the specs in `specs`; all: whole suite
#   specs=<paths>        space-separated, relative to website/ (e.g. `e2e/home.spec.ts e2e/seo.spec.ts`); empty unless e2e=specs
#
# The specs test the built site, so a change to anything the site is built from (website/src, public, content, config,
# docs/, e2e/support, the Playwright config, the lockfile ...) can break a spec that did not change: that runs everything.
# The suite narrows only when every change under docs/ or website/ is a spec file (or its visual snapshots). Changes
# outside docs/ and website/ need no browser tests, except the workflow and gate script that run them. An unknown path under
# docs/ or website/ must never skip tests; an unresolvable base runs everything. Bash 3.2 compatible.
#
# This is the fast path for pull requests and local runs. Pushes to develop and releases always run everything.
set -euo pipefail

cd "$(dirname "$0")/.."

case "${1:-}" in
    --stdin) files=$(cat) ;;
    "")
        if git rev-parse --verify --quiet HEAD~1 >/dev/null; then
            files=$(
                git diff --name-only --no-renames HEAD~1...HEAD
                git diff --name-only --no-renames HEAD
                git ls-files --others --exclude-standard
            )
        else
            files="website/package.json" # no previous commit: run everything
        fi
        ;;
    *)
        if files=$(git diff --name-only --no-renames "$1"...HEAD 2>/dev/null); then
            :
        else
            files="website/package.json" # base not resolvable (shallow clone, bad ref): run everything
        fi
        ;;
esac

all=false
specs=""

add_spec() {
    case " $specs " in
        *" $1 "*) ;;
        *) specs="${specs:+$specs }$1" ;;
    esac
}

while IFS= read -r path; do
    [[ -z $path ]] && continue
    case "$path" in
        # A spec itself (not a helper in e2e/support/).
        website/e2e/*.spec.ts) add_spec "${path#website/}" ;;
        # Its visual snapshots belong to one spec: website/e2e/<spec>.spec.ts-snapshots/...
        website/e2e/*.spec.ts-snapshots/*)
            snap=${path#website/e2e/}
            add_spec "e2e/${snap%%-snapshots/*}"
            ;;
        # What runs the browser tests: a change here is a change to them.
        .github/workflows/docs.yml | scripts/website-check.sh | scripts/e2e-select.sh) all=true ;;
        # Everything else the site is built from or checked against.
        docs/* | website/*) all=true ;;
        # Swift, skills, video, design, other workflows: not visible to the browser tests.
        *) ;;
    esac
done <<<"$files"

if [[ $all == true ]]; then
    echo "e2e=all"
    echo "specs="
elif [[ -n $specs ]]; then
    echo "e2e=specs"
    echo "specs=$specs"
else
    echo "e2e=none"
    echo "specs="
fi
