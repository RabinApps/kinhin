#!/bin/bash
# Checks what the video pipeline needs on this machine. Nothing is installed or changed.
# Usage: video/scripts/doctor.sh
cd "$(dirname "$0")/.."
ok=1
check() { # name, command, needed-for, how-to-get
  if command -v "$2" >/dev/null 2>&1; then printf '  ok       %-12s %s\n' "$1" "$3"
  else printf '  MISSING  %-12s %s  (%s)\n' "$1" "$3" "$4"; ok=0; fi
}
optional() { # like check, but a missing tool is not a failure
  if command -v "$2" >/dev/null 2>&1; then printf '  ok       %-12s %s\n' "$1" "$3"
  else printf '  optional %-12s %s  (%s)\n' "$1" "$3" "$4"; fi
}
echo "Any machine (title scenes and the final cut):"
check node node "Motion Canvas title scenes" "node >= 22"
check ffmpeg ffmpeg "export.sh" "brew install ffmpeg"
[ -d node_modules ] && echo "  ok       npm deps     video/node_modules" || { echo "  MISSING  npm deps     (cd video && npm install)"; ok=0; }
echo "Web product clips (any machine; a container is optional):"
[ -d node_modules/playwright-core ] && echo "  ok       playwright   video/node_modules (browser: Playwright's Chromium, or CHROMIUM_PATH)" \
  || echo "  MISSING  playwright   (cd video && npm install)"
optional docker docker "record-web.sh --runner docker" "install Docker"
optional container container "record-web.sh --runner apple" "apple/container: kinhin setup repair container"
echo "A Mac (the app and terminal clips):"
if [ "$(uname -s)" = Darwin ]; then
  check swift swift "building the demo app" "Xcode 26+"
  check screencapture screencapture "record.sh" "built into macOS"
  check vhs vhs "terminal/install.tape" "brew install vhs"
  check tart tart "record-in-tart.sh" "kinhin setup repair tart"
  check sshpass sshpass "record-in-tart.sh password login (or use an ssh key)" "brew install sshpass"
else
  echo "  skipped  not macOS: record the app clips on a Mac (see docs/making-a-video.md)"
fi
[ "$ok" = 1 ] && echo "All set." || { echo "Some tools are missing."; exit 1; }
