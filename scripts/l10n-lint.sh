#!/bin/bash
# Localization gate for the menu bar app's String Catalog.
#
#   scripts/l10n-lint.sh          check  Sources/kinhin-app/Resources/Localizable.xcstrings against the sources
#   scripts/l10n-lint.sh --sync   add catalog entries for new strings and drop stale ones, then re-check
#
# The checks are L10nCatalogTests (Tests/KinhinAppTests), so `swift test` runs them too; this script exists to run
# them alone, fast, and to host the --sync recipe. They fail when:
#   - a user-facing literal (String(localized:), Text("…"), Button("…"), FormCard(title:), …) has no catalog entry
#   - a catalog entry is no longer referenced by any source
#   - an entry whose comment says "plural by …" has no English plural variations
#   - a translation drops or invents a printf placeholder
#   - a sentence-like literal sits outside every localizing call (new hard-coded English)
# See "Localization" in CONTRIBUTING.md.
set -euo pipefail

cd "$(dirname "$0")/.."

CATALOG="Sources/kinhin-app/Resources/Localizable.xcstrings"

case "${1:-}" in
    "") ;;
    --sync)
        echo "==> syncing $CATALOG with the sources"
        KINHIN_UPDATE_L10N=1 swift test --build-system swiftbuild --filter L10nCatalogTests/testCatalogMatchesSources >/dev/null
        ;;
    *)
        echo "usage: $0 [--sync]" >&2
        exit 2
        ;;
esac

# Cheap syntax gate first: a broken catalog would otherwise fail the build with a less helpful message.
plutil -convert xml1 -o /dev/null "$CATALOG"

swift test --build-system swiftbuild --filter L10nCatalogTests
echo "l10n lint: ok"
