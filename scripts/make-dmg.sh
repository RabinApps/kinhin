#!/bin/bash
# Packages the app bundle into a distributable DMG.
# Usage: scripts/make-dmg.sh
#
# With CODESIGN_IDENTITY set to a Developer ID identity the DMG is signed too;
# with NOTARY_KEY_PATH / NOTARY_KEY_ID / NOTARY_ISSUER_ID set it is also
# notarized and stapled (see scripts/notarize.sh).
set -euo pipefail

VERSION="${KINHIN_VERSION:-0.1.0}"
OUT_DIR="dist"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

./scripts/build-app.sh "$OUT_DIR"

# Stage only the app and an /Applications shortcut: packaging $OUT_DIR itself
# would also pull in any other artifact left there (CLI zip, older DMGs).
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$OUT_DIR/kinhin.app" "$STAGE/kinhin.app"
ln -s /Applications "$STAGE/Applications"

DMG="$OUT_DIR/kinhin-$VERSION-arm64.dmg"
echo "==> hdiutil create $DMG"
rm -f "$DMG"
hdiutil create \
    -volname "kinhin $VERSION" \
    -srcfolder "$STAGE" \
    -ov \
    -format UDZO \
    "$DMG"

if [ "$CODESIGN_IDENTITY" != "-" ]; then
    echo "==> codesign DMG ($CODESIGN_IDENTITY)"
    codesign --force --sign "$CODESIGN_IDENTITY" --timestamp "$DMG"
    codesign --verify --strict "$DMG"
fi

./scripts/notarize.sh "$DMG"

echo "==> DMG ready: $DMG"
echo "    Install by dragging kinhin.app to /Applications."
if [ "$CODESIGN_IDENTITY" = "-" ]; then
    echo "    Unsigned build: right-click -> Open on first launch, or:"
    echo "      xattr -cr /Applications/kinhin.app"
fi
