#!/bin/bash
# Builds the debug menu bar app, signs it with a stable identity, and runs it.
#
# Why: the Keychain trusts specific signed binaries. A plain `swift build`
# binary gets a new ad-hoc signature on every rebuild, so macOS asks for
# Keychain access again after each one. Signing with the same identity and
# identifier every time keeps the "Always Allow" answer valid across rebuilds
# (click Always Allow once, the first time).
#
# Usage: scripts/dev-run.sh [app arguments]
#   e.g. scripts/dev-run.sh -kinhin.autoStartFleet NO   (one-off pref override)
# Env:   CODESIGN_IDENTITY  signing identity (default: first "Apple Development"
#                           identity in your keychain; see
#                           `security find-identity -v -p codesigning`)
#        KINHIN_BUNDLE_ID   signing identifier (default com.RabinApps.kinhin)
set -euo pipefail

IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)"
fi
if [ -z "$IDENTITY" ]; then
    echo "No 'Apple Development' signing identity found; running unsigned (Keychain will prompt after every rebuild)." >&2
fi

echo "==> swift build --product kinhin-app"
swift build --product kinhin-app
BIN="$(swift build --show-bin-path --product kinhin-app)/kinhin-app"

if [ -n "$IDENTITY" ]; then
    echo "==> codesign ($IDENTITY)"
    codesign --force --sign "$IDENTITY" --identifier "${KINHIN_BUNDLE_ID:-com.RabinApps.kinhin}" "$BIN"
fi

echo "==> running $BIN"
exec "$BIN" "$@"
