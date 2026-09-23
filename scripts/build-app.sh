#!/bin/bash
# Builds the Orchard menu bar app bundle from the Swift package.
# Usage: scripts/build-app.sh [output-dir]
set -euo pipefail

VERSION="${ORCHARD_VERSION:-0.1.0}"
OUT_DIR="${1:-dist}"
APP="$OUT_DIR/Orchard.app"
CONFIGURATION="${CONFIGURATION:-release}" # lowercase: debug|release

echo "==> swift build -c $CONFIGURATION"
swift build -c "$CONFIGURATION"

BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path --product orchard-app)"
# Assemble from scratch — never patch over a previous bundle (stale binaries).
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources/bin"

echo "==> assembling $APP"
# Chain of custody: hash every binary before and after copying so a stale
# artifact can never sneak into the bundle (this class of bug once shipped an
# old CLI in the DMG and made the app's buttons appear broken).
cp "$BIN_DIR/orchard-app" "$APP/Contents/MacOS/Orchard"
# The CLI lives at Resources/bin/orchard — MacOS/ is case-insensitive on APFS,
# so 'Orchard' and 'orchard' in the same directory would silently clobber it.
cp "$BIN_DIR/orchard" "$APP/Contents/Resources/bin/orchard"

app_src_hash="$(shasum -a 256 "$BIN_DIR/orchard-app" | awk '{print $1}')"
app_dst_hash="$(shasum -a 256 "$APP/Contents/MacOS/Orchard" | awk '{print $1}')"
cli_src_hash="$(shasum -a 256 "$BIN_DIR/orchard" | awk '{print $1}')"
cli_dst_hash="$(shasum -a 256 "$APP/Contents/Resources/bin/orchard" | awk '{print $1}')"
if [ "$app_src_hash" != "$app_dst_hash" ] || [ "$cli_src_hash" != "$cli_dst_hash" ]; then
    echo "FATAL: bundle binaries do not match build products" >&2
    echo "  orchard-app: $app_src_hash vs $app_dst_hash" >&2
    echo "  orchard:     $cli_src_hash vs $cli_dst_hash" >&2
    exit 1
fi
echo "==> hashes verified: orchard-app $app_src_hash / orchard $cli_src_hash"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Orchard</string>
    <key>CFBundleDisplayName</key>
    <string>Orchard</string>
    <key>CFBundleIdentifier</key>
    <string>com.orchard.runner</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleExecutable</key>
    <string>Orchard</string>
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
