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
set -euo pipefail

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
    swift build --product kinhin-app
    BIN="$(swift build --show-bin-path --product kinhin-app)/kinhin-app"
fi

if [ -n "$IDENTITY" ]; then
    echo "==> codesign ($IDENTITY)"
    codesign --force --sign "$IDENTITY" --identifier "${KINHIN_BUNDLE_ID:-com.RabinApps.kinhin}" "$BIN"
fi

echo "==> running $BIN"
exec "$BIN" "$@"
