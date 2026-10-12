#!/bin/bash
# Records an adapter's terminal clip (its VHS tape) in the variants a video can use, so it picks the one that suits
# its theme and format: light or dark, landscape or portrait.
#
# Usage: video/scripts/record-terminal.sh [--adapter NAME] [--clip NAME] [--dark] [--portrait] [--all]
#   --adapter NAME  default: the project's adapter (VIDEO_ADAPTER / VIDEO_PROJECT), see adapters/
#   --clip NAME     a terminal clip of the adapter (default: its first one)
#   (none)  light, 1920x1080      raw/<adapter>/<clip>.mp4
#   --dark  dark terminal          raw/<adapter>/<clip>-dark.mp4        (for themes with "terminal": "dark")
#   --portrait  1080x1350          raw/<adapter>/<clip>-portrait.mp4    (for 9:16, 4:5 and 1:1)
#   --all   all four variants
# The tape (the adapter's "tape") is a template: this script fills in its Output, FontSize, Width, Height, Padding and
# Theme lines, and exports VIDEO_REPO_ROOT for commands that need the repository. When the adapter gives
# "hideFromLine", everything from that output line down is painted over (scripts/mask-terminal.sh), so a clip can end
# before output that should not show. Needs vhs, ttyd and ffmpeg. scripts/make-reference.sh then makes the committed copies.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -d /opt/homebrew/opt/ffmpeg-full/bin ] && export PATH="/opt/homebrew/opt/ffmpeg-full/bin:$PATH"
export VIDEO_REPO_ROOT="$(cd .. && pwd)"

ADAPTER="${VIDEO_ADAPTER:-}"; CLIP=""; ALL=0; dark=0; portrait=0
while [ $# -gt 0 ]; do
  case "$1" in
    --adapter) ADAPTER="${2:?--adapter needs a name}"; shift ;;
    --clip) CLIP="${2:?--clip needs a name}"; shift ;;
    --dark) dark=1 ;; --portrait) portrait=1 ;; --all) ALL=1 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$ADAPTER" ] || ADAPTER="$(node scripts/project.mjs --adapter)"
[ -n "$ADAPTER" ] || { echo "no adapter: pass --adapter NAME (see video/adapters/)" >&2; exit 2; }
[ -n "$CLIP" ] || CLIP="$(node -e "const a=require('fs').readFileSync('adapters/$ADAPTER/adapter.json','utf8');const c=JSON.parse(a).clips;console.log(Object.keys(c).find(k=>c[k].kind==='terminal')||'')")"
[ -n "$CLIP" ] || { echo "adapter $ADAPTER has no terminal clip" >&2; exit 2; }
eval "$(node scripts/adapter.mjs "$ADAPTER" --clip "$CLIP" --env)"
[ -f "$TAPE" ] || { echo "no tape for $ADAPTER/$CLIP: $TAPE" >&2; exit 1; }
mkdir -p "$RAW_DIR"

record() { # dark(0|1) portrait(0|1)
  local dark="$1" portrait="$2" name="$CLIP" w=1920 h=1080 size=34 pad=80 theme='"Builtin Light"' bg=white
  [ "$dark" = 1 ] && name="$name-dark"
  [ "$portrait" = 1 ] && { name="$name-portrait"; w=1080; h=1350; size=36; pad=60; }
  if [ "$dark" = 1 ]; then
    bg='0x11162d'   # what the dark terminal's background decodes to (one level off the theme colour)
    theme='{"name":"video-midnight","black":"#10162c","red":"#ff7a8a","green":"#8be9a8","yellow":"#ffd479","blue":"#7aa2ff","magenta":"#c3a6ff","cyan":"#7ee7f0","white":"#e6e9f5","brightBlack":"#4a557f","brightRed":"#ff9aa6","brightGreen":"#a6f0bd","brightYellow":"#ffe3a0","brightBlue":"#9ab8ff","brightMagenta":"#d4bcff","brightCyan":"#a0f0f6","brightWhite":"#ffffff","background":"#10162c","foreground":"#e6e9f5","selection":"#26305a","cursor":"#e6e9f5"}'
  fi
  local tape="$RAW_DIR/.$name.tape"
  sed -e "s|^Output .*|Output \"$RAW_DIR/$name-uncut.mp4\"|" -e "s|^Set FontSize .*|Set FontSize $size|" -e "s|^Set Width .*|Set Width $w|" \
      -e "s|^Set Height .*|Set Height $h|" -e "s|^Set Padding .*|Set Padding $pad|" -e "s|^Set Theme .*|Set Theme $theme|" "$TAPE" > "$tape"
  vhs "$tape" >/dev/null
  rm -f "$tape"
  if [ -n "$HIDE_FROM_LINE" ]; then
    # Where the hidden lines start: the padding plus that many terminal lines of 41 px (the line pitch of both font sizes).
    MASK_Y="$((pad + HIDE_FROM_LINE * 41 + 4))" BG="$bg" scripts/mask-terminal.sh "$RAW_DIR/$name-uncut.mp4" "$RAW_DIR/$name.mp4"
  else
    cp "$RAW_DIR/$name-uncut.mp4" "$RAW_DIR/$name.mp4"; echo "wrote $RAW_DIR/$name.mp4"
  fi
}

if [ "$ALL" = 1 ]; then record 0 0; record 1 0; record 0 1; record 1 1; else record "$dark" "$portrait"; fi
