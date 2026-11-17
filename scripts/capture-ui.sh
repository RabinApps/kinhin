#!/bin/bash
# Render every screen of the desktop app to PNGs, offscreen, without launching it.
#
# Runs UICaptureTests (Tests/KinhinAppTests): the real window controller, every sidebar section, every Diagnostics pane
# and the setup wizard, in light, dark and right-to-left. Use it for step 4 of "Design first" in CONTRIBUTING.md:
# compare each image with its frame in design/exports/.
#
# It never touches your real setup: it points the app at a throwaway support directory with a small config
# (a GitHub account, all three runtimes on, a named image, a container pool, routes and a budget, so Runtimes shows
# every card), keeps tokens out of the Keychain
# (KINHIN_TOKEN_STORE=env), and talks to no daemon or forge.
#
# Usage: scripts/capture-ui.sh [OUT_DIR]     OUT_DIR defaults to shots/out (gitignored)
#        KINHIN_CAPTURE_PAGES=runtimes,settings scripts/capture-ui.sh     render only those pages
set -euo pipefail

cd "$(dirname "$0")/.."

OUT="${1:-shots/out}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

SUPPORT="$(mktemp -d)"
trap 'rm -rf "$SUPPORT"' EXIT

cat > "$SUPPORT/config.yaml" <<'YAML'
accounts:
  - name: github
    forge: github
    scope: acme/demo
labels: [self-hosted]
max_runners: 6
min_runners: 0
image: tahoe-base
image_min_idle: 1
images:
  - name: xcode
    labels: [xcode]
    min_idle: 1
runtimes:
  default: appleContainer
  tart:
    enabled: true
  budget: { tart: 0.4, appleContainer: 0.4, docker: 0.2 }
  routes:
    - pattern: "acme/ios-app"
      runtime: tart
container:
  image: kinhin-ci-linux
  cpus: 4
  memory_gb: 8
  min_idle: 1
  pools:
    big: { labels: [big], cpus: 4, min_idle: 1 }
docker:
  image: kinhin-ci-linux
  cpus: 2
  memory_gb: 4
  max_slots: 4
  min_idle: 1
YAML

echo "==> rendering the screens into $OUT"
KINHIN_SUPPORT_DIR="$SUPPORT" KINHIN_TOKEN_STORE=env KINHIN_CAPTURE_OUT="$OUT" \
  swift test --build-system swiftbuild --filter UICaptureTests

echo "==> done: $(find "$OUT" -maxdepth 1 -name '*.png' | wc -l | tr -d ' ') images in $OUT"
