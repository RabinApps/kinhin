#!/bin/bash
# Packages the app bundle into a distributable DMG.
# Usage: scripts/make-dmg.sh
set -euo pipefail

VERSION="${KINHIN_VERSION:-0.1.0}"
OUT_DIR="dist"

./scripts/build-app.sh "$OUT_DIR"

DMG="$OUT_DIR/kinhin-$VERSION-arm64.dmg"
echo "==> hdiutil create $DMG"
rm -f "$DMG"
hdiutil create \
    -volname "kinhin" \
    -srcfolder "$OUT_DIR" \
    -ov \
    -format UDZO \
    "$DMG"

echo "==> DMG ready: $DMG"
echo "    Install by dragging kinhin.app to /Applications."
echo "    Unsigned build: right-click -> Open on first launch, or:"
echo "      xattr -cr /Applications/kinhin.app"
