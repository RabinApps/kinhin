#!/bin/bash
# Builds the kinhin menu bar app bundle from the Swift package.
# Usage: scripts/build-app.sh [output-dir]
set -euo pipefail

# Single source of truth: Sources/KinhinKit/Core/Version.swift. Release CI
# stamps that file from the tag, so the binaries and the bundle agree.
SOURCE_VERSION="$(sed -n 's/.*current = "\(.*\)".*/\1/p' Sources/KinhinKit/Core/Version.swift)"
if [ -z "$SOURCE_VERSION" ]; then
    echo "FATAL: could not read the version from Sources/KinhinKit/Core/Version.swift" >&2
    exit 1
fi
VERSION="${KINHIN_VERSION:-$SOURCE_VERSION}"
# Info.plist versions must be numeric; a "-beta-N" suffix lives only in Version.swift and the tag.
BUNDLE_VERSION="${VERSION%%-*}"
OUT_DIR="${1:-dist}"
APP="$OUT_DIR/kinhin.app"
CONFIGURATION="${CONFIGURATION:-release}" # lowercase: debug|release
BUNDLE_ID="${KINHIN_BUNDLE_ID:-com.RabinApps.kinhin}"
# Signing identity (see `security find-identity -v -p codesigning`). "-" is an
# ad-hoc signature (CI, forks); set e.g. CODESIGN_IDENTITY="Developer ID
# Application: Your Name (TEAMID)" for a signed build. Siri/Shortcuts index
# App Intents most reliably for apps signed with a real identity.
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

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

# SwiftPM resource bundle (forge icons). ForgeIcon looks for it in
# Contents/Resources; without it the app falls back to a generic symbol.
RESOURCE_BUNDLE="kinhin_kinhin-app.bundle"
if [ ! -d "$BIN_DIR/$RESOURCE_BUNDLE/Contents/Resources/ForgeIcons" ]; then
    echo "FATAL: $BIN_DIR/$RESOURCE_BUNDLE/Contents/Resources/ForgeIcons missing — did the kinhin-app build copy its resources?" >&2
    exit 1
fi
cp -R "$BIN_DIR/$RESOURCE_BUNDLE" "$APP/Contents/Resources/$RESOURCE_BUNDLE"

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
    <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>
    <string>$BUNDLE_VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$BUNDLE_VERSION</string>
    <key>CFBundleExecutable</key>
    <string>kinhin</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Rabin Apps, LLC — Apache License 2.0</string>
</dict>
</plist>
PLIST

# App Intents (Siri / Shortcuts / Spotlight): SwiftPM does not run Xcode's
# metadata step, so generate Metadata.appintents from the compiler's
# const-values output and put it in the bundle's Resources.
echo "==> generating App Intents metadata"
BUILD_ROOT="$(dirname "$(dirname "$BIN_DIR")")"
META_TMP="$(mktemp -d)"
trap 'rm -rf "$META_TMP"' EXIT
find "$BUILD_ROOT" -path "*kinhin-app*" -name '*.swiftconstvalues' > "$META_TMP/constvalues.txt"
find Sources/kinhin-app -name '*.swift' | sed "s|^|$PWD/|" > "$META_TMP/sources.txt"
if [ ! -s "$META_TMP/constvalues.txt" ]; then
    echo "FATAL: no .swiftconstvalues found under $BUILD_ROOT; App Intents metadata cannot be generated" >&2
    exit 1
fi
xcrun appintentsmetadataprocessor \
    --output "$APP/Contents/Resources" \
    --toolchain-dir "$(dirname "$(dirname "$(dirname "$(xcrun --find swiftc)")")")" \
    --module-name kinhin_app \
    --sdk-root "$(xcrun --show-sdk-path)" \
    --xcode-version "$(xcodebuild -version | awk '/Build version/ {print $3}')" \
    --platform-family macOS \
    --deployment-target 15.0 \
    --target-triple arm64-apple-macos15.0 \
    --source-file-list "$META_TMP/sources.txt" \
    --swift-const-vals-list "$META_TMP/constvalues.txt"

# Sign inside-out (nested CLI first, then the bundle). A real identity gets the
# hardened runtime + secure timestamp that notarization requires.
SIGN_ARGS=(--force --sign "$CODESIGN_IDENTITY")
if [ "$CODESIGN_IDENTITY" != "-" ]; then
    SIGN_ARGS+=(--options runtime --timestamp)
fi
echo "==> codesign ($CODESIGN_IDENTITY)"
codesign "${SIGN_ARGS[@]}" "$APP/Contents/Resources/bin/kinhin"
codesign "${SIGN_ARGS[@]}" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --deep --strict "$APP"

echo "==> app bundle ready: $APP"
