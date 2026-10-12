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
check ffmpeg ffmpeg "assemble.mjs" "brew install ffmpeg-full"
if command -v ffmpeg >/dev/null 2>&1 || [ -x /opt/homebrew/opt/ffmpeg-full/bin/ffmpeg ]; then
  FF=ffmpeg; [ -x /opt/homebrew/opt/ffmpeg-full/bin/ffmpeg ] && FF=/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg
  if "$FF" -hide_banner -filters 2>/dev/null | grep -q ' subtitles '; then echo "  ok       libass       captions (ffmpeg subtitles filter)"
  else echo "  MISSING  libass       captions need ffmpeg with libass  (brew install ffmpeg-full, or VIDEO_CAPTIONS=off)"; ok=0; fi
fi
[ -d node_modules ] && echo "  ok       npm deps     video/node_modules" || { echo "  MISSING  npm deps     (cd video && npm install)"; ok=0; }
echo "Web product clips (any machine; a container is optional):"
[ -d node_modules/playwright-core ] && echo "  ok       playwright   video/node_modules (browser: Playwright's Chromium, or CHROMIUM_PATH)" \
  || echo "  MISSING  playwright   (cd video && npm install)"
optional docker docker "record-web.sh --runner docker" "install Docker"
optional container container "record-web.sh --runner apple, and building in a container" "https://github.com/apple/container"
# Each adapter lists what recording its clips needs (adapters/<name>/adapter.json "needs"). Optional tools are
# reported but never fail the check; the committed reference clips mean nothing here is needed to build a video.
for dir in adapters/*/; do
  name="$(basename "$dir")"
  echo "Adapter $name (only to record fresh clips; the committed reference clips need none of this):"
  while IFS=$'\t' read -r tool why how optional; do
    [ -n "$tool" ] || continue
    if [ "$optional" = true ]; then optional "$tool" "$tool" "$why" "$how"; else check "$tool" "$tool" "$why" "$how"; fi
  done < <(node -e "for (const n of (JSON.parse(require('fs').readFileSync('$dir/adapter.json','utf8')).needs||[])) console.log([n.tool,n.why,n.how,!!n.optional].join('\t'))")
done
[ "$ok" = 1 ] && echo "All set." || { echo "Some tools are missing."; exit 1; }
