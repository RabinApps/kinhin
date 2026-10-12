#!/bin/bash
# Records the terminal clip (terminal/install.tape: the real `kinhin doctor`, run from this checkout's debug build
# against a throwaway support dir) in one of four variants, so a video can use the one that suits its theme and format:
#   (none)      light terminal, 1920x1080   raw/install.mp4
#   --dark      dark terminal               raw/install-dark.mp4     (for themes with "terminal": "dark")
#   --portrait  1080x1350 for 9:16, 4:5 and 1:1   raw/install-portrait.mp4
#   both        raw/install-dark-portrait.mp4
# The empty-config lines at the bottom are masked afterwards (terminal/trim.sh). Needs vhs, ttyd and ffmpeg, and
# `swift build --product kinhin` first. After recording, scripts/make-reference.sh copies the clips into reference/.
# Usage: video/scripts/record-terminal.sh [--dark] [--portrait] [--all]
set -euo pipefail
cd "$(dirname "$0")/.."
[ -d /opt/homebrew/opt/ffmpeg-full/bin ] && export PATH="/opt/homebrew/opt/ffmpeg-full/bin:$PATH"

record() { # dark(0|1) portrait(0|1)
  local dark="$1" portrait="$2" name=install w=1920 h=1080 size=34 pad=80 theme='"Builtin Light"' bg=white
  [ "$dark" = 1 ] && name="$name-dark"
  [ "$portrait" = 1 ] && { name="$name-portrait"; w=1080; h=1350; size=36; pad=60; }
  if [ "$dark" = 1 ]; then
    bg='0x11162d'   # what the dark terminal's background decodes to (one level off the theme colour)
    theme='{"name":"kinhin-midnight","black":"#10162c","red":"#ff7a8a","green":"#8be9a8","yellow":"#ffd479","blue":"#7aa2ff","magenta":"#c3a6ff","cyan":"#7ee7f0","white":"#e6e9f5","brightBlack":"#4a557f","brightRed":"#ff9aa6","brightGreen":"#a6f0bd","brightYellow":"#ffe3a0","brightBlue":"#9ab8ff","brightMagenta":"#d4bcff","brightCyan":"#a0f0f6","brightWhite":"#ffffff","background":"#10162c","foreground":"#e6e9f5","selection":"#26305a","cursor":"#e6e9f5"}'
  fi
  local tape="terminal/.$name.tape"
  sed -e "s|^Output .*|Output raw/$name-uncut.mp4|" -e "s|^Set FontSize .*|Set FontSize $size|" -e "s|^Set Width .*|Set Width $w|" \
      -e "s|^Set Height .*|Set Height $h|" -e "s|^Set Padding .*|Set Padding $pad|" -e "s|^Set Theme .*|Set Theme $theme|" terminal/install.tape > "$tape"
  vhs "$tape" >/dev/null
  rm -f "$tape"
  # Where the `token:` line starts: the padding plus nine terminal lines of 41 px (the line pitch of both font sizes).
  MASK_Y="$((pad + 9 * 41 + 4))" BG="$bg" terminal/trim.sh "raw/$name-uncut.mp4" "raw/$name.mp4"
}

case "${1:-}" in
  --all) record 0 0; record 1 0; record 0 1; record 1 1 ;;
  *) dark=0; portrait=0
     for a in "$@"; do case "$a" in --dark) dark=1 ;; --portrait) portrait=1 ;; *) echo "unknown option: $a" >&2; exit 2 ;; esac; done
     record "$dark" "$portrait" ;;
esac
