#!/bin/bash
# Downloads the CC0 music bed used in the launch video to raw/music.wav and checks its SHA-256, so every build
# uses the same track. First Light Particles by Yoiyami, CC0 1.0 (no credit needed; users may reuse it):
# https://opengameart.org/node/182244
# Usage: video/scripts/fetch-music.sh        (does nothing if raw/music.* already exists)
set -euo pipefail
cd "$(dirname "$0")/.."
URL="https://opengameart.org/sites/default/files/first_light_particles_0.wav"
SHA256="f0538a1a67450cc1d5e305fad5bc0d5d422ad809f720d695ab356e55fbe40fc5"
for ext in mp3 m4a wav flac ogg; do [ -f "raw/music.$ext" ] && { echo "raw/music.$ext exists"; exit 0; }; done
mkdir -p raw
curl -fsSL "$URL" -o raw/music.wav.part
got="$(sha256sum raw/music.wav.part 2>/dev/null | cut -d' ' -f1 || shasum -a 256 raw/music.wav.part | cut -d' ' -f1)"
if [ "$got" != "$SHA256" ]; then
  rm -f raw/music.wav.part
  echo "music checksum mismatch (got $got): the file at $URL changed; not using it" >&2
  exit 1
fi
mv raw/music.wav.part raw/music.wav
echo "wrote raw/music.wav (CC0, Yoiyami)"
