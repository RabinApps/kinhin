#!/bin/bash
# One-shot verification gate: everything CI runs, in one command.
#
# Keep this step list in sync with .github/workflows/ci.yml:
#   test job     : swift format lint --strict -r Sources Tests
#                  swift build -c release --product kinhin-app --product kinhin
#                  swift test
#   docs job     : bash scripts/docs-lint.sh          (GitHub-hosted ubuntu runner)
#                  bash scripts/docs-sync.sh --check
#                  bash scripts/skills-lint.sh
# The String Catalog checks (scripts/l10n-lint.sh) are L10nCatalogTests, so CI's `swift test` already runs
# them; here they get their own stage so a --fast run covers them too.
# The release-only build (KinhinTestSupport is testable-only) stays CI-only:
# it is a compile check CI can afford that a local iteration loop cannot.
#
#   scripts/check.sh          run every gate below, failing fast
#   scripts/check.sh --fast   skip the ~2 min test run (iterate; finish with a full run)
#
# Not included, because they only apply to some changes:
#   scripts/tsan.sh                        shared state / actors / nonisolated(unsafe)
#   cd website && npx vitepress build      after editing docs/ or website/ (dead-link check)
set -euo pipefail

cd "$(dirname "$0")/.."

run_test=1
case "${1:-}" in
    "") ;;
    --fast) run_test=0 ;;
    *)
        echo "usage: $0 [--fast]" >&2
        exit 2
        ;;
esac

stage() {
    echo ""
    echo "==> $1"
}

stage "swift build"
swift build

if [[ $run_test -eq 1 ]]; then
    stage "swift test"
    swift test
else
    stage "swift test (skipped: --fast)"
fi

stage "swift format lint --strict"
swift format lint --strict -r Sources Tests

stage "l10n lint (String Catalog)"
bash scripts/l10n-lint.sh

stage "docs lint (stale strings)"
bash scripts/docs-lint.sh

stage "docs sync (code-derived blocks)"
bash scripts/docs-sync.sh --check

stage "skills lint"
bash scripts/skills-lint.sh

echo ""
echo "check: all gates passed"
