#!/bin/bash
# Builds the kinhin menu bar app bundle from the Swift package.
# Usage: scripts/build-app.sh [output-dir]
set -euo pipefail

VERSION="${KINHIN_VERSION:-0.1.0}"
OUT_DIR="${1:-dist}"
APP="$OUT_DIR/kinhin.app"
CONFIGURATION="${CONFIGURATION:-release}" # lowercase: debug|release

# Build the shipped products explicitly: the test-support target is testable-only
# and does not compile in release.
echo "==> swift build -c $CONFIGURATION"
swift build -c "$CONFIGURATION" --product kinhin-app
swift build -c "$CONFIGURATION" --product kinhin

BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path --product kinhin-app)"
# Assemble from scratch — never patch over a previous bundle (stale binaries).
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources/bin"

echo "==> assembling $APP"
# Chain of custody: hash every binary before and after copying so a stale
# artifact can never sneak into the bundle (this class of bug once shipped an
# old CLI in the DMG and made the app's buttons appear broken).
cp "$BIN_DIR/kinhin-app" "$APP/Contents/MacOS/kinhin"
# The CLI lives at Resources/bin/kinhin — a different directory from MacOS/,
# so it never collides with the bundle executable on case-insensitive APFS
# (the pre-rename bundle relied on 'Orchard' vs 'orchard' casing to avoid this).
cp "$BIN_DIR/kinhin" "$APP/Contents/Resources/bin/kinhin"

app_src_hash="$(shasum -a 256 "$BIN_DIR/kinhin-app" | awk '{print $1}')"
app_dst_hash="$(shasum -a 256 "$APP/Contents/MacOS/kinhin" | awk '{print $1}')"
cli_src_hash="$(shasum -a 256 "$BIN_DIR/kinhin" | awk '{print $1}')"
cli_dst_hash="$(shasum -a 256 "$APP/Contents/Resources/bin/kinhin" | awk '{print $1}')"
if [ "$app_src_hash" != "$app_dst_hash" ] || [ "$cli_src_hash" != "$cli_dst_hash" ]; then
    echo "FATAL: bundle binaries do not match build products" >&2
    echo "  kinhin-app: $app_src_hash vs $app_dst_hash" >&2
    echo "  kinhin:     $cli_src_hash vs $cli_dst_hash" >&2
    exit 1
fi
echo "==> hashes verified: kinhin-app $app_src_hash / kinhin $cli_src_hash"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>kinhin</string>
    <key>CFBundleDisplayName</key>
    <string>kinhin</string>
    <key>CFBundleIdentifier</key>
    <string>com.kinhin.runner</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleExecutable</key>
    <string>kinhin</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Rabin Apps, LLC — Apache License 2.0</string>
</dict>
</plist>
PLIST

echo "==> app bundle ready: $APP"
