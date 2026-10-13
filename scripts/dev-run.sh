#!/bin/bash
# Builds the debug menu bar app, signs it with a stable identity, and runs it.
#
# Why: the Keychain trusts specific signed binaries. A plain `swift build`
# binary gets a new ad-hoc signature on every rebuild, so macOS asks for
# Keychain access again after each one. Signing with the same identity and
# identifier every time keeps the "Always Allow" answer valid across rebuilds
# (click Always Allow once, the first time).
#
# With --env-tokens the Keychain is not used at all: forge tokens are read from
# environment variables (KINHIN_TOKEN_GITHUB, KINHIN_TOKEN_GITEA, and
# KINHIN_TOKEN_<ACCOUNT> for named accounts), loaded from a git-ignored
# .env.dev file (copy .env.dev.example). Debug builds only; tokens typed into
# the app in this mode last for that run. Signing is skipped (nothing needs it).
#
# Usage: scripts/dev-run.sh [--env-tokens] [app arguments]
#   e.g. scripts/dev-run.sh -kinhin.autoStartFleet NO   (one-off pref override)
#        scripts/dev-run.sh --env-tokens
# Env:   KINHIN_DEV_ENV_FILE  env file for --env-tokens (default .env.dev)
#        CODESIGN_IDENTITY  signing identity (default: first "Apple Development"
#                           identity in your keychain; see
#                           `security find-identity -v -p codesigning`)
#        KINHIN_BUNDLE_ID   signing identifier (default com.RabinApps.kinhin)
#
# WARNING: do not run this script via `launchctl submit` or any other
# launchd-based runner. launchd will restart the script every time the app
# exits, creating an infinite restart loop. Always run from a terminal, or
# via `swift package --disable-sandbox dev`.
set -euo pipefail

# If running under launchd (not a terminal), refuse to start. launchd will
# restart this script every time the app exits, creating an infinite loop.
# launchd jobs have no TTY on stdin/stdout, so we check for that.
if [ ! -t 0 ] && [ ! -t 1 ]; then
    echo "ERROR: dev-run.sh does not appear to be running in a terminal." >&2
    echo "Launching under a process supervisor (launchd, etc.) causes an" >&2
    echo "infinite restart loop when the app exits. Run from a terminal." >&2
    echo "Use 'swift package --disable-sandbox dev' or run from a terminal." >&2
    exit 1
fi

ENV_TOKENS=0
if [ "${1:-}" = "--env-tokens" ]; then
    ENV_TOKENS=1
    shift
    ENV_FILE="${KINHIN_DEV_ENV_FILE:-.env.dev}"
    if [ -f "$ENV_FILE" ]; then
        echo "==> loading tokens from $ENV_FILE"
        set -a
        # shellcheck disable=SC1090
        . "$ENV_FILE"
        set +a
    else
        echo "No $ENV_FILE found (copy .env.dev.example); using variables already in the environment." >&2
    fi
    export KINHIN_TOKEN_STORE=env
fi

IDENTITY="${CODESIGN_IDENTITY:-}"
if [ "$ENV_TOKENS" = 1 ]; then
    IDENTITY=""
elif [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)"
fi
if [ -z "$IDENTITY" ] && [ "$ENV_TOKENS" = 0 ]; then
    echo "No 'Apple Development' signing identity found; running unsigned (Keychain will prompt after every rebuild)." >&2
fi

# KINHIN_APP_BIN=<path>: the caller already built the app (the `swift package dev`
# plugin does; any `swift build` run from inside it would wait on the package
# lock the plugin holds), so skip the build and use that binary.
if [ -n "${KINHIN_APP_BIN:-}" ]; then
    BIN="$KINHIN_APP_BIN"
else
    echo "==> swift build --product kinhin-app"
    swift build --build-system swiftbuild --product kinhin-app
    BIN="$(swift build --build-system swiftbuild --show-bin-path --product kinhin-app)/kinhin-app"
fi

if [ -n "$IDENTITY" ]; then
    echo "==> codesign ($IDENTITY)"
    codesign --force --sign "$IDENTITY" --identifier "${KINHIN_BUNDLE_ID:-com.RabinApps.kinhin}" "$BIN"
fi

# Localized strings: SwiftUI/AppKit look them up in Bundle.main, which for this bare binary is its build
# directory, while SwiftPM compiles the String Catalog into the app's resource bundle. Mirror the
# bundled app (scripts/build-app.sh) by placing the *.lproj folders next to the binary.
BIN_DIR="$(dirname "$BIN")"
for lproj in "$BIN_DIR"/kinhin_kinhin-app.bundle/Contents/Resources/*.lproj; do
    [ -d "$lproj" ] && cp -R "$lproj" "$BIN_DIR/"
done

echo "==> running $BIN"
exec "$BIN" "$@"
