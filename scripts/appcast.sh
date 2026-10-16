#!/bin/bash
# Writes the Sparkle appcast for one release: a single item that points at the
# release DMG on GitHub and carries that DMG's EdDSA signature. The release
# workflow publishes it to kinhin.dev (docs.yml), where the app reads it.
#
# Usage: scripts/appcast.sh <version> <dmg> <out-file>
#   <version>               the release version, e.g. 0.0.1-beta-3 (no leading v)
#   SPARKLE_ED_PRIVATE_KEY  the private EdDSA key, as `generate_keys -x` writes it (required)
#   SPARKLE_TOOLS           directory with Sparkle's bin/generate_appcast (default: on PATH)
#   GITHUB_REPOSITORY       owner/name the DMG is downloaded from (default: RabinApps/kinhin)
set -euo pipefail

VERSION="${1:?usage: scripts/appcast.sh <version> <dmg> <out-file>}"
DMG="${2:?usage: scripts/appcast.sh <version> <dmg> <out-file>}"
OUT="${3:?usage: scripts/appcast.sh <version> <dmg> <out-file>}"
REPO="${GITHUB_REPOSITORY:-RabinApps/kinhin}"

if [ -z "${SPARKLE_ED_PRIVATE_KEY:-}" ]; then
    echo "FATAL: SPARKLE_ED_PRIVATE_KEY is not set; an appcast without a signature is refused by the app" >&2
    exit 1
fi
if [ ! -f "$DMG" ]; then
    echo "FATAL: $DMG not found" >&2
    exit 1
fi
GENERATE="generate_appcast"
if [ -n "${SPARKLE_TOOLS:-}" ]; then
    GENERATE="$SPARKLE_TOOLS/bin/generate_appcast"
fi
if ! command -v "$GENERATE" >/dev/null 2>&1 && [ ! -x "$GENERATE" ]; then
    echo "FATAL: $GENERATE not found; set SPARKLE_TOOLS to a Sparkle distribution" >&2
    exit 1
fi

# The bundle's CFBundleVersion, which Sparkle compares (the same mapping build-app.sh uses).
source "$(dirname "$0")/bundle-version.sh"
BUILD="$(bundle_version "$VERSION")"

# generate_appcast scans its whole directory for archives, so give it a directory
# that holds only this DMG. The key lives in its own directory and is deleted on exit.
work="$(mktemp -d)"
keydir="$(mktemp -d)"
trap 'rm -rf "$work" "$keydir"' EXIT
cp "$DMG" "$work/"
keyfile="$keydir/ed25519-private-key"
(umask 077 && printf '%s' "$SPARKLE_ED_PRIVATE_KEY" > "$keyfile")

"$GENERATE" \
    --ed-key-file "$keyfile" \
    --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
    -o "$work/appcast.xml" \
    "$work" >/dev/null || { echo "FATAL: generate_appcast failed (see its output above)" >&2; exit 1; }

# Refuse an appcast that does not describe this build: a missing signature, or a
# version the app would not treat as newer than the one it is built from.
for want in "<sparkle:version>$BUILD</sparkle:version>" "sparkle:edSignature"; do
    if ! grep -q -- "$want" "$work/appcast.xml"; then
        echo "FATAL: generated appcast lacks $want; not publishing it" >&2
        exit 1
    fi
done

mv "$work/appcast.xml" "$OUT"
echo "==> appcast for $VERSION (sparkle:version $BUILD): $OUT"
