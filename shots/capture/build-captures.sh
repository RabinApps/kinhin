#!/bin/bash
# Build & run the UI capture harness (renders wizard steps 1–4 + Config tab
# to PNG + view-frame trees in shots/out/), then build the viewable gallery.
#
# Compiles the harness WITH the app sources so it sees internal types.
# AppMain.swift is excluded: its @main would collide with the harness's @main.
#
# Usage: shots/capture/build-captures.sh
set -e
cd "$(dirname "$0")/../.."

OUT=.build/out
PROD=$OUT/Products/Debug
DEST=shots/out
mkdir -p "$DEST"

swift build 2>/dev/null

# App sources minus AppMain.swift, plus the harness (which carries @main).
APP_SOURCES="Sources/kinhin-app"
SOURCES=$(find "$APP_SOURCES" -name '*.swift' | sort | grep -v "/AppMain.swift")
SOURCES="$SOURCES shots/capture/AppMainLite.swift shots/capture/harness_main.swift"

swiftc -swift-version 6 -o shots/capture/harness $SOURCES \
  -I $PROD \
  -I .build/checkouts/Yams/Sources/CYaml/include \
  $PROD/CYaml.o $PROD/Yams.o $PROD/KinhinKit.o \
  -framework AppKit -framework SwiftUI -framework Security 2> shots/capture/harness-build.err || {
  echo "BUILD FAILED — first errors:"
  grep -m8 "error:" shots/capture/harness-build.err
  exit 1
}

KINHIN_HARNESS_OUT=$DEST ./shots/capture/harness

python3 shots/tools/gallery.py
