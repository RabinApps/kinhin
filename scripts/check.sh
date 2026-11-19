#!/bin/bash
# One-shot verification gate: everything CI runs, in one command.
#
# Keep this step list in sync with .github/workflows/ci.yml:
#   test job     : swift format lint --strict -r Sources Tests
#                  scripts/warnings-check.sh
#                  swift build -c release --product kinhin-app --product kinhin
#                  swift test --build-system swiftbuild --parallel
#   docs job     : bash scripts/changelog.sh check    (Blacksmith Ubuntu runner)
#                  bash scripts/docs-lint.sh
#                  bash scripts/docs-sync.sh --check
#                  bash scripts/skills-lint.sh
#                  bash scripts/rules-lint.sh
#                  bash scripts/video-check.sh
#                  bash scripts/ci-changes-test.sh
#                  bash scripts/e2e-select-test.sh
# The String Catalog checks (scripts/l10n-lint.sh) are L10nCatalogTests, so CI's `swift test` already runs
# them; here they get their own stage so a --fast run covers them too.
# The release-only build (KinhinTestSupport is testable-only) stays CI-only:
# it is a compile check CI can afford that a local iteration loop cannot.
#
#   scripts/check.sh            run every gate below, failing fast; tests run with --parallel
#   scripts/check.sh --fast     skip the test run (iterate; finish with a full run)
#   scripts/check.sh --serial   run the tests serially (to rule out a parallel-only failure)
#
# --parallel runs each test in its own worker process: about 5.5 minutes instead of 8.5 here. Never combine it
# with ThreadSanitizer; scripts/tsan.sh stays serial on purpose.
#
# Not included, because they only apply to some changes:
#   scripts/tsan.sh                        shared state / actors / nonisolated(unsafe)
#   scripts/website-check.sh --opennext    also build the Cloudflare Worker (slower; CI does it on every docs/website PR)
#   scripts/website-check.sh --e2e         build the Worker and run the Playwright suite (website/e2e; CI runs it on every docs/website PR)
set -euo pipefail

cd "$(dirname "$0")/.."

run_test=1
parallel=1
for arg in "$@"; do
    case "$arg" in
        --fast) run_test=0 ;;
        --serial) parallel=0 ;;
        *)
            echo "usage: $0 [--fast] [--serial]" >&2
            exit 2
            ;;
    esac
done

stage() {
    echo ""
    echo "==> $1"
}

stage "swift build"
swift build --build-system swiftbuild

if [[ $run_test -eq 1 ]]; then
    if [[ $parallel -eq 1 ]]; then
        stage "swift test --parallel"
        swift test --build-system swiftbuild --parallel
    else
        stage "swift test (serial)"
        swift test --build-system swiftbuild
    fi
else
    stage "swift test (skipped: --fast)"
fi

stage "compiler warnings (clean build of Sources and Tests)"
bash scripts/warnings-check.sh

stage "swift format lint --strict"
swift format lint --strict -r Sources Tests

stage "l10n lint (String Catalog)"
bash scripts/l10n-lint.sh

stage "changelog structure"
bash scripts/changelog.sh check

stage "docs lint (stale strings)"
bash scripts/docs-lint.sh

stage "docs sync (code-derived blocks)"
bash scripts/docs-sync.sh --check

stage "website (content pipeline + dead links, typecheck, tests, next build)"
bash scripts/website-check.sh

stage "skills lint"
bash scripts/skills-lint.sh

stage "rules lint (try!, as!, force unwraps, locks, try?, file length)"
bash scripts/rules-lint.sh

stage "video suite (claims, ci.json, unit tests)"
bash scripts/video-check.sh

stage "CI change selection (scripts/ci-changes.sh table test)"
bash scripts/ci-changes-test.sh

stage "e2e spec selection (scripts/e2e-select.sh table test)"
bash scripts/e2e-select-test.sh

echo ""
echo "check: all gates passed"
