#!/bin/bash
# The release artifacts that follow the DMG: the signed CLI zip, the Gatekeeper
# verification pass, the Team-ID-stamped installer, and checksums.txt.
#
# Usage: scripts/release-artifacts.sh [--no-notarize] <version>
#
# Called by scripts/release.sh (a local run from this checkout) and by
# .github/workflows/release.yml (the v* tag publish), so both paths execute
# the same code and cannot drift apart. Environment:
#   CODESIGN_IDENTITY   Developer ID identity; ad-hoc ("-") is refused here.
#   NOTARY_KEYCHAIN_PROFILE, or NOTARY_KEY_PATH / NOTARY_KEY_ID / NOTARY_ISSUER_ID
#                       notarization credentials (see scripts/notarize.sh).
# Expects dist/kinhin-<version>-arm64.dmg to already exist (make-dmg.sh).
#
# --no-notarize is for local smoke runs only: it skips notarization and every
# check that depends on it (stapler, spctl), so the output is NOT Gatekeeper-
# verified and must never be published.
set -euo pipefail
cd "$(dirname "$0")/.."

NO_NOTARIZE=0
if [ "${1:-}" = "--no-notarize" ]; then
    NO_NOTARIZE=1
    shift
fi
VERSION="${1:?usage: release-artifacts.sh [--no-notarize] <version>}"
# Same shape release.yml accepts for a tag: plain semver, optional beta suffix.
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-beta-[0-9]+)?$ ]] || {
    echo "FATAL: version '$VERSION' is not MAJOR.MINOR.PATCH[-beta-N]" >&2
    exit 1
}

# Resolved like release.sh does: a resume run has no inherited env, so fall
# back to the first Developer ID identity in the keychain. Ad-hoc ("-") is
# never a release — it cannot be notarized and Gatekeeper refuses it.
# Names are resolved to the identity's SHA-1 hash: this keychain holds two
# certificates with the same "Developer ID Application: …" name, and codesign
# refuses a name as ambiguous, while the hash is unique and equally accepted.
identity_hash() {
    security find-identity -v -p codesigning |
        awk -v want="$1" -F'"' '$2 == want { sub(/^.*\) /, "", $1); gsub(/[ \t]/, "", $1); print $1; exit }'
}
if [ -z "${CODESIGN_IDENTITY:-}" ]; then
    CODESIGN_IDENTITY="$(security find-identity -v -p codesigning |
        sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
fi
if [ "$CODESIGN_IDENTITY" != "-" ] && [ -n "$CODESIGN_IDENTITY" ]; then
    resolved="$(identity_hash "$CODESIGN_IDENTITY" || true)"
    [ -n "$resolved" ] && CODESIGN_IDENTITY="$resolved"
fi
if [ -z "$CODESIGN_IDENTITY" ] || [ "$CODESIGN_IDENTITY" = "-" ]; then
    echo "FATAL: CODESIGN_IDENTITY must name a Developer ID identity (ad-hoc is never a release)" >&2
    exit 1
fi
echo "==> codesign: $CODESIGN_IDENTITY"

DMG="dist/kinhin-$VERSION-arm64.dmg"
if [ ! -f "$DMG" ]; then
    echo "FATAL: $DMG missing — run scripts/make-dmg.sh first" >&2
    exit 1
fi
if [ "$NO_NOTARIZE" = 1 ]; then
    echo "WARNING: --no-notarize — artifacts below are signed but not notarized," >&2
    echo "         Gatekeeper checks are skipped, and nothing here may be published." >&2
fi

stage() {
    echo ""
    echo "==> $1"
}

# --- 1. CLI zip -------------------------------------------------------------
# The app bundle carries the CLI at Resources/bin/kinhin; this is the zip for
# installs that only want the command.
stage "CLI zip: dist/kinhin-cli-$VERSION-arm64.zip"
ZIP="dist/kinhin-cli-$VERSION-arm64.zip"
if [ -f "$ZIP" ] && [ -f "$ZIP.notary" ]; then
    # A previous run uploaded it and is still waiting on Apple: rebuilding would
    # produce different bytes (zip embeds mtimes) and force a second submission.
    echo "    resuming the recorded submission (not rebuilding)"
else
    BIN_DIR="$(swift build --build-system swiftbuild -c release --show-bin-path --product kinhin)"
    mkdir -p dist/cli
    cp "$BIN_DIR/kinhin" dist/cli/kinhin
    codesign --force --sign "$CODESIGN_IDENTITY" --options runtime --timestamp dist/cli/kinhin
    codesign --verify --strict --verbose=2 dist/cli/kinhin
    # zip updates an existing archive in place, which would keep stale entries —
    # and its notary sidecar would otherwise describe the bytes we just replaced.
    rm -f "$ZIP" "$ZIP.notary"
    (cd dist/cli && zip ../kinhin-cli-"$VERSION"-arm64.zip kinhin)
fi
if [ "$NO_NOTARIZE" = 0 ]; then
    ./scripts/notarize.sh "$ZIP"
else
    echo "    (notarization skipped: --no-notarize)"
fi

# --- 2. Gatekeeper + version verification -----------------------------------
# Everything below runs against the mounted DMG, so what ships is what passes.
stage "verify Gatekeeper acceptance: $DMG"
if [ "$NO_NOTARIZE" = 0 ]; then
    xcrun stapler validate "$DMG"
    spctl -a -vv -t open --context context:primary-signature "$DMG"
else
    echo "    (stapler/spctl skipped: --no-notarize)"
fi
MOUNT="$(mktemp -d)"
hdiutil attach "$DMG" -mountpoint "$MOUNT" -nobrowse -quiet
trap 'hdiutil detach "$MOUNT" -quiet || true' EXIT
codesign --verify --deep --strict --verbose=2 "$MOUNT/kinhin.app"
reported="$("$MOUNT/kinhin.app/Contents/Resources/bin/kinhin" version)"
if [ "$reported" != "kinhin $VERSION" ]; then
    echo "FATAL: bundle CLI reports '$reported', expected 'kinhin $VERSION'" >&2
    exit 1
fi
if [ "$NO_NOTARIZE" = 0 ]; then
    spctl -a -vv -t exec "$MOUNT/kinhin.app"
fi
# Pin the installer to the team that actually signed the app: without it
# install.sh falls back to "any valid signature", and the only anchor left is
# a checksum served from the same release.
TEAM_ID="$(codesign -dv --verbose=4 "$MOUNT/kinhin.app" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
hdiutil detach "$MOUNT" -quiet || true
trap - EXIT

# --- 3. Stamped installer ---------------------------------------------------
stage "stage installer: dist/install.sh"
if ! [[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
    echo "FATAL: could not read the Team ID from the signed app ('$TEAM_ID')" >&2
    exit 1
fi
sed "s/@TEAM_ID@/$TEAM_ID/" scripts/install.sh > dist/install.sh
if grep -q '@TEAM_ID@' dist/install.sh; then
    echo "FATAL: install.sh still carries the @TEAM_ID@ placeholder" >&2
    exit 1
fi
if ! grep -q "^TEAM_ID=\"$TEAM_ID\"" dist/install.sh; then
    echo "FATAL: Team ID was not stamped into install.sh" >&2
    exit 1
fi
echo "    TEAM_ID=$TEAM_ID"

# --- 4. Checksums -----------------------------------------------------------
# Pinned to this version's files: dist/ is a local workbench, and a wildcard
# would silently checksum whatever older artifacts happen to be lying around.
stage "checksums: dist/checksums.txt"
(cd dist && shasum -a 256 \
    "kinhin-$VERSION-arm64.dmg" \
    "kinhin-cli-$VERSION-arm64.zip" \
    install.sh > checksums.txt)
cat dist/checksums.txt

echo ""
echo "release-artifacts: done (version $VERSION)"
